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
  [ValidateSet('Info', 'Pair', 'Start', 'Stop', 'FixPicture', 'RestartGame', 'Doctor', 'SetOption')]
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

. (Join-Path $PSScriptRoot 'DocHostCommon.ps1')
$root = $script:DH_PACK
$logs = Join-Path $root 'logs'

function Say([string]$m) { [Console]::Out.WriteLine($m); Write-DhLog 'dochost-actions.log' ("{0}: {1}" -f $Action, $m) }

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
        rom = [string]$cab.rom_ver; local_seats = @($cab.local_seats) } } else { $null })
    settings = (Get-DhSettings)
    migrated_pending_saves = $migrated
    migrated_cards = $migratedCards
    foreign_tasks = $foreign
    data_private = (Test-DhDataDirPrivate $script:DH_DATA)
    legacy_data = $(if (Test-Path -LiteralPath $script:DH_LEGACY_DATA) { $script:DH_LEGACY_DATA } else { '' })
    release = $script:DH_RELEASE
  }
  Write-DhJson 'INFO' $info
  return 0
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
  if ($s.site_rom -and $s.site_rom -ne $game.Rom) {
    Write-DhJson 'SITEROM' ([ordered]@{ site = $s.site_rom; local = $game.Rom })
    Say ("The website lists this cabinet as '{0}'. Set it to '{1}' on the website (Stable, Host section) or players are offered the wrong game." -f $s.site_rom, $game.Rom)
  }

  New-Item -ItemType Directory -Path $logs -Force | Out-Null
  # Tasks run through "DOC Host.exe --hidden-run": a GUI exe, so the task opens no console window, and it starts
  # PowerShell with no window. A task running powershell.exe directly flashes a console (and the listener's
  # never closed); hosts close those on instinct, which kills the step. powershell.exe only if the exe is missing.
  $hostExe = Join-Path $script:DH_APP 'DOC Host.exe'
  $hidden = Test-Path -LiteralPath $hostExe
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
  if (Test-Tunnel $cab.id) { Say 'the lobby can reach this cabinet through the relay hub' } else { Say 'the hub link is not answering yet: give it a minute, then press Doctor' }
  $ep = Get-LobbyEndpoints $cab.id
  if (-not $ep.Ok) { foreach ($i in 1..6) { Start-Sleep -Seconds 10; $ep = Get-LobbyEndpoints $cab.id; if ($ep.Ok) { break } } }
  if ($ep.Ok) { Say 'the lobby has this cabinet''s seat and video addresses' } else { Say 'the lobby has no addresses for this cabinet yet: press Doctor in a minute' }
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
    default { Say ("unknown option {0}" -f $Name); return 1 }
  }
  Set-DhSettings $s
  Say ("{0} = {1}" -f $Name, $s[$Name])
  return 0
}

# ---------------------------------------------------------------------------------------------------
$code = 0
if ($Action -in @('Info', 'SetOption')) {
  $code = @($(if ($Action -eq 'Info') { Invoke-Info } else { Invoke-SetOption }))[-1]
} else {
  $lock = Enter-DhAction 0
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
      'Start'       { $code = @(Invoke-Start)[-1] }
      'Stop'        { $code = @(Invoke-Stop)[-1] }
      'FixPicture'  { $code = @(Invoke-FixPicture)[-1] }
      'RestartGame' { $code = @(Invoke-RestartGame)[-1] }
      'Doctor'      { $code = @(Invoke-Doctor)[-1] }
    }
  } catch {
    Say ("error: {0}" -f $_.Exception.Message)
    $code = 1
  } finally { Clear-DhActionNote; Exit-DhAction $lock }
}
if (-not ($code -is [int])) { $code = 1 }
exit ([int]$code)
