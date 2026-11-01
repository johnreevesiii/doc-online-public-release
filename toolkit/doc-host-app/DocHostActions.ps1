# DocHostActions.ps1 -- the verbs behind the DOC Host window's buttons (doc-ops #117 Phase 1).
#
# Each verb is the non-interactive form of what a Host Pack script already does, built from the pack's own
# setup\Common.ps1 helpers:
#   Info        JSON for the window: version, games, cabinet, settings, warnings.
#   Pair        Setup.ps1 step 2: the existing device-code pairing (/api/cabinet/pair/start + poll). It opens
#               the website so the host signs in and approves, exactly as SETUP - Start Here does.
#   Start       Setup.ps1 steps 4-7 with the window's answers: write cabinet.json, register this install's
#               tasks, start services, game, borderless pass, video, then verify.
#   Stop        StopHosting.ps1, but scoped: only tasks and processes of THIS install.
#   FixPicture  Doctor -FixVideo plus the satellites' borderless pass. Never restarts Flycast.
#   RestartGame RestartGame.ps1 -Quiet.
#   Doctor      Doctor.ps1 -Quiet (the report).
#   SetOption   save one setting (remote_recover, video).
# Output: plain progress lines, plus "@@<TAG> <json>" lines the window parses.
# Exit codes: 0 ok, 1 failed, 2 busy (another action is running), 3 needs -Force (another pack owns the
# doc_home_ tasks), 4 refused (port 8770 belongs to another install, or not paired).
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('Info', 'Pair', 'Start', 'Stop', 'FixPicture', 'RestartGame', 'Doctor', 'SetOption', 'CheckUpdate', 'ApplyUpdate', 'AutoUpdate', 'Recover')]
  [string]$Action,
  [int]$Seats = 0,
  [string]$Rom = '',
  [string]$Label = '',
  [switch]$LocalPlay,
  [switch]$NoVideo,
  [switch]$Force,
  [string]$Name = '',
  [string]$Value = ''
)

