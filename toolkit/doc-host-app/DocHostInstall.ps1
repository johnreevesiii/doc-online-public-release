# DocHostInstall.ps1 -- the installer's helper (DOC Host, doc-ops #117 Phase 1). Run hidden by
# DOC-Host-Setup.exe before and after files are copied, and by the uninstaller before files are removed.
#
#   -Action PreUpgrade   -AppDir <install> -DataDir <data>
#       * keeps each board's emu.cfg so PostInstall can carry the host's [window] and [input] sections over
#   -Action PostInstall  -AppDir <install> -DataDir <data> [-MigrateFrom <old pack folder>]
#       * refuses a data folder that is a drive root, or one another Windows account owns
#       * records "DOC Host data.json" in the data folder: who owns it, whether DOC Host created it, and
#         the only entries DOC Host may ever delete there
#       * writes hostapp\datadir.txt; points pack\logs and pack\pending_saves at the data folder (NTFS
#         junctions: no admin needed, and the pack's scripts and broker keep their usual paths)
#       * moves over a v1 data folder in %ProgramData%\DOC Host (copy only, and only what this account
#         owns; the host is told the old folder can be removed, nothing is deleted)
#       * restores cabinet.json from the data folder when the pack has none, only if this account owns it
#       * migrates from an old Host Pack folder: READ ONLY on the old folder, never deletes or changes it
#       * merges the kept emu.cfg [window] and [input] sections into the new boards' emu.cfg (upgrade)
#       * locks the data folder to this account + SYSTEM (owner = this account, no inherited ACEs) as soon
#         as it exists (before any other step can stop the script), and again at the end; also when setup
#         runs elevated or /DATADIR points outside the profile
#       * locks the install folder the same way when it is outside this account's profile (it holds the
#         live pack\cabinet.json and the scripts that run as this account)
#       * every path is expanded from 8.3 short form first (Windows PowerShell 5.1 file moves fail on it)
#   -Action Uninstall    -AppDir <install> -DataDir <data> [-RestoreTasks] [-DeleteData] [-DeletePendingSaves]
#       * stops hosting of THIS install and removes the scheduled tasks that point into it
#       * with -RestoreTasks, re-registers another pack's tasks that DOC Host exported when it took them over
#       * copies cabinet.json, seat_state.json and any card still sitting in a seat to <data>\backups
#       * removes the two junctions (the links only, never what they point to)
#       * -DeleteData deletes only DOC Host's own entries, and only in a folder DOC Host created and this
#         account owns; pending_saves, backups and migrated only with -DeletePendingSaves as well
# Exit code 0 = done, 1 = something needs a look (details in <data>\logs\install.log), 2 = refused.
param(
  [Parameter(Mandatory = $true)][ValidateSet('PreUpgrade', 'PostInstall', 'Uninstall')][string]$Action,
  [Parameter(Mandatory = $true)][string]$AppDir,
  [Parameter(Mandatory = $true)][string]$DataDir,
  [string]$MigrateFrom = '',
  [switch]$RestoreTasks,
  [switch]$DeleteData,
  [switch]$DeletePendingSaves
)
$ErrorActionPreference = 'Continue'
# Setup appends "." to a path ending in a backslash so the closing quote survives; undo that here.
function Clean-Path([string]$p) { $p = $p.Trim().Trim('"'); if ($p.EndsWith('\.')) { $p = $p.Substring(0, $p.Length - 1) }; if ($p.Length -gt 3) { $p = $p.TrimEnd('\') }; return $p }
# Long form of a path (8.3 "JOHNPC~1" breaks Move-Item / Remove-Item -Recurse in PS 5.1): the existing part
# through Get-Item, the rest appended as given.
function Get-LongPath([string]$p) {
  if (-not $p) { return $p }
  try { $p = [IO.Path]::GetFullPath($p) } catch { return $p }
  $tail = @(); $cur = $p
  while ($cur -and -not (Test-Path -LiteralPath $cur)) {
    $tail = @(Split-Path -Leaf $cur) + $tail
    $parent = Split-Path -Parent $cur
    if (-not $parent -or $parent -eq $cur) { return $p }
    $cur = $parent
  }
  try { $long = (Get-Item -LiteralPath $cur -Force).FullName } catch { return $p }
  foreach ($t in $tail) { $long = Join-Path $long $t }
  if ($long.Length -gt 3) { $long = $long.TrimEnd('\') }
  return $long
}
$AppDir = Get-LongPath (Clean-Path $AppDir)
$DataDir = Get-LongPath (Clean-Path $DataDir)
$MigrateFrom = Get-LongPath (Clean-Path $MigrateFrom)
$pack = Join-Path $AppDir 'pack'
$scripts = Join-Path $AppDir 'hostapp'
$script:problems = 0
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$MARKER_NAME = 'DOC Host data.json'
# The only entries DOC Host ever deletes in the data folder ("Delete data"). Horses need a second yes.
$OWN_ENTRIES = @('logs', 'settings.json', 'cabinet.json', 'recover-state.json', 'recover-status.json',
                 'settings.json.tmp', 'recover-state.json.tmp', 'recover-status.json.tmp', $MARKER_NAME)
$HORSE_ENTRIES = @('pending_saves', 'backups', 'migrated')

$script:logReady = $false
function Log([string]$m) {
  if ($script:logReady) {
    try {
      New-Item -ItemType Directory -Path (Join-Path $DataDir 'logs') -Force | Out-Null
      Add-Content -LiteralPath (Join-Path $DataDir 'logs\install.log') -Value ("[{0}] {1}: {2}" -f (Get-Date -Format o), $Action, $m) -Encoding UTF8
    } catch { }
  }
  [Console]::Out.WriteLine($m)
}
function Bad([string]$m) { $script:problems++; Log ("PROBLEM: " + $m) }

function Test-DriveRoot([string]$p) { return ($p -match '^[A-Za-z]:\\?$') -or ($p -match '^\\\\[^\\]+\\[^\\]+\\?$') }
function Get-MySid { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
function Get-OwnerSid([string]$p) {
  try { return (New-Object Security.Principal.NTAccount((Get-Acl -LiteralPath $p).Owner)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return '' }
}
# Test builds only (no hostapp\RELEASE): DOCHOST_TEST_FOREIGN marks paths as another account's.
function Owned([string]$p) {
  if ($env:DOCHOST_SANDBOX -eq '1' -and -not (Test-Path -LiteralPath (Join-Path $scripts 'RELEASE')) -and $env:DOCHOST_TEST_FOREIGN -and
      $p.IndexOf($env:DOCHOST_TEST_FOREIGN, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $false }
  return ((Get-OwnerSid $p) -eq (Get-MySid))
}

# Owner = this account; only this account + SYSTEM, full control, nothing inherited; children reset to
# inherit that (reparse points skipped). Self-contained: it must work before the pack is known to be there.
function Lock-Folder([string]$dir) {
  $sid = Get-MySid
  $null = & icacls.exe $dir /setowner "*$sid" /T /C /Q 2>&1
  $null = & icacls.exe $dir /inheritance:r /grant:r "*${sid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' /Q 2>&1
  foreach ($c in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
    if ($c.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    $null = & icacls.exe $c.FullName /reset /T /C /Q 2>&1
  }
  try {
    $acl = Get-Acl -LiteralPath $dir
    if (-not $acl.AreAccessRulesProtected) { return $false }
    foreach ($r in $acl.Access) {
      $s = $r.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
      if ($s -ne $sid -and $s -ne 'S-1-5-18') { return $false }
    }
    return ((Get-OwnerSid $dir) -eq $sid)
  } catch { return $false }
}
function Test-UnderProfile([string]$p) {
  $prof = Get-LongPath $env:USERPROFILE
  return $p.StartsWith($prof.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Test-Junction([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { return $false }
  return [bool]((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
}
function Get-JunctionTarget([string]$p) {
  try { return [string]((Get-Item -LiteralPath $p -Force).Target | Select-Object -First 1) } catch { return '' }
}
function Remove-Junction([string]$p) {
  # Directory.Delete(path, $false) on a reparse point removes the LINK only, never what it points to.
  if (Test-Junction $p) { [IO.Directory]::Delete($p, $false) }
}
function Set-Junction([string]$link, [string]$target) {
  New-Item -ItemType Directory -Path $target -Force | Out-Null
  if (Test-Junction $link) {
    $cur = Get-JunctionTarget $link
    if ($cur.TrimEnd('\') -ieq $target.TrimEnd('\')) { Log ("{0} -> {1} (already)" -f $link, $target); return }
    Remove-Junction $link
  } elseif (Test-Path -LiteralPath $link) {
    # A real folder (the pack ships an empty logs\). Move anything in it to the data folder first.
    foreach ($c in @(Get-ChildItem -LiteralPath $link -Force)) {
      $dest = Join-Path $target $c.Name
      if (Test-Path -LiteralPath $dest) { $dest = Join-Path $target ("{0}.from-pack-{1}" -f $c.Name, $stamp) }
      Move-Item -LiteralPath $c.FullName -Destination $dest -Force
    }
    [IO.Directory]::Delete($link, $false)
  }
  New-Item -ItemType Junction -Path $link -Target $target | Out-Null
  if ((Test-Junction $link) -and ((Get-JunctionTarget $link).TrimEnd('\') -ieq $target.TrimEnd('\'))) { Log ("{0} -> {1}" -f $link, $target) }
  else { Bad ("could not link {0} to {1}" -f $link, $target) }
}

# Copy one file. Returns 1 only when it really copied; a failure (a locked file, say) goes to the install log.
# The copy loses the read-only flag, so a later "Delete data" never stops partway on it.
function Copy-One([string]$from, [string]$to) {
  try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force | Out-Null
    Copy-Item -LiteralPath $from -Destination $to -Force -ErrorAction Stop
    $fi = New-Object IO.FileInfo($to)
    if ($fi.IsReadOnly) { $fi.IsReadOnly = $false }
    return 1
  } catch {
    Bad ("could not copy {0}: {1}" -f $from, $_.Exception.Message)
    return 0
  }
}

# Copy a tree; with -OwnedOnly, only files this account owns (never adopt another account's files). A source
# folder that is itself a junction or symlink is skipped (and logged): it may point anywhere on the PC.
function Copy-Tree([string]$src, [string]$dst, [switch]$OwnedOnly) {
  if (-not (Test-Path -LiteralPath $src)) { return 0 }
  if (Test-Junction $src) { Log ("skipped {0}: it is a link to another folder, not copied" -f $src); return 0 }
  $n = 0
  foreach ($f in @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue)) {
    if ($OwnedOnly -and -not (Owned $f.FullName)) { continue }
    $rel = $f.FullName.Substring($src.TrimEnd('\').Length + 1)
    $n += Copy-One $f.FullName (Join-Path $dst $rel)
  }
  return $n
}

function Read-Marker {
  $m = Join-Path $DataDir $MARKER_NAME
  if (-not (Test-Path -LiteralPath $m)) { return $null }
  try { return ([IO.File]::ReadAllText($m) | ConvertFrom-Json) } catch { return $null }
}

# Merge [section] blocks of $old into $new for the named sections (whole block replaced, or appended).
function Split-CfgBlocks([string]$t) {
  $blocks = New-Object System.Collections.ArrayList
  $cur = @{ name = ''; lines = New-Object System.Collections.ArrayList }
  foreach ($l in ($t -split '\r?\n')) {
    if ($l -match '^\s*\[([^\]]+)\]\s*$') { [void]$blocks.Add($cur); $cur = @{ name = $Matches[1].ToLowerInvariant(); lines = New-Object System.Collections.ArrayList } }
    [void]$cur.lines.Add($l)
  }
  [void]$blocks.Add($cur)
  return , $blocks
}
function Merge-CfgSections([string]$new, [string]$old, [string[]]$sections) {
  $nl = "`n"; if ($new.Contains("`r`n")) { $nl = "`r`n" }
  $nb = Split-CfgBlocks $new
  $ob = Split-CfgBlocks $old
  foreach ($sec in $sections) {
    $o = $null; foreach ($b in $ob) { if ($b.name -eq $sec) { $o = $b; break } }
    if (-not $o) { continue }
    $hit = $false
    for ($i = 0; $i -lt $nb.Count; $i++) { if ($nb[$i].name -eq $sec) { $nb[$i] = $o; $hit = $true } }
    if (-not $hit) { [void]$nb.Add($o) }
  }
  $all = New-Object System.Collections.ArrayList
  foreach ($b in $nb) { foreach ($l in $b.lines) { [void]$all.Add([string]$l) } }
  return ($all -join $nl)
}

# ---------------------------------------------------------------------------------------------------
function Invoke-PreUpgrade {
  if (-not (Test-Path -LiteralPath $pack)) { return }
  $keep = Join-Path (Get-LongPath $env:TEMP) ("DOCHost-emucfg-{0}" -f (Get-Date -Format 'yyyyMMddHHmmssfff'))
  $n = 0
  foreach ($b in @(Get-ChildItem -LiteralPath $pack -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(main|sat[1-8])$' })) {
    $cfg = Join-Path $b.FullName 'emu.cfg'
    if (Test-Path -LiteralPath $cfg) { New-Item -ItemType Directory -Path $keep -Force | Out-Null; Copy-Item -LiteralPath $cfg -Destination (Join-Path $keep ($b.Name + '.cfg')); $n++ }
  }
  if ($n) { [IO.File]::WriteAllText((Join-Path $scripts 'emucfg-keep.txt'), $keep, (New-Object Text.UTF8Encoding($false))) }
  [Console]::Out.WriteLine(("kept {0} board emu.cfg file(s) for the upgrade" -f $n))
}

function Invoke-PostInstall {
  if (Test-DriveRoot $DataDir) { [Console]::Out.WriteLine("REFUSED: the data folder cannot be a drive root ($DataDir)"); exit 2 }
  if ((Test-Path -LiteralPath $DataDir) -and -not (Owned $DataDir)) {
    [Console]::Out.WriteLine("REFUSED: $DataDir belongs to another Windows account; choose another data folder"); exit 2
  }
  $existed = Test-Path -LiteralPath $DataDir
  $nonEmpty = $existed -and [bool](@(Get-ChildItem -LiteralPath $DataDir -Force -ErrorAction SilentlyContinue).Count)
  New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
  # Private from the first moment, before anything is written into it or any check below can stop here.
  if (-not (Lock-Folder $DataDir)) { [Console]::Out.WriteLine("PROBLEM: could not make $DataDir private to this account") ; $script:problems++ }
  $script:logReady = $true
  $marker = Read-Marker
  if (-not $marker) {
    $marker = [ordered]@{ product = 'DOC Host'; created_by_dochost = (-not $nonEmpty); owner_sid = (Get-MySid); created_at = (Get-Date -Format o)
                          own_entries = $OWN_ENTRIES; horse_entries = $HORSE_ENTRIES }
    [IO.File]::WriteAllText((Join-Path $DataDir $MARKER_NAME), ($marker | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false)))
    if ($nonEmpty) { Log ("{0} already held other files: DOC Host uses it, but will never delete anything there" -f $DataDir) }
  } elseif ([string]$marker.owner_sid -ne (Get-MySid)) {
    [Console]::Out.WriteLine("REFUSED: $DataDir is another Windows account's DOC Host data"); exit 2
  }
  foreach ($d in @('logs', 'pending_saves', 'backups')) { New-Item -ItemType Directory -Path (Join-Path $DataDir $d) -Force | Out-Null }
  [IO.File]::WriteAllText((Join-Path $scripts 'datadir.txt'), $DataDir, (New-Object Text.UTF8Encoding($false)))
  Log ("install folder {0}, data folder {1}" -f $AppDir, $DataDir)
  if (-not (Test-Path -LiteralPath (Join-Path $pack 'broker.py'))) { Bad 'pack\broker.py missing after install'; return }
  . (Join-Path $scripts 'DocHostCommon.ps1')

  # An install folder outside this account's profile (for example C:\DOC Host) inherits whatever C:\ allows,
  # often write access for every signed-in account. Lock it like the data folder, before the data links exist.
  if (-not (Test-UnderProfile $AppDir)) {
    if (Lock-Folder $AppDir) { Log ("install folder {0} is outside your profile: locked to this Windows account and SYSTEM" -f $AppDir) }
    else { Bad ("could not make the install folder {0} private to this account" -f $AppDir) }
  }

  Set-Junction (Join-Path $pack 'logs') (Join-Path $DataDir 'logs')
  Set-Junction (Join-Path $pack 'pending_saves') (Join-Path $DataDir 'pending_saves')

  Invoke-LegacyMove

  $packCab = Join-Path $pack 'cabinet.json'
  $dataCab = Join-Path $DataDir 'cabinet.json'
  if ((-not (Test-Path -LiteralPath $packCab)) -and (Test-Path -LiteralPath $dataCab)) {
    if (Owned $dataCab) { Copy-Item -LiteralPath $dataCab -Destination $packCab; Log 'cabinet.json restored from the data folder (this PC stays paired)' }
    else { Bad 'a cabinet.json in the data folder belongs to another Windows account: not used (pair this install yourself)' }
  } elseif (Test-Path -LiteralPath $packCab) {
    Copy-Item -LiteralPath $packCab -Destination $dataCab -Force
    Log 'cabinet.json kept (upgrade); copy refreshed in the data folder'
  }

  if ($MigrateFrom) { Invoke-Migrate $MigrateFrom }
  Invoke-CfgMerge

  if (Lock-Folder $DataDir) { Log 'data folder locked to this Windows account and SYSTEM' }
  else { Bad ("could not make {0} private to this account" -f $DataDir) }
}

# v1 (PR #29 at 9985552) kept data in %ProgramData%\DOC Host, readable by every account. Copy what THIS
# account owns into the private folder, adopt pairing/settings/horses only from files it owns, and tell the
# host the old folder can go. Never delete it here.
function Invoke-LegacyMove {
  $old = $script:DH_LEGACY_DATA
  if (-not (Test-Path -LiteralPath $old) -or ($old.TrimEnd('\') -ieq $DataDir)) { return }
  $done = Join-Path $DataDir 'migrated\programdata.done'
  if (Test-Path -LiteralPath $done) { return }
  $dest = Join-Path $DataDir ("migrated\programdata-{0}" -f $stamp)
  $n = Copy-Tree $old $dest -OwnedOnly
  Log ("{0} file(s) this account owns copied from the old shared data folder {1}" -f $n, $old)
  $c = Join-Path $old 'cabinet.json'
  if ((Test-Path -LiteralPath $c) -and -not (Owned $c)) { Log 'the old shared folder holds another account''s cabinet.json: not used' }
  $pc = Join-Path $pack 'cabinet.json'
  if (-not (Test-Path -LiteralPath $pc) -and (Test-Path -LiteralPath (Join-Path $dest 'cabinet.json'))) {
    Copy-Item -LiteralPath (Join-Path $dest 'cabinet.json') -Destination $pc
    Copy-Item -LiteralPath (Join-Path $dest 'cabinet.json') -Destination (Join-Path $DataDir 'cabinet.json') -Force
    Log 'pairing moved over from the old shared data folder'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $DataDir 'settings.json')) -and (Test-Path -LiteralPath (Join-Path $dest 'settings.json'))) {
    Copy-Item -LiteralPath (Join-Path $dest 'settings.json') -Destination (Join-Path $DataDir 'settings.json')
  }
  $p = Copy-Tree (Join-Path $dest 'pending_saves') (Join-Path $DataDir 'pending_saves')
  if ($p) { Log ("{0} unsaved horse file(s) from the old shared folder are back in pending_saves" -f $p) }
  New-Item -ItemType Directory -Path (Split-Path -Parent $done) -Force | Out-Null
  [IO.File]::WriteAllText($done, $old, (New-Object Text.UTF8Encoding($false)))
  Log ("The old shared folder {0} is no longer used. After checking DOC Host, you can delete it." -f $old)
  [Console]::Out.WriteLine("@@LEGACY $old")
}

function Invoke-Migrate([string]$old) {
  if (-not (Test-Path -LiteralPath $old)) { Bad ("old pack folder not found: {0}" -f $old); return }
  $full = (Resolve-Path -LiteralPath $old).Path.TrimEnd('\')
  if ($full -ieq $pack -or $full -ieq $AppDir -or $full.StartsWith($AppDir + '\', [StringComparison]::OrdinalIgnoreCase)) {
    Bad 'the old pack folder is inside the DOC Host install folder; nothing migrated'; return
  }
  if (-not ((Test-Path (Join-Path $full 'cabinet.json')) -or (Test-Path (Join-Path $full 'broker.py')))) {
    Bad ("{0} does not look like a Host Pack folder (no cabinet.json or broker.py); nothing migrated" -f $full); return
  }
  $dest = Join-Path $DataDir ("migrated\{0}" -f $stamp)
  New-Item -ItemType Directory -Path $dest -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $dest 'FROM.txt'),
    ("Copied from {0} on {1}. The old folder was not changed or deleted.`r`n" -f $full, (Get-Date -Format o)),
    (New-Object Text.UTF8Encoding($false)))
  Log ("migrating from {0} (read only) into {1}" -f $full, $dest)

  $oldCab = Join-Path $full 'cabinet.json'
  if ((Test-Path -LiteralPath $oldCab) -and -not (Owned $oldCab)) {
    Bad 'the old pack''s cabinet.json belongs to another Windows account: pairing not moved'
  } elseif (Test-Path -LiteralPath $oldCab) {
    [void](Copy-One $oldCab (Join-Path $dest 'cabinet.json'))
    $packCab = Join-Path $pack 'cabinet.json'
    $oldId = ''; try { $oldId = [string]((Get-Content -LiteralPath $oldCab -Raw | ConvertFrom-Json).id) } catch { }
    if (-not (Test-Path -LiteralPath $packCab)) {
      Copy-Item -LiteralPath $oldCab -Destination $packCab
      Copy-Item -LiteralPath $oldCab -Destination (Join-Path $DataDir 'cabinet.json') -Force
      Log ("pairing moved over: cabinet {0}" -f $oldId)
    } else {
      $curId = ''; try { $curId = [string]((Get-Content -LiteralPath $packCab -Raw | ConvertFrom-Json).id) } catch { }
      if ($curId -eq $oldId) { Log ("already paired as the same cabinet {0}" -f $curId) }
      else { Bad ("DOC Host is already paired as {0}; the old pack's cabinet {1} was kept in {2}, not switched" -f $curId, $oldId, $dest) }
    }
  } else { Log 'the old folder has no cabinet.json (it was never paired)' }

  $n = Copy-Tree (Join-Path $full 'logs') (Join-Path $dest 'logs')
  Log ("{0} old log file(s) copied" -f $n)
  # pending_saves: copied for the operator, NOT into the active folder. The pack README's rule: horses
  # waiting in an old pack's pending_saves are recovered separately, and the old pack still holds them.
  $p = Copy-Tree (Join-Path $full 'pending_saves') (Join-Path $dest 'pending_saves')
  if ($p) {
    Log ("{0} file(s) in the old pack's pending_saves: copied to {1}. Tell the operator; they are recovered separately." -f $p, (Join-Path $dest 'pending_saves'))
    [Console]::Out.WriteLine(("@@PENDING {0}" -f $p))
  }
  if (Test-Path -LiteralPath (Join-Path $full 'seat_state.json')) {
    [void](Copy-One (Join-Path $full 'seat_state.json') (Join-Path $dest 'seat_state.json.old'))
    Log 'seat_state.json kept for reference only (not reused)'
  }
  # Horses an older pack (Home Pack 2.x, Host Pack 3.0) can hold OUTSIDE pending_saves: a card still in a
  # seat (<board>\data\*.card), the Station Managers' seat libraries (<board>\data\_library) and the shared
  # shelf (Card-Library-Shared). Copied aside for the operator, never into an active folder.
  $cards = 0
  foreach ($b in @(Get-ChildItem -LiteralPath $full -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(main|sat[1-8])$' })) {
    $bd = Join-Path $b.FullName 'data'
    if ((Test-Junction $b.FullName) -or (Test-Junction $bd)) { Log ("skipped {0}: it is a link to another folder, not copied" -f $bd); continue }
    foreach ($c in @(Get-ChildItem -LiteralPath $bd -Filter '*.card' -File -Force -ErrorAction SilentlyContinue)) {
      $cards += Copy-One $c.FullName (Join-Path $dest ("cards\{0}\{1}" -f $b.Name, $c.Name))
    }
    $cards += Copy-Tree (Join-Path $bd '_library') (Join-Path $dest ("cards\{0}\_library" -f $b.Name))
  }
  $cards += Copy-Tree (Join-Path $full 'Card-Library-Shared') (Join-Path $dest 'cards\Card-Library-Shared')
  if ($cards) {
    Log ("{0} file(s) from the old pack's seats and card libraries copied for review to {1}. Tell the operator." -f $cards, (Join-Path $dest 'cards'))
    [Console]::Out.WriteLine(("@@CARDS {0}" -f $cards))
  }
}

# Upgrade: the new pack's emu.cfg wins, except the host's own [window] and [input] sections.
function Invoke-CfgMerge {
  $f = Join-Path $scripts 'emucfg-keep.txt'
  if (-not (Test-Path -LiteralPath $f)) { return }
  $keep = ([IO.File]::ReadAllText($f)).Trim()
  Remove-Item -LiteralPath $f -Force
  if (-not (Test-Path -LiteralPath $keep)) { return }
  $n = 0
  foreach ($k in @(Get-ChildItem -LiteralPath $keep -Filter '*.cfg' -File)) {
    $board = [IO.Path]::GetFileNameWithoutExtension($k.Name)
    $cfg = Join-Path $pack ($board + '\emu.cfg')
    if (-not (Test-Path -LiteralPath $cfg)) { continue }
    $merged = Merge-CfgSections ([IO.File]::ReadAllText($cfg)) ([IO.File]::ReadAllText($k.FullName)) @('window', 'input')
    [IO.File]::WriteAllText($cfg, $merged, (New-Object Text.UTF8Encoding($false)))
    $n++
  }
  $bk = Join-Path $DataDir ("backups\emucfg-before-upgrade-{0}" -f $stamp)
  New-Item -ItemType Directory -Path $bk -Force | Out-Null
  Copy-Item -Path (Join-Path $keep '*') -Destination $bk
  [IO.Directory]::Delete($keep, $true)       # 8.3-safe; Remove-Item -Recurse fails on a short %TEMP%
  Log ("upgrade kept the [window] and [input] sections of {0} board emu.cfg file(s) (old files in {1})" -f $n, $bk)
}

# ---------------------------------------------------------------------------------------------------
function Invoke-Uninstall {
  $script:logReady = (Test-Path -LiteralPath $DataDir) -and (Owned $DataDir)
  if (Test-Path -LiteralPath (Join-Path $pack 'setup\Common.ps1')) {
    # Stop this install (scoped) and drop ITS tasks (only tasks whose action points into this pack).
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $out = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $scripts 'DocHostActions.ps1') -Action Stop 2>&1
    foreach ($l in @($out)) { Log ("  stop: " + [string]$l) }
    try {
      . (Join-Path $scripts 'DocHostCommon.ps1')
      foreach ($t in @(Get-DhOurTasks)) {
        Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false -ErrorAction Stop
        Log ("task {0} removed" -f $t.TaskName)
      }
      $left = @(Get-DhOurTasks)
      if ($left.Count) { Bad ("tasks still registered: " + (($left | ForEach-Object { $_.TaskName }) -join ', ')) }
      if ($RestoreTasks -and $script:logReady) { Restore-TakenOverTasks }
    } catch { Bad ("removing tasks: {0}" -f $_.Exception.Message) }
  }

  if (-not $script:logReady) { Log 'the data folder is missing or not this account''s: nothing kept or deleted there'; Remove-Links; return }
  # Player files that live in the install folder: keep copies before the folder goes.
  $bk = Join-Path $DataDir ("backups\uninstall-{0}" -f $stamp)
  New-Item -ItemType Directory -Path $bk -Force | Out-Null
  foreach ($f in @('cabinet.json', 'seat_state.json')) {
    $src = Join-Path $pack $f
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $bk $f); Log ("{0} copied to {1}" -f $f, $bk) }
  }
  if (Test-Path -LiteralPath (Join-Path $pack 'cabinet.json')) { Copy-Item -LiteralPath (Join-Path $pack 'cabinet.json') -Destination (Join-Path $DataDir 'cabinet.json') -Force }
  $cards = 0
  foreach ($b in @(Get-ChildItem -LiteralPath $pack -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(main|sat[1-8])$' })) {
    foreach ($c in @(Get-ChildItem -LiteralPath (Join-Path $b.FullName 'data') -Filter '*.card' -File -ErrorAction SilentlyContinue)) {
      $to = Join-Path $bk ("cards\{0}" -f $b.Name)
      New-Item -ItemType Directory -Path $to -Force | Out-Null
      Copy-Item -LiteralPath $c.FullName -Destination (Join-Path $to $c.Name)
      $cards++
    }
  }
  if ($cards) { Log ("{0} card file(s) still in a seat copied to {1}\cards. Tell the operator." -f $cards, $bk) }
  Remove-Links

  if ($DeleteData) { Remove-OwnData }
  else { Log ("data kept in {0}" -f $DataDir) }
}

function Remove-Links {
  foreach ($j in @('logs', 'pending_saves')) {
    $p = Join-Path $pack $j
    try { Remove-Junction $p } catch { }
    if (Test-Junction $p) { Bad ("could not remove the link {0}; the uninstaller will leave the pack folder in place" -f $p) }
    else { Log ("link {0} removed (its contents stay in {1})" -f $p, $DataDir) }
  }
}

# Put back the doc_home_* tasks of another pack folder that DOC Host exported when it took them over.
function Restore-TakenOverTasks {
  foreach ($m in @(Get-ChildItem -LiteralPath (Join-Path $DataDir 'backups') -Directory -Filter 'tasks-*' -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $mf = Join-Path $m.FullName 'tasks.json'
    if (-not (Test-Path -LiteralPath $mf)) { continue }
    try { $man = [IO.File]::ReadAllText($mf) | ConvertFrom-Json } catch { continue }
    if ($man.restored) { continue }
    foreach ($t in @($man.tasks)) {
      $existing = Get-ScheduledTask -TaskName $t.name -ErrorAction SilentlyContinue
      if ($existing) { Log ("task {0} exists again (not DOC Host's): left as it is" -f $t.name); continue }
      try {
        $xml = [IO.File]::ReadAllText((Join-Path $m.FullName $t.xml))
        Register-ScheduledTask -Xml $xml -TaskName $t.name -TaskPath $t.path -ErrorAction Stop | Out-Null
        Log ("task {0} put back for {1}" -f $t.name, $t.action)
      } catch { Bad ("could not put back task {0}: {1} (its XML is in {2})" -f $t.name, $_.Exception.Message, $m.FullName) }
    }
    $man.restored = $true
    [IO.File]::WriteAllText($mf, ($man | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
  }
}

# "Delete data": only DOC Host's own entries, only in a folder DOC Host created and this account owns.
function Remove-OwnData {
  $marker = Read-Marker
  if (Test-DriveRoot $DataDir) { Bad 'the data folder is a drive root: nothing deleted'; return }
  if (-not $marker) { Bad ("{0} has no DOC Host marker: nothing deleted" -f $DataDir); return }
  if ([string]$marker.owner_sid -ne (Get-MySid) -or -not (Owned $DataDir)) { Bad 'the data folder is not this account''s: nothing deleted'; return }
  if (-not $marker.created_by_dochost) { Bad ("{0} existed before DOC Host and held other files: nothing deleted" -f $DataDir); return }
  $names = @($OWN_ENTRIES)
  if ($DeletePendingSaves) { $names += $HORSE_ENTRIES }
  $script:logReady = $false        # logs is about to go
  foreach ($n in $names) {
    if ($n -eq $MARKER_NAME) { continue }
    $p = Join-Path $DataDir $n
    if (-not (Test-Path -LiteralPath $p)) { continue }
    if ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($p, $false); continue }
    try { if (Test-Path -LiteralPath $p -PathType Container) { [IO.Directory]::Delete($p, $true) } else { [IO.File]::Delete($p) } } catch { }
  }
  $rest = @(Get-ChildItem -LiteralPath $DataDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $MARKER_NAME })
  if (-not $rest.Count) {
    Remove-Item -LiteralPath (Join-Path $DataDir $MARKER_NAME) -Force -ErrorAction SilentlyContinue
    [IO.Directory]::Delete($DataDir, $false)
    $parent = Split-Path -Parent $DataDir
    if ((Split-Path -Leaf $parent) -eq 'DOC Host' -and -not @(Get-ChildItem -LiteralPath $parent -Force).Count) { [IO.Directory]::Delete($parent, $false) }
    [Console]::Out.WriteLine('data folder deleted')
  } else {
    [Console]::Out.WriteLine(('deleted DOC Host''s settings and logs; kept: ' + (($rest | ForEach-Object { $_.Name }) -join ', ')))
  }
}

switch ($Action) {
  'PreUpgrade'  { Invoke-PreUpgrade }
  'PostInstall' { Invoke-PostInstall }
  'Uninstall'   { Invoke-Uninstall }
}
if ($script:problems) { exit 1 }
exit 0