# ---- an interrupted update is undone by the code that started it (review of PR #45) ------------------------------
# Before anything else is loaded: after a power cut in the middle of an update these scripts may be a mix of the
# old and new release. The actions that undo an interrupted update first run that undo from the frozen copy the
# update saved before its first swap (DocHostUpdate.ps1 Save-DhRecoveryKit), as "-Action Recover -Value <action>".
# Only plain file reads here, nothing from the other scripts. The copy answers 10 + the undo's code, or 9 (another
# action holds the lock); anything else (the copy itself failed) falls through to this install's own undo below.
# The copy runs only when it can be trusted as much as these scripts (review of PR #45 round 12): it names THIS
# install, nothing on its path is a junction or link, its files belong to this account, and (release builds) the
# data folder is private to this account and SYSTEM, as the installer makes it. Otherwise the install's own undo runs.
# DOCHOST_RERUN marks the fresh run below: it never runs the copy again (it can only turn the copy off, so it is
# honoured in release builds too), which bounds the hand-over to one level even if the marker could not be removed.
function Test-DhDataDirTrustedEarly([string]$dir, [bool]$needPrivate) {
  # $true when only this account and the system can change the data folder or anything above it (review of PR #45
  # rounds 16-17). SIDs are read without translating names (an orphaned "Account Unknown" entry on a second drive
  # is simply not this account). A network folder is never trusted (share permissions and the server are not
  # visible from here). $needPrivate (release builds): the folder itself is private as the installer makes it.
  # $script:DH_TRUST_WHY says which rule failed, for the host's message.
  $script:DH_TRUST_WHY = ''
  try {
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $sidT = [Security.Principal.SecurityIdentifier]
    $full = [IO.Path]::GetFullPath($dir).TrimEnd('\')
    if ($full.StartsWith('\\')) { $script:DH_TRUST_WHY = "the data folder is on the network ($full)"; return $false }
    $root = [IO.Path]::GetPathRoot($full)
    $drv = New-Object IO.DriveInfo $root
    if ($drv.DriveType -eq [IO.DriveType]::Network) { $script:DH_TRUST_WHY = "the data folder is on a network drive ($full)"; return $false }
    if ($drv.DriveFormat -notin @('NTFS', 'ReFS')) { $script:DH_TRUST_WHY = "the data folder's drive has no Windows permissions ($($drv.DriveFormat))"; return $false }
    if ((Test-Path -LiteralPath $full) -and ((Get-Item -LiteralPath $full -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { $script:DH_TRUST_WHY = "the data folder is a link to another folder ($full)"; return $false }
    $okSids = @($me, 'S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    if ($needPrivate) {
      $acl = Get-Acl -LiteralPath $full
      if (-not $acl.AreAccessRulesProtected -or $acl.GetOwner($sidT).Value -ne $me) { $script:DH_TRUST_WHY = "the data folder is not private to this Windows account ($full)"; return $false }
      foreach ($r in $acl.GetAccessRules($true, $true, $sidT)) { if ($r.IdentityReference.Value -notin @($me, 'S-1-5-18')) { $script:DH_TRUST_WHY = "another account ($($r.IdentityReference.Value)) has access to the data folder ($full)"; return $false } }
    }
    # every folder above: no junction or link, owned by this account or the system, and nobody else may delete it,
    # change its permissions, take it over, or delete what is inside it
    $chain = @(); $c = Split-Path -Parent $full
    while ($c) { $chain += $c; $n = Split-Path -Parent $c; if (-not $n -or $n -eq $c) { break }; $c = $n }
    for ($i = 0; $i -lt $chain.Count; $i++) {
      $f = $chain[$i]; $isRoot = ($i -eq $chain.Count - 1)
      if ((Get-Item -LiteralPath $f -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { $script:DH_TRUST_WHY = "a folder above the data folder is a link ($f)"; return $false }
      $acl = Get-Acl -LiteralPath $f
      $own = $acl.GetOwner($sidT).Value
      if ($own -notin $okSids) { $script:DH_TRUST_WHY = "a folder above the data folder belongs to another account ($f, $own)"; return $false }
      foreach ($r in $acl.GetAccessRules($true, $true, $sidT)) {
        if ($r.AccessControlType -ne 'Allow' -or ($r.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
        if ($r.IdentityReference.Value -in $okSids) { continue }
        # 0x40 delete children, 0x40000 change permissions, 0x80000 take ownership, generic all / generic write;
        # 0x10000 delete (not on a drive's root, which cannot be deleted)
        $bad = 0x40 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
        if (-not $isRoot) { $bad = $bad -bor 0x10000 }
        if ([int64]$r.FileSystemRights -band $bad) { $script:DH_TRUST_WHY = "another account ($($r.IdentityReference.Value)) can rename or replace a folder above the data folder ($f)"; return $false }
      }
    }
    return $true
  } catch { $script:DH_TRUST_WHY = "the data folder's permissions could not be read ($($_.Exception.Message))"; return $false }
}
# Read once and cleared at once, so nothing this run starts inherits them (round 17 red team): a stale one could
# turn the copy off for a later interrupted update or hold the time guard back.
$script:DH_IS_RERUN = ($env:DOCHOST_RERUN -eq '1'); $script:DH_T0_IN = [string]$env:DOCHOST_T0
Remove-Item Env:\DOCHOST_RERUN, Env:\DOCHOST_T0 -ErrorAction SilentlyContinue
if ($Action -in @('Start', 'RestartGame', 'ApplyUpdate', 'AutoUpdate') -and -not $script:DH_IS_RERUN -and -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'recovery-app.txt'))) {
  $kitRun = $null; $why = ''
  try {
    $rel = Test-Path -LiteralPath (Join-Path $PSScriptRoot 'RELEASE')
    $dd = ''
    $ddf = Join-Path $PSScriptRoot 'datadir.txt'                   # DocHostCommon.ps1 Get-DhDataDir, same rule
    if (Test-Path -LiteralPath $ddf) { $dd = ([IO.File]::ReadAllText($ddf)).Trim() }
    if (-not $dd) { $dd = Join-Path $env:LOCALAPPDATA $(if ($rel) { 'DOC Host\data' } else { 'DOC Host TEST\data' }) }
    $ipf = Join-Path $dd 'updates\in-progress.json'
    if (Test-Path -LiteralPath $ipf) {
      $att = [string](([IO.File]::ReadAllText($ipf)) | ConvertFrom-Json).attempt
      if ($att -match '^[0-9a-f]{12}$') {
        $kitDir = Join-Path $dd ("updates\recovery\{0}\hostapp" -f $att)
        $kit = Join-Path $kitDir 'DocHostActions.ps1'; $kitApp = Join-Path $kitDir 'recovery-app.txt'
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        # this account, or Administrators/SYSTEM (an update run from DOC Host started as administrator)
        $ownedByMe = { param($p) ((Get-Acl -LiteralPath $p).GetOwner([Security.Principal.SecurityIdentifier]).Value -in @($me, 'S-1-5-32-544', 'S-1-5-18')) }
        $ok = (Test-Path -LiteralPath $kit -PathType Leaf) -and (Test-Path -LiteralPath $kitApp -PathType Leaf)
        if ($ok) {
          # long forms on both sides (an 8.3 short path such as JOHNPC~1 must not refuse a good copy)
          $want = (Get-Item -LiteralPath (Split-Path -Parent $PSScriptRoot) -Force).FullName.TrimEnd('\')
          $nm = ([IO.File]::ReadAllText($kitApp)).Trim()
          if (-not $nm -or -not (Test-Path -LiteralPath $nm -PathType Container)) { $ok = $false }
          else { $ok = (Get-Item -LiteralPath $nm -Force).FullName.TrimEnd('\').Equals($want, [StringComparison]::OrdinalIgnoreCase) }
        }
        if ($ok) {                                     # no junction or link from the data folder down to the copy
          $d = $kitDir
          while ($ok -and $d.Length -ge $dd.TrimEnd('\').Length) {
            if ((Get-Item -LiteralPath $d -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { $ok = $false }
            $d = Split-Path -Parent $d
          }
          $kitPack = Join-Path (Split-Path -Parent $kitDir) 'pack'
          foreach ($pd in @($kitPack, (Join-Path $kitPack 'setup'))) {   # the copy's pack folder too
            if ($ok -and (Test-Path -LiteralPath $pd) -and ((Get-Item -LiteralPath $pd -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { $ok = $false }
          }
          $kitPC = Join-Path $kitPack 'setup\Common.ps1'
          if ($ok -and (Test-Path -LiteralPath $kitPC) -and (((Get-Item -LiteralPath $kitPC -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not (& $ownedByMe $kitPC))) { $ok = $false }
          foreach ($p in @($kit, $kitApp, (Join-Path $kitDir 'DocHostCommon.ps1'), (Join-Path $kitDir 'DocHostUpdate.ps1'))) {
            if ($ok -and (-not (Test-Path -LiteralPath $p -PathType Leaf) -or ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not (& $ownedByMe $p))) { $ok = $false }
          }
        }
        # the data folder and every folder above it: only this account and the system can change them (rounds 16-17)
        if ($ok -and -not (Test-DhDataDirTrustedEarly $dd ($rel -or $env:DOCHOST_SANDBOX -ne '1'))) { $ok = $false; $why = $script:DH_TRUST_WHY }
        if ($ok) { $kitRun = $kit } else { [Console]::Out.WriteLine(('an interrupted update''s recovery copy failed its checks{0}: using this install''s own undo' -f $(if ($why) { " ($why)" } else { '' }))) }
      }
    }
  } catch {
    $kitRun = $null
    [Console]::Out.WriteLine(('an interrupted update''s recovery copy failed its checks ({0}): using this install''s own undo' -f $_.Exception.Message))
  }
  if ($kitRun) {
    # bounded: the copy runs outside the update task's job, so the task's time limit would not stop it
    $kp = Start-Process -FilePath ((Get-Process -Id $PID).Path) -NoNewWindow -PassThru -ArgumentList @(
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $kitRun + '"'), '-Action', 'Recover', '-Value', $Action)
    $null = $kp.Handle                                 # Windows PowerShell 5.1 reports no exit code without it
    if (-not $kp.WaitForExit(1800000)) {
      try { $kp.Kill() } catch { }
      [Console]::Out.WriteLine('the undo of an interrupted update did not finish in 30 minutes: stopped; it is tried again next time')
      exit 1
    }
    $kc = $kp.ExitCode
    if ($kc -eq 9) {                                   # busy, as each action answered busy before
      [Console]::Out.WriteLine('busy: another DOC Host action is running (an update in progress finishes or is undone first)')
      exit $(if ($Action -eq 'AutoUpdate') { 0 } else { 2 })
    }
    if ($kc -ge 10 -and $kc -le 15) {
      $rr = $kc - 10                                   # Repair-DhInterruptedUpdate's code
      switch ($Action) {
        'Start'       { if ($rr -eq 1) { exit 1 } }
        'RestartGame' { if ($rr -eq 1 -or $rr -eq 5) { exit 1 }; if ($rr -eq 3) { exit 0 } }   # 3: the undo started it
        default       { if ($rr -eq 1 -or $rr -eq 5) { exit 1 }; if ($rr -eq 2) { exit 0 } }
      }
      # Undone (or nothing left). This process already parsed THIS DocHostActions.ps1, which may be the new release's
      # one the undo just replaced: the action runs again in a fresh process, on the restored files (review of PR #45
      # round 15). It cannot loop: the undo removed the marker, so the fresh run skips this block.
      # Only the arguments these four actions take, each checked (round 16: Windows PowerShell 5.1 passes quotes
      # inside an argument through unescaped, so nothing free-form is handed on).
      $ra = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Action', $Action)
      if ($Seats -gt 0) { $ra += @('-Seats', [string][int]$Seats) }
      if ($Rom) {
        # a game name is handed on only when it is a plain key; any other is refused aloud, never dropped (round 17
        # review: dropped, Start would quietly host cabinet.json's game instead)
        if ($Rom -notmatch '^[A-Za-z0-9_]{1,32}$') { [Console]::Out.WriteLine("the game '$Rom' is not a known game key: press Start hosting again"); exit 1 }
        $ra += @('-Rom', $Rom)
      }
      foreach ($sw in @('LocalPlay', 'NoVideo', 'Force')) { if ($PSBoundParameters.ContainsKey($sw) -and $PSBoundParameters[$sw].IsPresent) { $ra += "-$sw" } }
      # Set for the fresh run only (it clears them at its top). It is bounded like the copy's run (it runs outside the
      # update task's job too): the time the task has left, or 30 minutes for a button; a run stopped part way is
      # an interrupted update the next run undoes (round 17 red team).
      $tStart = Get-Date; try { $tStart = (Get-Process -Id $PID).StartTime } catch { }
      $env:DOCHOST_RERUN = '1'; $env:DOCHOST_T0 = $tStart.ToUniversalTime().ToString('o')
      $ra[5] = '"' + $PSCommandPath + '"'                 # Start-Process joins the arguments as they are
      $limitMs = 1800000
      if ($Action -in @('ApplyUpdate', 'AutoUpdate')) { $limitMs = [int][Math]::Max(60000, (57 * 60000) - ((Get-Date) - $tStart).TotalMilliseconds) }
      $rp = $null; try { $rp = Start-Process -FilePath ((Get-Process -Id $PID).Path) -NoNewWindow -PassThru -ArgumentList $ra -ErrorAction Stop } catch { }
      Remove-Item Env:\DOCHOST_RERUN, Env:\DOCHOST_T0 -ErrorAction SilentlyContinue
      if (-not $rp) { [Console]::Out.WriteLine('the interrupted update was undone, but the action could not be started again: press it again'); exit 1 }
      $null = $rp.Handle
      if (-not $rp.WaitForExit($limitMs)) {
        try { $rp.Kill() } catch { }
        [Console]::Out.WriteLine('the action after the undo did not finish in time: stopped; it is tried again next time')
        exit 1
      }
      exit $rp.ExitCode
    }
  }
}

. (Join-Path $PSScriptRoot 'DocHostCommon.ps1')
. (Join-Path $PSScriptRoot 'DocHostUpdate.ps1')
$root = $script:DH_PACK
$logs = Join-Path $root 'logs'

function Say([string]$m) { [Console]::Out.WriteLine($m); Write-DhLog 'dochost-actions.log' ("{0}: {1}" -f $Action, $m) }

# The pack's lobby and hub checks (setup\Common.ps1) use Invoke-RestMethod, whose -TimeoutSec in PowerShell 5.1
# bounds only the wait for headers: a server dripping its body held them, and the action lock, indefinitely
# (review of PR #45 round 10). Within DOC Host's actions they go through Invoke-DhHttp, with an overall deadline.
function Get-DhJsonBounded([string]$url, [int]$deadlineS = 20) {
  try { $r = Invoke-DhHttp $url $null 256KB '' $deadlineS; return ([Text.Encoding]::UTF8.GetString($r.Bytes) | ConvertFrom-Json) } catch { return $null }
}
function Test-Tunnel([string]$id) {
  $t = Get-DhJsonBounded ("{0}/hub/cab_{1}/api/health" -f $script:HUB, $id)
  return [bool]($t -and $t.ok)
}
function Get-LobbyEndpoints([string]$id) {
  $j = Get-DhJsonBounded ("{0}/api/cabinet/endpoints?id={1}" -f $script:LOBBY, $id)
  if (-not $j) { return [pscustomobject]@{ Ok = $false; Broker = ''; Whep = '' } }
  return [pscustomobject]@{ Ok = ([bool]$j.broker_base -and [bool]$j.whep_base); Broker = [string]$j.broker_base; Whep = [string]$j.whep_base }
}

# ---------------------------------------------------------------------------------------------------
function Invoke-Info {
  $cab = Read-Cab $root
  $paired = Test-Paired $cab
  $ver = ''
  try { $ver = ([IO.File]::ReadAllText((Join-Path $root 'VERSION'))).Trim() } catch { }
  # Horses, not files: pending saves without their .json sidecars, and seat/library/shelf .card copies.
  $migrated = 0; $migratedCards = 0
  $mig = Join-Path $script:DH_DATA 'migrated'
  if (Test-Path -LiteralPath $mig) {
    # programdata-* is the v1 data folder's copy: its unsaved horses were already put back into pending_saves.
    $all = @(Get-ChildItem -LiteralPath $mig -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\migrated\\programdata-' })
    $migrated = @($all | Where-Object { $_.FullName -match '\\pending_saves\\' -and $_.Extension -ne '.json' }).Count
    $migratedCards = @($all | Where-Object { $_.FullName -match '\\cards\\' -and $_.Extension -eq '.card' }).Count
  }
  $foreign = @(Get-DhForeignTasks | ForEach-Object { $_.Name + ' (' + $_.State + '): ' + $_.Args.Substring(0, [Math]::Min(160, $_.Args.Length)) })
  # A game the website chose for this cabinet after this PC started its current one (site-rom.json, written by the
  # relay agent from the heartbeat reply): offered as the game for the next Start.
  $siteRom = $(if ($cab) { Get-DhSiteRom -PendingOnly } else { $null })
  $info = [ordered]@{
    pack_version = $ver
    pack_root = $root
    data_dir = $script:DH_DATA
    sandbox = $script:DH_SANDBOX
    lobby = $script:LOBBY
    hub = $script:HUB
    broker = $script:DH_BROKER
    task_prefix = $script:TASKPFX
    max_seats = $script:MAX_SEATS
    games = @($script:GAMES | ForEach-Object { [ordered]@{ key = $_.Key; rom = $_.Rom; name = $_.Name } })
    paired = [bool]$paired
    cabinet = $(if ($cab) { [ordered]@{
        id = [string]$cab.id; label = [string]$cab.label; seats = (Get-SeatCount $cab)
        rom = $(if ($siteRom) { $siteRom } else { [string]$cab.rom_ver }); local_seats = @($cab.local_seats)
        site_rom_pending = [bool]$siteRom } } else { $null })
    settings = (Get-DhSettings)
    migrated_pending_saves = $migrated
    migrated_cards = $migratedCards
    foreign_tasks = $foreign
    data_private = (Test-DhDataDirPrivate $script:DH_DATA)
    legacy_data = $(if (Test-Path -LiteralPath $script:DH_LEGACY_DATA) { $script:DH_LEGACY_DATA } else { '' })
    release = $script:DH_RELEASE
  }
  # Updates: the window shows the installed version and the last check; the 30-minute check is (re)registered
  # here, so it exists whenever DOC Host has been opened (only once updates are set up).
  $taskState = 'n/a'
  if ((Test-DhUpdateConfigured) -and -not $script:DH_SANDBOX) {
    try { $taskState = $(if (Register-DhUpdateTask) { 'ok' } else { 'failed' }) } catch { $taskState = 'failed' }
  }
  $upd = Get-DhUpdateInfo; $us = Get-DhUpdateSettings; $upd['task'] = $taskState
  $upd['mode'] = $us.Mode; $upd['channel'] = $us.Channel
  $info['update'] = $upd
  Write-DhJson 'INFO' $info
  return 0
}

# The website's game for this cabinet, as the relay agent last heard it (pack\site-rom.json), when it is a game this
# pack can run. -PendingOnly: only when the site's choice is newer than the game this PC started.
function Get-DhSiteRom([switch]$PendingOnly) {
  $f = Join-Path $root 'site-rom.json'
  if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $null }
  try { $sr = [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { return $null }
  $r = ([string]$sr.rom).Trim().ToLowerInvariant()
  if (-not $r -or -not (Get-GameByRom $r)) { return $null }
  if ($PendingOnly -and -not [bool]$sr.pending) { return $null }
  return $r
}

# ---------------------------------------------------------------------------------------------------
function Invoke-Pair {
  $cab = Read-Cab $root
  if (Test-Paired $cab) { Say ("already paired: {0} ({1})" -f $cab.label, $cab.id); return 0 }
  if (-not $Label) { $Label = [Net.Dns]::GetHostName() }
  $want = $Seats; if ($want -lt 1 -or $want -gt $script:MAX_SEATS) { $want = $script:MAX_SEATS }
  Say ("pairing as '{0}' with {1} seats..." -f $Label, $want)
  try {
    $start = Invoke-RestMethod -Method Post -Uri "$($script:LOBBY)/api/cabinet/pair/start" -ContentType 'application/json' `
               -Body (@{ device_label = $Label; seats = $want } | ConvertTo-Json) -TimeoutSec 20
  } catch { Say ("could not reach the website to start pairing: {0}" -f $_.Exception.Message); return 1 }
  if (-not $start.ok) { Say ("could not start pairing: {0}" -f $start.error); return 1 }
  Write-DhJson 'PAIRCODE' ([ordered]@{ code = [string]$start.user_code; uri = [string]$start.verification_uri; uri_complete = [string]$start.verification_uri_complete })
  Set-DhActionNote 'Pair' @{ code = [string]$start.user_code; uri = [string]$start.verification_uri; uri_complete = [string]$start.verification_uri_complete
                             expires = (Get-Date).AddSeconds([int]$start.expires_in_s).ToString('o') }
  if ($script:DH_SANDBOX) { Say ("sandbox: would open {0}" -f $start.verification_uri_complete) }
  else { Start-Process ([string]$start.verification_uri_complete) }
  Say ("A browser opened. Sign in and approve this cabinet. If it did not open, go to {0} and enter {1}" -f $start.verification_uri, $start.user_code)
  $deadline = (Get-Date).AddSeconds([int]$start.expires_in_s)
  $pollS = [int]$start.poll_interval_s; if ($pollS -lt 2) { $pollS = 3 }
  $approved = $null
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $pollS
    try { $r = Invoke-RestMethod -Method Post -Uri "$($script:LOBBY)/api/cabinet/pair/poll" -ContentType 'application/json' -Body (@{ device_code = $start.device_code } | ConvertTo-Json) -TimeoutSec 20 } catch { continue }
    if ($r.status -eq 'approved') { $approved = $r; break }
    if (@('expired', 'claimed', 'not_found') -contains $r.status) { Say ("pairing {0}. Press Sign in again." -f $r.status); return 1 }
  }
  if (-not $approved) { Say 'pairing timed out. Press Sign in again.'; return 1 }
  # Same object Setup.ps1 writes after an approval.
  $cab = [pscustomobject]@{
    id = $approved.cabinet_id; label = $approved.label; host_token = $approved.host_token
    seat_count = $(if ([int]$approved.seat_count -ge 1) { [int]$approved.seat_count } else { $want })
    rom_ver = $(if ($approved.rom) { [string]$approved.rom } else { 'derbyoc2' })
    pack_dir = $root; connector_base = $script:LOBBY; local_seats = @()
    clerk_jwks_url = "$($script:CLERK)/.well-known/jwks.json"; clerk_issuer = $script:CLERK
    pack_version = ((Get-Content (Join-Path $root 'VERSION') -Raw -ErrorAction SilentlyContinue) -as [string]).Trim()
  }
  Write-Cab $cab $root
  Backup-DhCabinet
  $s = Get-DhSettings; $s.site_rom = [string]$cab.rom_ver; Set-DhSettings $s
  Say ("paired: {0} ({1}). Keep this PC's DOC Host data private: it holds the cabinet's token." -f $cab.label, $cab.id)
  return 0
}

# ---------------------------------------------------------------------------------------------------
# The video feeds of THIS install, as broadcast-wgc.ps1 sweeps them (doc-stream PR #32, cddc3aa): killing a
# pusher python does not kill its ffmpeg or seat_audio_capture.exe (bare Popen children), which then keep
# publishing cab_<id>/<feed>. Matched by: our pusher scripts' full paths; ffmpeg/capture children of those
# pushers (parent PID); an ffmpeg publishing THIS cabinet's path (cab_<id>/, cab_<id>: or cab_<id>?); this install's
# seat_audio_capture.exe by full path. Never by process name alone.
function Get-DhFeedProcs([int[]]$parents, [string[]]$cabTags) {
  $pushers = @('wgc_relay_push.py', 'audio_relay_push.py') | ForEach-Object { Join-Path $root $_ }
  $capExe = Join-Path $root 'seat_audio_capture.exe'
  $ic = [StringComparison]::OrdinalIgnoreCase
  return @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe' OR Name='ffmpeg.exe' OR Name='seat_audio_capture.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $cl = [string]$_.CommandLine; $nm = [string]$_.Name; $exe = [string]$_.ExecutablePath
    (($nm -ieq 'python.exe' -or $nm -ieq 'pythonw.exe') -and $cl -and @($pushers | Where-Object { $cl.IndexOf($_, $ic) -ge 0 }).Count -gt 0) -or
    (($nm -ieq 'ffmpeg.exe' -or $nm -ieq 'seat_audio_capture.exe') -and $parents -contains [int]$_.ParentProcessId) -or
    ($nm -ieq 'ffmpeg.exe' -and $cl -and @($cabTags | Where-Object { $_ -and $cl.IndexOf($_, $ic) -ge 0 }).Count -gt 0) -or
    ($nm -ieq 'seat_audio_capture.exe' -and (($exe -and $exe -ieq $capExe) -or ($cl -and $cl.IndexOf($capExe, $ic) -ge 0)))
  })
}

function Stop-DhFeeds {
  # The path tag has three spellings on the command line: cab_<id>/ (RTMP publish path / seat feeds),
  # cab_<id>? (RTMP URL ending the path before a query) and cab_<id>: (the SRT URL
  # srt://<relay>:8890?streamid=publish:cab_<id>:cab:<token>, used by the combined bare-path mains ffmpeg).
  # Each ends in a delimiter so cab_12 never matches cab_123.
  $cabTag = @()
  $cab = Read-Cab $root
  if ($cab -and [string]$cab.id) { $i = 'cab_' + [string]$cab.id; $cabTag = @("$i/", "${i}:", "$i?") }
  # Pushers first (a live pusher respawns a dead ffmpeg), then their children and orphans.
  $found = @(Get-DhFeedProcs @() $cabTag)
  $pusherPids = @($found | Where-Object { $_.Name -ieq 'python.exe' -or $_.Name -ieq 'pythonw.exe' } | ForEach-Object { [int]$_.ProcessId })
  $children = @(Get-DhFeedProcs $pusherPids $cabTag)
  $all = @($found) + @($children | Where-Object { $found.ProcessId -notcontains $_.ProcessId })
  $all | Sort-Object { if ($pusherPids -contains [int]$_.ProcessId) { 0 } else { 1 } } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  $deadline = (Get-Date).AddSeconds(10)
  $left = @(Get-DhFeedProcs $pusherPids $cabTag)
  while ($left.Count -gt 0 -and (Get-Date) -lt $deadline) {
    $left | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 250
    $left = @(Get-DhFeedProcs $pusherPids $cabTag)
  }
  if ($all.Count) { Say ("{0} video feed process(es) stopped ({1} pusher(s), {2} encoder/capture)" -f ($all.Count - $left.Count), $pusherPids.Count, ($all.Count - $pusherPids.Count)) }
  if ($left.Count) { Say ("{0} video feed process(es) still running after 10 s: {1}" -f $left.Count, (($left | ForEach-Object { "$($_.Name) $($_.ProcessId)" }) -join ', ')) }
}

function Stop-DhHosting {
  # StopHosting.ps1's order, scoped to this install: tasks, video, services, game.
  $ours = @(Get-DhOurTasks)
  foreach ($t in $ours) { try { Stop-ScheduledTask -TaskName $t.TaskName -ErrorAction SilentlyContinue } catch { } }
  Say ("{0} background task(s) of this install stopped" -f $ours.Count)
  Stop-DhFeeds
  $stop = Join-Path $root 'start-services.ps1'
  if (Test-Path $stop) { try { & $stop -Stop | Out-Null } catch { } }
  foreach ($m in @('slot_station', 'broker.py', 'input_service', 'relay_agent')) {
    foreach ($p in (Get-OurPython $root $m)) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
  }
  # The recover listener of THIS install (a powershell running our DocHostRecover.ps1).
  $rec = Join-Path $script:DH_SCRIPTS 'DocHostRecover.ps1'
  foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
      Where-Object { ([string]$_.CommandLine).IndexOf($rec, [StringComparison]::OrdinalIgnoreCase) -ge 0 })) {
    try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
  }
  Say 'stations, broker, input service, relay agent and remote-restart listener stopped'
  $fly = @(Get-OurFlycast $root)
  foreach ($p in $fly) { try { $p.Kill() } catch { } }
  if ($fly.Count) { Say ("{0} game window(s) closed" -f $fly.Count) } else { Say 'game was not running' }
}

function Invoke-Stop {
  # the host's Stop wins: an undo afterwards never restarts hosting (if the marker cannot be rewritten, a stop
  # request says the same thing to the updater)
  try { Set-DhUpdateWasHosting $false; Clear-DhStopRequested } catch { try { Write-DhStopRequest } catch { } }
  Stop-DhHosting
  Start-Sleep -Seconds 2
  $h = Get-DhBrokerHealth
  if ($h -and -not (Test-DhBrokerOurs)) { Say 'note: another DOC install on this PC is still answering on port 8770 (not touched)' }
  elseif ($h) { Say 'warning: the broker still answers; run Stop hosting again' ; return 1 }
  else { Say 'stopped. Pairing is kept, so Start hosting never re-pairs.' }
  return 0
}

# ---------------------------------------------------------------------------------------------------
function Backup-DhForeignTasks($foreign) {
  $dir = Join-Path $script:DH_DATA ("backups\tasks-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $list = @()
  foreach ($t in $foreign) {
    try {
      $xml = Export-ScheduledTask -TaskName $t.Name -TaskPath $t.Path -ErrorAction Stop
      $f = $t.Name + '.xml'
      [IO.File]::WriteAllText((Join-Path $dir $f), $xml, (New-Object Text.UnicodeEncoding($false, $true)))
      $list += [ordered]@{ name = $t.Name; path = $t.Path; xml = $f; action = $t.Args }
    } catch { Say ("could not export {0}: {1}" -f $t.Name, $_.Exception.Message); return $null }
  }
  $m = [ordered]@{ taken_over_at = (Get-Date -Format o); taken_over_by = $root; restored = $false; tasks = $list }
  [IO.File]::WriteAllText((Join-Path $dir 'tasks.json'), ($m | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
  return $dir
}

function Invoke-Start {
  $cab = Read-Cab $root
  if (-not (Test-Paired $cab)) { Say 'not paired yet: press Sign in and pair first.'; return 4 }

  # Another DOC install's broker on this PC holds the ports every pack uses.
  $h = Get-DhBrokerHealth
  if ($h -and -not (Test-DhBrokerOurs)) {
    Say 'Another DOC Host Pack is running on this PC (port 8770 answers and it is not this install).'
    Say 'Run Stop Hosting in that pack folder first, then press Start hosting again.'
    return 4
  }
  $foreign = @(Get-DhForeignTasks)
  if ($foreign.Count -and $Force) {
    # Taking over another pack folder's doc_home_* tasks: export each one first, so uninstall can put
    # them back (DOC Host never removes a task it did not create).
    $bk = Backup-DhForeignTasks $foreign
    if (-not $bk) { Say 'could not save a copy of the other pack''s tasks; nothing was taken over'; return 1 }
    Write-DhJson 'TASKBACKUP' ([ordered]@{ folder = $bk; tasks = @($foreign | ForEach-Object { $_.Name }) })
    Say ("the other pack's {0} task(s) were saved to {1}; uninstalling DOC Host offers to put them back" -f $foreign.Count, $bk)
  }
  if ($foreign.Count -and -not $Force) {
    Write-DhJson 'NEEDFORCE' ([ordered]@{ tasks = @($foreign | ForEach-Object { $_.Name + ': ' + $_.Args.Substring(0, [Math]::Min(160, $_.Args.Length)) }) })
    Say ("{0} hosting task(s) on this PC belong to another DOC pack folder. DOC Host will take them over only if you say so." -f $foreign.Count)
    return 3
  }

  # ROMs present (Setup.ps1's preflight).
  $game = Get-GameByRom $Rom
  if (-not $game) { $game = Get-GameByRom ([string]$cab.rom_ver) }
  if (-not $game) { $game = $script:GAMES[0] }
  $z = Join-Path $root ("ROMs\{0}\{0}.zip" -f $game.Rom)
  if (-not (Test-Path $z)) { Say ("game files missing for {0}: reinstall DOC Host" -f $game.Name); return 1 }

  $seats = $Seats; if ($seats -lt 1) { $seats = Get-SeatCount $cab }
  if ($seats -gt $script:MAX_SEATS) { $seats = $script:MAX_SEATS }
  $localSeats = @(); if ($LocalPlay) { $localSeats = @(1) }
  $doVideo = -not $NoVideo
  $s = Get-DhSettings; $s.video = [bool]$doVideo; Set-DhSettings $s

  # Stop whatever this install was running, so Start is also "apply new settings".
  Stop-DhHosting

  $cab | Add-Member -NotePropertyName seat_count -NotePropertyValue $seats -Force
  $cab | Add-Member -NotePropertyName local_seats -NotePropertyValue $localSeats -Force
  $cab | Add-Member -NotePropertyName rom_ver -NotePropertyValue $game.Rom -Force
  $cab | Add-Member -NotePropertyName pack_dir -NotePropertyValue $root -Force
  $cab | Add-Member -NotePropertyName connector_base -NotePropertyValue $script:LOBBY -Force
  Write-Cab $cab $root
  Backup-DhCabinet
  Say ("cabinet.json: {0} seat(s), game {1}{2}" -f $seats, $game.Name, $(if ($localSeats.Count) { ', seat 1 reserved for you' } else { '' }))
  # The website follows the game this PC runs (2026-10-19): the relay agent reports it on every heartbeat, and the
  # site serves players that game. A game chosen on the website after this PC started its last one is offered by the
  # window at the next Start (Get-DhSiteRom); starting a different one here is the newer choice, so the site follows.
  $siteNote = Get-DhSiteRom
  if ($siteNote -and $siteNote -ne $game.Rom) {
    Write-DhJson 'SITEROM' ([ordered]@{ site = $siteNote; local = $game.Rom })
    Say ("The website had this cabinet set to '{0}'. You started '{1}', so the website switches to it within a minute." -f $siteNote, $game.Rom)
  }

  New-Item -ItemType Directory -Path $logs -Force | Out-Null
  # Tasks run through "DocHostTask.exe --hidden-run" (the stable launcher, Get-DhTaskLauncher): a GUI exe, so the
  # task opens no console window, and it starts PowerShell with no window. A task running powershell.exe directly
  # flashes a console (and the listener's never closed); hosts close those on instinct, which kills the step.
  # powershell.exe only if no launcher is there.
  $hostExe = Get-DhTaskLauncher
  $hidden = [bool]$hostExe
  $ps = $(if ($hidden) { $hostExe } else { 'powershell.exe' })
  $recArgs = '-PackRoot ' + (ConvertTo-PsLiteral $root)
  $tasks = @(
    @{ Suffix = 'services';   Arg = (New-TaskPsLine $root (Join-Path $root 'start-services.ps1') '' (Join-Path $logs 'services.log')) }
    @{ Suffix = 'windowless'; Arg = (New-TaskPsLine $root (Join-Path $root 'windowless.ps1') '' (Join-Path $logs 'windowless.log')) }
    @{ Suffix = 'broadcast';  Arg = (New-TaskPsLine $root (Join-Path $root 'broadcast-wgc.ps1') "-Seats $seats -NoChromeCrop" (Join-Path $logs 'broadcast.log')) }
    @{ Suffix = 'game';       Arg = (New-GameTaskArg $root $game) }
    @{ Suffix = 'recover';    Arg = (New-TaskPsLine $root (Join-Path $script:DH_SCRIPTS 'DocHostRecover.ps1') $recArgs (Join-Path $logs 'recover_task.log')) }
  )
  if ($script:DH_SANDBOX) {
    foreach ($t in $tasks) { Say ("sandbox: would register {0}: {1} {2}" -f (Get-TaskName $t.Suffix), $ps, $t.Arg) }
    Say 'sandbox: would start services, game, borderless pass, video and the remote-restart listener (skipped)'
    return 0
  }
  foreach ($t in $tasks) {
    $arg = $(if ($hidden) { '--hidden-run ' + $t.Arg } else { $t.Arg })
    try { $n = Register-HomeTask $t.Suffix $ps $arg; Say ("task {0} registered" -f $n) }
    catch { Say ("could not register {0}: {1}" -f (Get-TaskName $t.Suffix), $_.Exception.Message); return 1 }
  }

  Say 'starting stations, broker, input service and relay agent...'
  if (-not (Start-HomeTask 'services')) { Say 'services task would not start'; return 1 }
  Start-Sleep -Seconds 8
  Say 'starting the game...'
  Start-HomeTask 'game' | Out-Null
  $rbOk = $true
  if ($game.Rom -eq 'docrebal') {
    . (Join-Path $root 'setup\RebalanceBoot.ps1')
    $rbOk = $false
    $deadline = (Get-Date).AddSeconds(75)
    do { $rb = Get-RebalanceBootState $root $seats; if ($rb.Ready) { $rbOk = $true; break }; Start-Sleep -Seconds 2 } while ((Get-Date) -lt $deadline)
    if (-not $rbOk) { Say ('Rebalance startup incomplete. Missing: ' + ($rb.MissingBoards -join ', ')) }
  } else {
    Say ("{0} windows open: Main plus {1} satellite(s). Click the game picture once in each (MAIN first)." -f ($seats + 1), $seats)
    Start-Sleep -Seconds 25
  }
  Start-HomeTask 'windowless' | Out-Null
  # the Right main screen opens only when the race link starts: give it up to 20 s, then say which are up
  $mr = Set-DhMainsBorderless $root
  for ($w = 0; $w -lt 10 -and $mr.Found -lt 2; $w++) { Start-Sleep -Seconds 2; $mr = Set-DhMainsBorderless $root }
  Say (Get-DhMainsMessage $mr '')
  $n = Set-GamePriority $root 'AboveNormal'
  if ($n) { Say ("game priority raised on {0} window(s)" -f $n) }
  if ($doVideo -and $rbOk) {
    Say 'starting the video broadcast...'
    Start-HomeTask 'broadcast' | Out-Null
    Start-Sleep -Seconds 10
    $e = Set-EncoderPriority $root 'BelowNormal'
    if ($e) { Say ("encoder priority lowered on {0} feed(s)" -f $e) }
  } elseif (-not $doVideo) { Say 'video off: remote seats are not playable, local play only' }
  Start-HomeTask 'recover' | Out-Null

  # Verify, as Setup.ps1 does.
  $store = $null
  foreach ($i in 1..10) { $hh = Get-DhBrokerHealth; if ($hh) { $store = [string]$hh.store; break }; Start-Sleep -Seconds 3 }
  if ($store) { Say ("broker healthy (store: {0})" -f $store) } else { Say 'broker not answering: open logs, services.log'; return 1 }
  $down = @(); foreach ($p in (Get-SeatPorts $seats)) { if (-not (Test-Port $p)) { $down += $p } }
  if ($down.Count) { Say ('seat stations not listening on: ' + ($down -join ', ')) } else { Say ("all {0} seat stations listening" -f $seats) }
  # Report-only checks against the lobby and hub. An updater restart skips them ($SkipLobbyCheck from
  # Restart-DhHostingForUpdate): a slow reply must never hold the action lock (PowerShell 5.1's -TimeoutSec does
  # not bound a dripped body), and Doctor shows the same thing on demand.
  if ($SkipLobbyCheck) { Say 'lobby and hub checks skipped after an update (press Doctor to see them)' }
  else {
    if (Test-Tunnel $cab.id) { Say 'the lobby can reach this cabinet through the relay hub' } else { Say 'the hub link is not answering yet: give it a minute, then press Doctor' }
    $ep = Get-LobbyEndpoints $cab.id
    if (-not $ep.Ok) { foreach ($i in 1..6) { Start-Sleep -Seconds 10; $ep = Get-LobbyEndpoints $cab.id; if ($ep.Ok) { break } } }
    if ($ep.Ok) { Say 'the lobby has this cabinet''s seat and video addresses' } else { Say 'the lobby has no addresses for this cabinet yet: press Doctor in a minute' }
  }
  Say ("hosting: {0}, {1} seat(s)" -f $game.Name, $seats)
  return 0
}

# ---------------------------------------------------------------------------------------------------
function Invoke-FixPicture {
  $cab = Read-Cab $root
  if (-not (Test-Paired $cab)) { Say 'not paired yet'; return 4 }
  $fly = @(Get-OurFlycast $root)
  if (-not $fly.Count) { Say 'the game is not running: press Start hosting'; return 1 }
  $seats = Get-SeatCount $cab
  # Satellites (windowless.ps1 is scoped to this install's folder) then mains, then republish without
  # the chrome crop. Flycast is never restarted here.
  try { & (Join-Path $root 'windowless.ps1') | Out-Null } catch { }
  $mr = Set-DhMainsBorderless $root
  Say ('satellites re-stripped; ' + (Get-DhMainsMessage $mr))
  $s = Get-DhSettings
  if (-not $s.video) { Say 'video is off for this cabinet: nothing to republish'; return 0 }
  if ($script:DH_SANDBOX) { Say 'sandbox: would restart the video feeds with -NoChromeCrop'; return 0 }
  if (Restart-Broadcast $root $seats) {
    Start-Sleep -Seconds 6
    $e = Set-EncoderPriority $root 'BelowNormal'
    Say ("video restarted for {0} seat(s), full picture ({1} encoder(s) BelowNormal)" -f $seats, $e)
    Say 'players: hard-refresh the lobby page (Ctrl+Shift+R)'
    return 0
  }
  Say 'could not restart the video: open logs, broadcast.log'
  return 1
}

function Invoke-RestartGame {
  $cab = Read-Cab $root
  if (-not (Test-Paired $cab)) { Say 'not paired yet'; return 4 }
  Set-DhLastRestart      # the host's own restart also starts the remote Restart cooldown
  if ($script:DH_SANDBOX) { Say 'sandbox: would run setup\RestartGame.ps1 -Quiet'; return 0 }
  & (Join-Path $root 'setup\RestartGame.ps1') -Quiet *>&1 | ForEach-Object { Say ([string]$_) }
  # one pass, no wait: after a restart the game sits at attract and the Right main screen only opens when the
  # race link starts, so the message tells the host to press Fix picture then
  Say (Get-DhMainsMessage (Set-DhMainsBorderless $root) '')
  return 0
}

function Invoke-Doctor {
  $cab = Read-Cab $root
  if ($script:DH_SANDBOX -and (Test-Paired $cab)) {
    Say 'sandbox: the pack Doctor would contact the live lobby and hub for this cabinet; skipped'
    return 0
  }
  & (Join-Path $root 'setup\Doctor.ps1') -Quiet *>&1 | ForEach-Object { Say ([string]$_) }
  return 0
}

function Invoke-SetOption {
  $s = Get-DhSettings
  switch ($Name) {
    'remote_recover' { $s.remote_recover = ($Value -eq '1' -or $Value -eq 'true') }
    'video'          { $s.video = ($Value -eq '1' -or $Value -eq 'true') }
    'update_mode'    { if ($Value -notin @('auto', 'ask')) { Say 'update_mode is auto or ask'; return 1 }; $s.update_mode = $Value }
    'update_channel' { if ($Value -notin @('stable', 'beta')) { Say 'update_channel is stable or beta'; return 1 }; $s.update_channel = $Value }
    default { Say ("unknown option {0}" -f $Name); return 1 }
  }
  Set-DhSettings $s
  Say ("{0} = {1}" -f $Name, $s[$Name])
  return 0
}

# ---- updates (doc-ops #117 Phase 1, D-015) --------------------------------------------------------------
function Get-DhUpdateSettings {
  # update_mode: auto (install when idle; D-015 default) or ask. channel: stable or beta.
  $s = Get-DhSettings
  $mode = $(if ($s.update_mode -in @('auto', 'ask')) { [string]$s.update_mode } else { 'auto' })
  $ch = $(if ($s.update_channel -in @('stable', 'beta')) { [string]$s.update_channel } else { 'stable' })
  return @{ Mode = $mode; Channel = $ch }
}
function Find-DhUpdate([switch]$Auto, [switch]$NoHash) {
  # Returns @{ Code; Manifest; Plan; Bytes } or a code with a message already said. 0 = an update is ready to apply.
  $cab = Read-Cab $root
  if (-not (Test-DhUpdateConfigured)) { Say 'updates are not set up yet in this version of DOC Host'; return @{ Code = 3 } }
  if (-not (Test-Paired $cab)) { Say 'updates need this PC to be paired first (Sign in and pair)'; return @{ Code = 4 } }
  $us = Get-DhUpdateSettings; $iv = Get-DhInstalledVersion
  try { $rm = Get-DhRemoteManifest $cab $us.Channel } catch { Say ("could not reach the website to check for updates: {0}" -f $_.Exception.Message); return @{ Code = 1 } }
  if (-not $rm) { Say ("DOC Host {0} is up to date" -f $iv); Save-DhUpdateState ([ordered]@{ status = 'current'; installed = $iv }); Write-DhJson 'UPDATE' ([ordered]@{ status = 'current'; installed = $iv }); return @{ Code = 2 } }
  $r = Read-DhManifest $rm.Bytes $rm.Sig $us.Channel $iv
  if ($r.UpToDate) { Say ("DOC Host {0} is up to date" -f $iv); Save-DhUpdateState ([ordered]@{ status = 'current'; installed = $iv }); Write-DhJson 'UPDATE' ([ordered]@{ status = 'current'; installed = $iv }); return @{ Code = 2 } }
  if (-not $r.Ok) { Say ("update refused: {0}" -f $r.Error); Save-DhUpdateState ([ordered]@{ status = 'refused'; installed = $iv; error = $r.Error }); Write-DhJson 'UPDATE' ([ordered]@{ status = 'refused'; installed = $iv; error = $r.Error }); return @{ Code = 1 } }
  if ($Auto -and (@(Get-DhFailedVersions) -contains [string]$r.Manifest.version)) {
    $m = ("update {0} failed on this PC before: waiting for a newer release (Update now in DOC Host retries it)" -f $r.Manifest.version)
    Say $m; $st = [ordered]@{ status = 'failed'; installed = $iv; version = [string]$r.Manifest.version }
    Save-DhUpdateState $st; Write-DhJson 'UPDATE' $st; return @{ Code = 2 }
  }
  try { $plan = Get-DhUpdatePlan $r.Manifest $script:DH_APP -NoHash:$NoHash }
  catch {
    if ($_.Exception.Message -notlike 'layout change:*') { throw }
    # refused each time it is checked (it costs nothing: before any download), never set aside, so it installs by
    # itself once the host moves the blocking file or folder (review of PR #45 round 14)
    $e = $_.Exception.Message
    Say ("update {0} refused: {1}" -f $r.Manifest.version, $e)
    $st = [ordered]@{ status = 'refused'; installed = $iv; version = [string]$r.Manifest.version; error = $e }
    Save-DhUpdateState $st; Write-DhJson 'UPDATE' $st; return @{ Code = 1 }
  }
  $plan = @($plan); $bytes = [int64](($plan | Measure-Object -Property Size -Sum).Sum)
  $info = [ordered]@{ status = 'available'; installed = $iv; version = [string]$r.Manifest.version; required = [bool]$r.Manifest.required
                      notes = [string]$r.Manifest.notes; files = @($plan).Count; bytes = $bytes }
  Save-DhUpdateState $info; Write-DhJson 'UPDATE' $info
  Say ("update {0} available: {1} file(s), {2:N1} MB{3}" -f $r.Manifest.version, @($plan).Count, ($bytes / 1MB), $(if ($r.Manifest.required) { ' (required)' } else { '' }))
  return @{ Code = 0; Manifest = $r.Manifest; Plan = $plan; Cab = $cab }
}
function Invoke-CheckUpdate {
  # The window learns here that updates are off (and why) instead of offering an Update now that would fail.
  if (-not (Test-DhDataDirTrusted)) {
    $st = [ordered]@{ status = 'off'; installed = (Get-DhInstalledVersion); why = $script:DH_TRUST_WHY }; Save-DhUpdateState $st; Write-DhJson 'UPDATE' $st
    Say ("updates are off on this PC: {0}" -f $script:DH_TRUST_WHY); return 1
  }
  # While hosting, the check never hashes files (the apply plans again, idle, with hashing).
  $c = (Find-DhUpdate -NoHash:(Test-DhHostingNow)).Code; return $(if ($c -eq 2) { 0 } else { $c })   # up to date is a success
}
# Stop pressed while an update holds the action lock cannot run, so it leaves this note instead; every restart
# the updater would do honours it (the host's Stop wins), and the host's next Start clears it.
# It applies to the update running now: each update run clears it when it starts, and Stop and Start clear it.
$script:DH_STOP_REQ = Join-Path $script:DH_DATA 'stop-requested.json'
function Test-DhStopRequested { return (Test-Path -LiteralPath $script:DH_STOP_REQ) }
function Clear-DhStopRequested { Remove-Item -LiteralPath $script:DH_STOP_REQ -Force -ErrorAction SilentlyContinue }
function Write-DhStopRequest {
  Write-DhFileAtomic $script:DH_STOP_REQ ((@{ at = (Get-Date).ToUniversalTime().ToString('o') }) | ConvertTo-Json -Compress)
  try { Set-DhUpdateWasHosting $false } catch { }   # an undo of this update never restarts hosting either
}
function Restart-DhHostingForUpdate {
  # Start again with what the last Start saved (cabinet.json and settings), as the window would.
  # 6 = skipped because the host pressed Stop during this update.
  if (Test-DhStopRequested) { Say 'the host pressed Stop during the update: hosting is not started again'; return 6 }
  $cab = Read-Cab $root
  $Seats = [int]$cab.seat_count; $Rom = [string]$cab.rom_ver
  $LocalPlay = [bool](@($cab.local_seats).Count); $NoVideo = -not [bool](Get-DhSettings).video
  $SkipLobbyCheck = $true
  return @(Invoke-Start)[-1]
}
function Test-DhHealthyAfterUpdate([int]$waitS = 150) {
  $deadline = (Get-Date).AddSeconds($waitS)
  while ((Get-Date) -lt $deadline) {
    if (@(Get-OurFlycast $root).Count -gt 0 -and (Get-DhBrokerHealth) -and (Test-DhBrokerOurs)) { return $true }
    Start-Sleep -Seconds 5
  }
  return $false
}
function Repair-DhInterruptedUpdate([switch]$NoRestart, [switch]$Force) {
  # An update killed part way is undone, completely, from its journal. 0 = nothing left over (or undone),
  # 2 = waiting (a live broker reports players), 1 = could not be fully undone, 3 = undone and hosting started again,
  # 5 = undone but hosting did not start again. Hosting is stopped for the undo
  # when pack files are involved; a broker that does not answer never blocks it (a broken game must be undoable).
  # Hosting comes back afterwards if it was on before the update (the marker says so) or when this stopped it,
  # unless the caller starts it itself (-NoRestart: Start, Restart game). -Force: the caller interrupts players
  # anyway (Start, Restart game), so it never waits for them.
  $ip = Get-DhUpdateInProgress
  if (-not $ip) { return 0 }
  if (-not (Test-DhDataDirTrusted)) {
    # the journal, backups and hashes the undo would copy into the install come from the data folder (round 17)
    Say ("an interrupted update cannot be undone here: {0}. Start hosting is refused until then. Reinstalling DOC Host clears it (your data folder and everything in it are kept); updates stay off until the data folder is one only you can change, such as the default one." -f $script:DH_TRUST_WHY)
    return 1
  }
  $wasH = [bool]$ip.was_hosting
  $jr = Read-DhJournal
  $packJ = @($jr | Where-Object { $_.Path -like 'pack/*' }).Count -gt 0
  $hostJ = $packJ -and (Test-DhHostingNow)
  if ($hostJ) {
    if (-not $Force -and (Get-DhBrokerHealth)) {
      $idleR = Test-DhUpdateIdle
      if (-not $idleR.Idle) { Say ("an interrupted update waits to be undone: {0}" -f $idleR.Why); return 2 }
    }
    Say 'an earlier update was interrupted: stopping hosting to undo it'; Stop-DhHosting
  }
  # was_hosting with no pack swap journaled: the update died during or just before its stop. A cabinet left
  # half stopped (something still running, broker not answering) is stopped fully so it can start cleanly; a
  # working one (broker answering) is left alone.
  if ($wasH -and -not $hostJ -and (Test-DhHostingNow) -and -not (Get-DhBrokerHealth)) {
    Say 'an interrupted update left hosting half stopped: stopping it fully first'; Stop-DhHosting
  }
  $preVer = Get-DhInstalledVersion                  # = from for an unfinished attempt (stale and finished markers differ)
  if (-not (Resume-DhInterruptedUpdate)) {
    Say 'an interrupted update could not be fully undone: hosting stays stopped and no new update runs until it is. It retries every 30 minutes; if this stays, reinstall DOC Host (your data and horses are kept). Copies are in the updates folder.'
    return 1
  }
  Say 'an interrupted update was undone; the PC is back on its previous version'
  # a killed attempt counts as a failure, so a version that keeps dying (a stalled restart, a time-limit kill)
  # is set aside after three tries instead of cycling stop, swap, undo forever
  if ($ip.to -and $preVer -eq [string]$ip.from -and (Get-DhInstalledVersion) -ne [string]$ip.to) { try { Add-DhFailedVersion ([string]$ip.to) } catch { } }
  # Only ever brings hosting back when it is DOWN (never restarts a live game) and when an update took it down
  # (was_hosting, set after the stop succeeded) or this undo stopped it.
  if (($hostJ -or $wasH) -and -not $NoRestart -and -not (Test-DhHostingNow)) {
    $sc = @(Restart-DhHostingForUpdate)[-1]
    if ($sc -eq 0) { return 3 }
    if ($sc -eq 6) { return 0 }                     # the host asked to stop: undone, hosting left stopped
    Say ("hosting did not start again after the undo (code {0}): press Start hosting" -f $sc)
    return 5
  }
  return 0
}
function Invoke-DhRecover([string]$for) {
  # Never waits for the lock, as the undo never did: a running update holds it for its whole swap and health check
  # (its marker and copy exist meanwhile), and a busy button must answer at once.
  $al = Enter-DhAction 0
  if (-not $al) { return 9 }
  Set-DhActionNote $for
  try {
    if (Get-DhUpdateInProgress) { Say 'an earlier update was interrupted: undoing it with the version that started it' }
    switch ($for) {
      'Start'       { Clear-DhStopRequested; $rr = Repair-DhInterruptedUpdate -NoRestart -Force }
      'RestartGame' { Clear-DhStopRequested; $rr = Repair-DhInterruptedUpdate -Force }
      default       { $rr = Repair-DhInterruptedUpdate; if ($rr -ne 1 -and $rr -ne 2) { Clear-DhStopRequested } }   # Invoke-ApplyUpdate's rule
    }
    return (10 + [int]@($rr)[-1])
  } finally { Clear-DhActionNote; Exit-DhAction $al }
}
function Invoke-DhWithActionLock([string]$name, [scriptblock]$body, [int]$waitMs = 0) {
  # The update downloads WITHOUT the action lock (a slow or stalled download never blocks Start, Stop or Restart
  # game); it takes the lock only to undo or swap. $null = another action held it for the whole wait.
  $al = Enter-DhAction $waitMs
  if (-not $al) { return $null }
  Set-DhActionNote $name
  try { return @(& $body)[-1] } finally { Clear-DhActionNote; Exit-DhAction $al }
}
function Invoke-ApplyUpdate([switch]$Auto) {
  # from the start of this run (the recovery copy's undo may already have used part of the task's hour)
  $t0 = Get-Date; try { $t0 = (Get-Process -Id $PID).StartTime } catch { }
  # a fresh run handed over after the copy's undo counts from the run that started the task (DOCHOST_T0 can only
  # make this guard stricter: an earlier time is all it is ever used for)
  if ($script:DH_T0_IN) {
    try {
      $t1 = [DateTime]::Parse($script:DH_T0_IN, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
      if ($t1 -lt $t0 -and ((Get-Date) - $t1).TotalMinutes -le 65) { $t0 = $t1 }   # never older than the task's hour
    } catch { }
  }
  # a request from an earlier, finished run is done with; one beside an interrupted update is still the host's
  # word for its undo (cleared after the undo below)
  if (-not (Get-DhUpdateInProgress)) { Clear-DhStopRequested }
  $actName = $(if ($Auto) { 'AutoUpdate' } else { 'ApplyUpdate' })
  if (Test-DhDataDirTrusted) { Remove-Item -LiteralPath (Join-Path $script:DH_UPD 'updates-off.txt') -Force -ErrorAction SilentlyContinue }
  elseif (-not (Get-DhUpdateInProgress)) {
    # an update's backups, journal and recovery copy live in the data folder: none if others can change it (round 17).
    # The background check says so once a day and counts as done (it would only repeat itself every 30 minutes).
    if ($Auto) {
      $wf = Join-Path $script:DH_UPD 'updates-off.txt'; $today = (Get-Date).ToString('yyyy-MM-dd')
      $last = ''; try { $last = ([IO.File]::ReadAllText($wf)).Trim() } catch { }
      if ($last -eq $today) { return 0 }
      try { New-Item -ItemType Directory -Path $script:DH_UPD -Force | Out-Null; [IO.File]::WriteAllText($wf, $today) } catch { }
    }
    $st = [ordered]@{ status = 'off'; installed = (Get-DhInstalledVersion); why = $script:DH_TRUST_WHY }
    try { Save-DhUpdateState $st } catch { }; Write-DhJson 'UPDATE' $st
    Say ("updates are off on this PC: {0}. A plain reinstall keeps the same data folder; to turn updates on, the data folder must be one only you can change, such as the default one (DOC support can help move it)." -f $script:DH_TRUST_WHY)
    return $(if ($Auto) { 0 } else { 1 })
  }
  if (Get-DhUpdateInProgress) {
    $rr = Invoke-DhWithActionLock $actName { Repair-DhInterruptedUpdate }
    if ($null -eq $rr) { Say 'an interrupted update waits: another DOC Host action is running'; return 0 }
    if ($rr -eq 2) { return 0 }
    if ($rr -ne 1) { Clear-DhStopRequested }        # the undo honoured it
    if ($rr -eq 1 -or $rr -eq 5) { return 1 }
  }
  # The background run checks idle FIRST, so nothing heavy (planning, hashing) happens while players are seated.
  if ($Auto) {
    $idle0 = Test-DhUpdateIdle
    if (-not $idle0.Idle) { Say ("update check skipped: {0}" -f $idle0.Why); return 0 }
  }
  $f = Find-DhUpdate -Auto:$Auto
  if ($f.Code -ne 0) { return $(if ($f.Code -eq 2) { 0 } else { $f.Code }) }
  $us = Get-DhUpdateSettings
  if ($Auto -and $us.Mode -eq 'ask' -and -not $f.Manifest.required) { Say 'update waiting for the host (Update now in DOC Host)'; return 0 }
  $idle = Test-DhUpdateIdle
  if (-not $idle.Idle) {
    Say ("update waits: {0}" -f $idle.Why)
    $st = [ordered]@{ status = 'waiting'; installed = (Get-DhInstalledVersion); version = [string]$f.Manifest.version; why = $idle.Why
                      files = @($f.Plan).Count; bytes = [int64]((@($f.Plan) | Measure-Object -Property Size -Sum).Sum) }
    Save-DhUpdateState $st; Write-DhJson 'UPDATE' $st
    return 0
  }
  $ver = [string]$f.Manifest.version; $old = Get-DhInstalledVersion
  $staging = Join-Path $script:DH_UPD ("staging-" + $ver); $backup = Join-Path $script:DH_UPD ("backup-" + $old)
  # staging folders of other versions (an abandoned download) are dropped; this version's resumes
  Get-ChildItem -LiteralPath $script:DH_UPD -Directory -Filter 'staging-*' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $staging } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
  # Room: staging (the new files) and backups (the old ones) live under the data folder; the new copies sit beside
  # the renamed-aside originals in the install folder until cleanup. Sum per drive (often both are C:).
  $planBytes = [int64]((@($f.Plan) | Measure-Object -Property Size -Sum).Sum)
  $oldBytes = [int64]0; foreach ($x in @($f.Plan)) { if (Test-Path -LiteralPath $x.Full) { $oldBytes += (Get-Item -LiteralPath $x.Full).Length } }
  $needBy = @{}
  $dDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($script:DH_DATA)); $aDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($script:DH_APP))
  $needBy[$dDrive] = [int64]$needBy[$dDrive] + $planBytes + $oldBytes + 100MB
  $needBy[$aDrive] = [int64]$needBy[$aDrive] + $planBytes + 100MB
  foreach ($drv in $needBy.Keys) {
    try { $free = (New-Object IO.DriveInfo $drv).AvailableFreeSpace } catch { $free = [int64]::MaxValue }
    if ($free -lt $needBy[$drv]) { Say ("not enough free disk space for the update on {0} (need {1:N0} MB)" -f $drv, ($needBy[$drv] / 1MB)); return 1 }
  }
  Say ("downloading {0} file(s)..." -f @($f.Plan).Count)
  try { Get-DhUpdateObjects $f.Plan $staging $f.Cab } catch { Say ("download stopped: {0} (nothing changed; it resumes next time)" -f $_.Exception.Message); return 1 }
  # Near the scheduled task's 1-hour limit, do not start a swap the limit could cut (the next run resumes from
  # the staged files, which are kept).
  if ($Auto -and ((Get-Date) - $t0).TotalMinutes -gt 45) { Say 'update downloaded; the install runs on the next check (time limit)'; return 0 }
  # A manual Update now waits up to 2 minutes for another action to finish; the background run tries once.
  $rt = Invoke-DhWithActionLock $actName { Install-DhStagedUpdate } $(if ($Auto) { 0 } else { 120000 })
  if ($null -eq $rt) {
    Say 'update downloaded but NOT installed: another DOC Host action is running (it installs on a later check)'
    return $(if ($Auto) { 0 } else { 2 })
  }
  return $rt
}
function Install-DhStagedUpdate {
  # Runs under the action lock, inside Invoke-ApplyUpdate (reads its $f, $ver, $old, $staging, $backup, $Auto).
  # Idle again: the download can take long, and players may have sat down since.
  $idle = Test-DhUpdateIdle
  if (-not $idle.Idle) {
    Say ("update downloaded; it installs when {0} no longer applies" -f $idle.Why)
    $st = [ordered]@{ status = 'waiting'; installed = $old; version = $ver; why = $idle.Why; files = @($f.Plan).Count; bytes = [int64]0 }
    Save-DhUpdateState $st; Write-DhJson 'UPDATE' $st
    return 0
  }
  # Pack files are in use while hosting: stop, swap, start again. Only DOC Host's own files: no restart; the
  # restart listener is refreshed so it runs the new script. The marker is written BEFORE hosting stops (a kill
  # after it is undone); was_hosting is set just before the stop, so the undo also brings hosting back (only
  # ever when hosting is down, never against a Stop the host pressed).
  $packTouched = @($f.Plan | Where-Object { $_.Path.StartsWith('pack/', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
  $wasHosting = Test-DhHostingNow
  try { Set-DhUpdateInProgress $old $ver $false } catch { Say ("could not start the update: {0} (nothing changed)" -f $_.Exception.Message); return 1 }
  # the frozen copy of this code that will undo the update if it is cut off part way (review of PR #45)
  try { Save-DhRecoveryKit } catch { Clear-DhUpdateInProgress; Say ("could not start the update: could not save the recovery copy: {0} (nothing changed)" -f $_.Exception.Message); return 1 }
  if ($packTouched -and $wasHosting) {
    # set before the stop: a kill during it is undone and hosting comes back (the undo restarts only a cabinet
    # that is down, finishes a half-stopped one, and the host's own Stop clears this)
    Set-DhUpdateWasHosting $true
    Say 'stopping hosting for the update (nobody is seated)'; Stop-DhHosting
    $stopWait = (Get-Date).AddSeconds(15)             # a killed game takes a moment to exit
    while ((Test-DhHostingNow) -and (Get-Date) -lt $stopWait) { Start-Sleep -Milliseconds 500 }
    if (Test-DhHostingNow) {
      Clear-DhUpdateInProgress                        # nothing swapped yet
      try { Add-DhFailedVersion $ver } catch { }       # counts, so a stop that never completes is not retried every 30 minutes
      Say 'hosting did not stop fully: starting it again; the update waits for a later check (nothing changed)'
      Restart-DhHostingForUpdate | Out-Null
      return 1
    }
  }
  try { $done = Install-DhUpdateFiles $f.Plan $staging $backup }
  catch {
    Say $_.Exception.Message; Add-DhFailedVersion $ver
    if ($_.Exception.Message -like '*ROLLBACK INCOMPLETE*') {
      # the marker and journal stay: the next run retries the undo; hosting stays stopped on mixed files
      $st = [ordered]@{ status = 'failed'; installed = $old; version = $ver }; Save-DhUpdateState $st; Write-DhJson 'UPDATE' $st
      return 1
    }
    Clear-DhUpdateInProgress
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    if ($packTouched -and $wasHosting) { Restart-DhHostingForUpdate | Out-Null }
    $st = [ordered]@{ status = 'failed'; installed = $old; version = $ver }; Save-DhUpdateState $st; Write-DhJson 'UPDATE' $st
    return 1
  }
  $rec = Read-DhInstalled
  try {
    $map = [ordered]@{}
    if ($rec -and $rec.files) { foreach ($p in $rec.files.PSObject.Properties) { $map[$p.Name] = [string]$p.Value } }
    foreach ($x in $f.Manifest.files) { if (-not (Test-DhPreserved ([string]$x.path) @($f.Manifest.preserve)) -and -not (Test-DhCreateOnly ([string]$x.path)) -and -not $x.create_only) { $map[[string]$x.path] = [string]$x.sha256 } }
    foreach ($x in @($f.Plan | Where-Object { $_.Remove })) { $map.Remove($x.Path) }
    if (-not ($packTouched -and $wasHosting)) {
      Save-DhInstalled $ver $map                      # the record first, then the marker: a crash between is "finished"
      Clear-DhUpdateInProgress
    }
  } catch {
    # Never leave new files without the record that says so: put the old files back.
    Say ("could not record the update ({0}): rolling back" -f $_.Exception.Message)
    $bad = Restore-DhUpdateFiles $done; Add-DhFailedVersion $ver
    if ($bad.Count) { Say ("ROLLBACK INCOMPLETE for: {0} (copies in {1}); the next run retries" -f ($bad -join ', '), $backup); return 1 }
    Clear-DhUpdateInProgress
    if ($packTouched -and $wasHosting) { Restart-DhHostingForUpdate | Out-Null }
    return 1
  }
  if ($packTouched -and $wasHosting) {
    Say 'starting hosting again...'
    Restart-DhHostingForUpdate | Out-Null
    # the marker and journal stay until the game is healthy: a crash during the check or its rollback is undone
    # from the journal on the next run
    if (Test-DhStopRequested) {
      if (Test-DhHostingNow) { Stop-DhHosting }      # Stop pressed while the restart was already running: carry it out
      Save-DhInstalled $ver $map; Clear-DhUpdateInProgress; Say 'updated; hosting stays stopped as the host asked'
    }
    elseif (Test-DhHealthyAfterUpdate) { Save-DhInstalled $ver $map; Clear-DhUpdateInProgress }
    else {
      Say ("the game did not come back healthy after {0}: rolling back to {1}" -f $ver, $old)
      Stop-DhHosting
      $bad = Restore-DhUpdateFiles $done; if ($bad.Count) { Say ("ROLLBACK INCOMPLETE for: {0} (copies in {1})" -f ($bad -join ', '), $backup); return 1 }
      Clear-DhUpdateInProgress
      Add-DhFailedVersion $ver -Hard                  # the game did not come back: do not try this one again by itself
      Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
      if ($rec) { Save-DhInstalled ([string]$rec.version) $rec.files } else { Remove-Item -LiteralPath $script:DH_INSTALLED -Force -ErrorAction SilentlyContinue }
      Restart-DhHostingForUpdate | Out-Null
      Save-DhUpdateState ([ordered]@{ status = 'rolled_back'; version = $ver; installed = $old })
      Write-DhJson 'UPDATE' ([ordered]@{ status = 'rolled_back'; version = $ver; installed = $old })
      return 1
    }
  } elseif (@(Get-DhOurTasks | Where-Object { $_.TaskName -eq (Get-TaskName 'recover') }).Count) {
    $recScript = Join-Path $script:DH_SCRIPTS 'DocHostRecover.ps1'
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $cl = [string]$_.CommandLine; $cl.IndexOf($recScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $cl.IndexOf($recScript.Replace("'", "''"), [StringComparison]::OrdinalIgnoreCase) -ge 0 })) {
      try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
    }
    if ($wasHosting) { Start-HomeTask 'recover' | Out-Null }
  }
  Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  Clear-DhFailedVersions                            # installed: older failures no longer matter
  Remove-DhOldBackups 2
  $exeChanged = @($f.Plan | Where-Object { $_.Path -eq 'DOC Host.exe' }).Count -gt 0
  $st = [ordered]@{ status = 'updated'; installed = $ver; from = $old; reopen = $exeChanged; notes = [string]$f.Manifest.notes }
  Save-DhUpdateState $st; Write-DhJson 'UPDATE' $st
  Say ("updated to {0}{1}" -f $ver, $(if ($exeChanged) { '. Reopen DOC Host to finish (its window is still the old version).' } else { '' }))
  return 0
}

# ---------------------------------------------------------------------------------------------------
$code = 0
if ($Action -in @('Info', 'SetOption', 'Doctor')) {
  # report-only (Doctor runs the pack Doctor without any -Fix switch): no lock, so a slow lobby reply during its
  # checks never blocks Start, Stop or an update
  $code = @($(if ($Action -eq 'Info') { Invoke-Info } elseif ($Action -eq 'Doctor') { Invoke-Doctor } else { Invoke-SetOption }))[-1]
} elseif ($Action -eq 'Recover') {
  # run from the frozen recovery copy by the check at the top: undo an interrupted update the way -Value would.
  # Exit 10 + the undo's code, or 9 when another action holds the lock.
  $code = @(Invoke-DhRecover $Value)[-1]
} elseif ($Action -in @('ApplyUpdate', 'AutoUpdate')) {
  # One update at a time (its own lock); the action lock only around the undo and the swap (Invoke-ApplyUpdate).
  $ul = New-Object Threading.Mutex($false, ('Local\DOCHost_Update_' + (Get-DhRootTag)))
  $got = $false; try { $got = $ul.WaitOne(0) } catch [Threading.AbandonedMutexException] { $got = $true }
  if (-not $got) { $ul.Dispose(); Say 'an update is already running'; exit $(if ($Action -eq 'AutoUpdate') { 0 } else { 2 }) }
  try {
    $code = @(Invoke-ApplyUpdate -Auto:($Action -eq 'AutoUpdate'))[-1]
    if ($Action -eq 'AutoUpdate') { Invoke-DhWithActionLock 'AutoUpdate' { Remove-DhAsideFiles $script:DH_APP; 0 } | Out-Null }
  } catch {
    Say ("error: {0}" -f $_.Exception.Message)
    $code = 1
  } finally { try { $ul.ReleaseMutex() } catch { }; $ul.Dispose() }
} else {
  # the fresh run after the copy's undo waits briefly: the copy has just released the lock (round 16)
  $lock = Enter-DhAction $(if ($script:DH_IS_RERUN) { 30000 } else { 0 })
  if (-not $lock -and $Action -eq 'Stop') {
    $holder = Get-DhActionNote
    $updRunning = $false
    try { $um = New-Object Threading.Mutex($false, ('Local\DOCHost_Update_' + (Get-DhRootTag))); try { if ($um.WaitOne(0)) { $um.ReleaseMutex() } else { $updRunning = $true } } catch [Threading.AbandonedMutexException] { $um.ReleaseMutex() }; $um.Dispose() } catch { }
    if (($holder -and [string]$holder.action -in @('ApplyUpdate', 'AutoUpdate')) -or (-not $holder -and $updRunning)) {
      try { Write-DhStopRequest } catch { }
      Say 'Stop requested: an update is running; it will not start hosting again. Press Stop hosting again when it finishes if anything is still running.'
    }
  }
  if (-not $lock) {
    $note = Get-DhActionNote
    foreach ($line in (Get-DhBusyMessage $note)) { Say $line }
    if ($Action -eq 'Pair' -and $note -and [string]$note.action -eq 'Pair' -and $note.code) {   # only a refused Sign in re-shows the code
      Write-DhJson 'PAIRCODE' ([ordered]@{ code = [string]$note.code; uri = [string]$note.uri; uri_complete = [string]$note.uri_complete })
    }
    exit 2
  }
  Set-DhActionNote $Action
  try {
    switch ($Action) {
      'Pair'        { $code = @(Invoke-Pair)[-1] }
      'Start'       { Clear-DhStopRequested; if ((Repair-DhInterruptedUpdate -NoRestart -Force) -eq 1) { $code = 1 } else { $code = @(Invoke-Start)[-1] } }   # never host half-updated files
      'Stop'        { $code = @(Invoke-Stop)[-1] }
      'FixPicture'  { $code = @(Invoke-FixPicture)[-1] }
      'RestartGame' {
        # the undo may stop the services; RestartGame.ps1 only restarts the game windows, so a stopped cabinet gets
        # a full start from the undo (code 3) and that is the restart
        Clear-DhStopRequested                         # the host asks for the game now
        $rr = Repair-DhInterruptedUpdate -Force
        if ($rr -eq 1 -or $rr -eq 5) { $code = 1 } elseif ($rr -eq 3) { $code = 0 } else { $code = @(Invoke-RestartGame)[-1] }
      }
      'Doctor'      { $code = @(Invoke-Doctor)[-1] }
      'CheckUpdate' { $code = @(Invoke-CheckUpdate)[-1] }
    }
  } catch {
    Say ("error: {0}" -f $_.Exception.Message)
    $code = 1
  } finally { Clear-DhActionNote; Exit-DhAction $lock }
}
if (-not ($code -is [int])) { $code = 1 }
exit ([int]$code)
