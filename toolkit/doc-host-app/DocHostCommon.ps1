# DocHostCommon.ps1 -- shared helpers for the DOC Host app (doc-ops #117 Phase 1).
#
# Dot-sourced by DocHostActions.ps1, DocHostRecover.ps1 and DocHostInstall.ps1. It sits ON TOP of the Host
# Pack's own setup\Common.ps1 (dot-sourced here), so the games list, cabinet.json reader/writer, scheduled
# task helpers, borderless and priority helpers are the pack's code, not a copy.
#
# Layout of an installed DOC Host (everything per Windows user):
#   <install>\DOC Host.exe            the window
#   <install>\hostapp\*.ps1           these scripts (+ datadir.txt written by the installer, + RELEASE in
#                                     release builds)
#   <install>\pack\                   the Host Pack, unchanged (scripts expect to run from its root)
#   <install>\pack\logs          ->   junction to <data>\logs
#   <install>\pack\pending_saves ->   junction to <data>\pending_saves
#   <data> = %LOCALAPPDATA%\DOC Host\data   settings, logs, pending_saves, backups, migrated. Its ACL is
#            this user + SYSTEM only (no inheritance): it holds the cabinet token and stashed cards.
#
# SANDBOX (test builds only): DOCHOST_SANDBOX=1 lets DOCHOST_STUB replace the lobby and hub base url,
# DOCHOST_HUB the hub alone, DOCHOST_BROKER the local broker url and DOCHOST_TASK_PREFIX the doc_home_
# task prefix. A release build (hostapp\RELEASE present) ignores every DOCHOST_* variable.

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# 8.3 short paths ("C:\Users\<SHORTN~1>\...", the default %TEMP% for long or spaced account names) break
# Move-Item and Remove-Item -Recurse in Windows PowerShell 5.1. Every path used here is expanded to its
# long form first: the existing part through Get-Item, the rest appended as given.
function Get-DhLongPath([string]$p) {
  if (-not $p) { return $p }
  try { $p = [IO.Path]::GetFullPath($p) } catch { return $p }
  $tail = @()
  $cur = $p
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

# Write a small state file through a .tmp and a File.Replace/Move, never Move-Item (8.3-safe).
function Write-DhFileAtomic([string]$path, [string]$text) {
  $tmp = $path + '.tmp'
  [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding($false)))
  # [NullString]::Value, not $null: PowerShell would pass $null as "" and File.Replace rejects an empty backup name.
  if ([IO.File]::Exists($path)) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
}

$script:DH_SCRIPTS = Get-DhLongPath $PSScriptRoot
$script:DH_APP     = Split-Path -Parent $script:DH_SCRIPTS
$script:DH_RELEASE = Test-Path -LiteralPath (Join-Path $PSScriptRoot 'RELEASE')
$script:DH_SANDBOX = ($env:DOCHOST_SANDBOX -eq '1') -and -not $script:DH_RELEASE
$script:DH_PACK    = Join-Path $script:DH_APP 'pack'
if ($script:DH_SANDBOX -and $env:DOCHOST_PACK) { $script:DH_PACK = $env:DOCHOST_PACK }
$script:DH_PACK    = (Get-DhLongPath $script:DH_PACK).TrimEnd('\')

function Get-DhDefaultDataDir {
  if ($script:DH_RELEASE) { return (Join-Path $env:LOCALAPPDATA 'DOC Host\data') }
  return (Join-Path $env:LOCALAPPDATA 'DOC Host TEST\data')      # a test build never shares the real data
}
function Get-DhDataDir {
  $f = Join-Path $script:DH_SCRIPTS 'datadir.txt'
  if (Test-Path -LiteralPath $f) {
    $d = ([IO.File]::ReadAllText($f)).Trim()
    if ($d) { return (Get-DhLongPath $d) }
  }
  return (Get-DhLongPath (Get-DhDefaultDataDir))
}
$script:DH_DATA = Get-DhDataDir
$script:DH_LOGS = Join-Path $script:DH_DATA 'logs'
# v1 kept data in %ProgramData%\DOC Host (shared by every account on the PC; doc-stream PR #29 review P1-1).
$script:DH_LEGACY_DATA = Join-Path $env:ProgramData 'DOC Host'
if ($script:DH_SANDBOX -and $env:DOCHOST_LEGACY_DATA) { $script:DH_LEGACY_DATA = $env:DOCHOST_LEGACY_DATA }

# The pack's own helpers (games, cabinet.json, tasks, borderless, priorities).
$packCommon = Join-Path $script:DH_PACK 'setup\Common.ps1'
if (-not (Test-Path -LiteralPath $packCommon)) { throw "Host Pack not found at $($script:DH_PACK)" }
. $packCommon

$script:DH_BROKER  = 'http://127.0.0.1:8770'
if ($script:DH_SANDBOX) {
  if ($env:DOCHOST_STUB) { $script:LOBBY = $env:DOCHOST_STUB.TrimEnd('/'); $script:HUB = $script:LOBBY }
  if ($env:DOCHOST_HUB) { $script:HUB = $env:DOCHOST_HUB.TrimEnd('/') }
  if ($env:DOCHOST_BROKER) { $script:DH_BROKER = $env:DOCHOST_BROKER.TrimEnd('/') }
  if ($env:DOCHOST_TASK_PREFIX) { $script:TASKPFX = $env:DOCHOST_TASK_PREFIX }
}

function Write-DhLog([string]$name, [string]$msg) {
  try {
    New-Item -ItemType Directory -Path $script:DH_LOGS -Force | Out-Null
    Add-Content -LiteralPath (Join-Path $script:DH_LOGS $name) -Value ("[{0}] {1}" -f (Get-Date -Format o), $msg) -Encoding UTF8
  } catch { }
}

# ---- who owns what ---------------------------------------------------------------------------------
function Get-DhMySid { return [Security.Principal.WindowsIdentity]::GetCurrent().User }

# True only when this Windows account owns the file or folder. A second account's files (or anything
# planted by another account) are never adopted: no pairing, settings or horses cross accounts.
function Test-DhOwnedByMe([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  if ($script:DH_SANDBOX -and $env:DOCHOST_TEST_FOREIGN -and $path.IndexOf($env:DOCHOST_TEST_FOREIGN, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $false }
  try {
    $acl = Get-Acl -LiteralPath $path
    $owner = (New-Object Security.Principal.NTAccount($acl.Owner)).Translate([Security.Principal.SecurityIdentifier])
    return ($owner.Value -eq (Get-DhMySid).Value)
  } catch { return $false }
}

# The data folder: this account and SYSTEM only, owned by this account, nothing inherited from the parent
# (so a /DATADIR outside the profile is as private as the default). Children are reset to inherit it.
# Runs elevated or not: an elevated setup ("Run as administrator") still hands the folder to the user.
function Protect-DhDataDir([string]$dir) {
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $sid = (Get-DhMySid).Value
  $out = @()
  $out += & icacls.exe $dir /setowner "*$sid" /T /C /Q 2>&1
  $out += & icacls.exe $dir /inheritance:r /grant:r "*${sid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' /Q 2>&1
  foreach ($c in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
    if ($c.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    $out += & icacls.exe $c.FullName /reset /T /C /Q 2>&1
  }
  return (Test-DhDataDirPrivate $dir)
}

# Private = protected (no inherited ACEs) and every ACE is this account or SYSTEM.
function Test-DhDataDirPrivate([string]$dir) {
  try {
    $acl = Get-Acl -LiteralPath $dir
    if (-not $acl.AreAccessRulesProtected) { return $false }
    $mine = (Get-DhMySid).Value
    foreach ($r in $acl.Access) {
      $sid = $r.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
      if ($sid -ne $mine -and $sid -ne 'S-1-5-18') { return $false }
    }
    $owner = (New-Object Security.Principal.NTAccount($acl.Owner)).Translate([Security.Principal.SecurityIdentifier]).Value
    return ($owner -eq $mine)
  } catch { return $false }
}

# ---- settings ---------------------------------------------------------------------------------------
# remote_recover: let remote players use the lobby's Restart and Refresh screens buttons (default ON).
# video:          broadcast video (default ON, as Setup.ps1 defaults it).
# site_rom:       the game version the website had for this cabinet at pairing time.
function Get-DhSettings {
  $s = [ordered]@{ remote_recover = $true; video = $true; site_rom = '' }
  $p = Join-Path $script:DH_DATA 'settings.json'
  if (Test-Path -LiteralPath $p) {
    try {
      $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json
      foreach ($k in @('remote_recover', 'video', 'site_rom')) {
        if ($j.PSObject.Properties.Name -contains $k) { $s[$k] = $j.$k }
      }
    } catch { }
  }
  return $s
}
function Set-DhSettings($s) {
  New-Item -ItemType Directory -Path $script:DH_DATA -Force | Out-Null
  Write-DhFileAtomic (Join-Path $script:DH_DATA 'settings.json') ($s | ConvertTo-Json)
}

# A copy of cabinet.json in the data folder. The pack's scripts and broker read cabinet.json at the pack root
# (Host Pack 3.1 has no data-folder setting for it), so the live file stays there and this is the copy that
# survives a reinstall. DocHostInstall.ps1 restores it when the pack root has none, and only if this account
# owns the copy.
function Backup-DhCabinet {
  $src = Join-Path $script:DH_PACK 'cabinet.json'
  if (-not (Test-Path -LiteralPath $src)) { return }
  New-Item -ItemType Directory -Path $script:DH_DATA -Force | Out-Null
  Copy-Item -LiteralPath $src -Destination (Join-Path $script:DH_DATA 'cabinet.json') -Force
}

# ---- restart bookkeeping (shared by the window's Restart game and the remote listener) ---------------
$script:DH_REC_STATE = Join-Path $script:DH_DATA 'recover-state.json'
function Read-DhRecState {
  $s = @{ last_restart_at = 0.0; handled = @() }
  if (Test-Path -LiteralPath $script:DH_REC_STATE) {
    try {
      $j = [IO.File]::ReadAllText($script:DH_REC_STATE) | ConvertFrom-Json
      $s.last_restart_at = [double]$j.last_restart_at
      $s.handled = @($j.handled)
    } catch { }
  }
  return $s
}
function Save-DhRecState($s) {
  New-Item -ItemType Directory -Path $script:DH_DATA -Force | Out-Null
  $obj = [ordered]@{ last_restart_at = $s.last_restart_at; handled = @($s.handled | Select-Object -Last 50) }
  Write-DhFileAtomic $script:DH_REC_STATE ($obj | ConvertTo-Json -Depth 4)
}
# Any game restart (the host's button or a remote request) starts the remote Restart cooldown.
function Set-DhLastRestart {
  $s = Read-DhRecState
  $s.last_restart_at = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  Save-DhRecState $s
}

# ---- one action at a time ----------------------------------------------------------------------
# The window's buttons and the remote recover listener share one named mutex per install, so a remote
# Restart can never run on top of the host's own Start, Stop or Fix picture.
function Get-DhRootTag {
  $sha = [Security.Cryptography.SHA1]::Create()
  $b = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:DH_PACK.ToLowerInvariant()))
  return (-join ($b[0..5] | ForEach-Object { $_.ToString('x2') }))
}
function Enter-DhAction([int]$waitMs = 0) {
  $m = New-Object Threading.Mutex($false, ('Local\DOCHost_Action_' + (Get-DhRootTag)))
  $got = $false
  try { $got = $m.WaitOne($waitMs) } catch [Threading.AbandonedMutexException] { $got = $true }
  if (-not $got) { $m.Dispose(); return $null }
  return $m
}
function Exit-DhAction($m) { if ($m) { try { $m.ReleaseMutex() } catch { }; $m.Dispose() } }

# What holds the lock, so a refused button can say why (a host reported a bare "another action is still
# running" after closing the window mid sign-in: the pairing child keeps polling, and holding the lock, for
# up to 15 minutes after the window is gone). The note names the action, its process and start time; a
# sign-in adds its code, link and expiry. A note whose process is gone is ignored.
$script:DH_ACTION_NOTE = Join-Path $script:DH_DATA 'action-running.json'
function Set-DhActionNote([string]$action, $extra = @{}) {
  $ps = ''; try { $ps = (Get-Process -Id $PID).StartTime.ToString('o') } catch { }
  $o = [ordered]@{ action = $action; pid = $PID; pstart = $ps; started = (Get-Date).ToString('o') }
  foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] }
  try { New-Item -ItemType Directory -Path $script:DH_DATA -Force | Out-Null; Write-DhFileAtomic $script:DH_ACTION_NOTE ($o | ConvertTo-Json -Compress) } catch { }
}
function Clear-DhActionNote {
  try {
    $n = Get-Content -LiteralPath $script:DH_ACTION_NOTE -Raw -ErrorAction Stop | ConvertFrom-Json
    if ([int]$n.pid -eq $PID) { Remove-Item -LiteralPath $script:DH_ACTION_NOTE -Force -ErrorAction SilentlyContinue }
  } catch { }
}
function Get-DhActionNote {
  try {
    $n = Get-Content -LiteralPath $script:DH_ACTION_NOTE -Raw -ErrorAction Stop | ConvertFrom-Json
    $p = Get-Process -Id ([int]$n.pid) -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    # A reused process number is not the note's owner: the start time must match too (when both are readable).
    $st = $null; try { $st = $p.StartTime } catch { }   # an elevated owner's start time reads as $null, not an error
    if ($n.pstart -and $st) {
      try { if ([Math]::Abs(($st - [datetime]$n.pstart).TotalSeconds) -gt 2) { return $null } } catch { }
    }
    return $n
  } catch { return $null }
}
# The words for a refused action, from the note (or a plain fallback when there is none).
function Get-DhBusyMessage($n, [datetime]$now = (Get-Date)) {
  $names = @{ Pair = 'Sign in and pair'; Start = 'Start hosting'; Stop = 'Stop hosting'; FixPicture = 'Fix picture'; RestartGame = 'Restart game'; Doctor = 'Doctor' }
  if (-not $n) {
    return @('another DOC Host action is still running on this install; try again when it finishes.',
             'If nothing seems to be running, close DOC Host (check the system tray) and open it again, or restart the PC.')
  }
  $what = $(if ($names.ContainsKey([string]$n.action)) { $names[[string]$n.action] } else { [string]$n.action })
  $since = ''
  try { $t = [datetime]$n.started; $since = $(if ($t.Date -eq $now.Date) { $t.ToString('HH:mm') } else { $t.ToString('yyyy-MM-dd HH:mm') }) } catch { }
  if ([string]$n.action -eq 'Pair' -and $n.code) {
    $left = 0
    try { $left = [int][Math]::Ceiling((([datetime]$n.expires) - $now).TotalMinutes) } catch { }
    if ($left -gt 0) {
      return @(("a sign-in is already waiting for you: approve code {0} in the browser page that opened{1}" -f $n.code, $(if ($since) { ' at ' + $since } else { '' })),
               ("(or go to {0} and enter the code). It stays open for {1} more minute(s), and DOC Host finishes pairing by itself once you approve." -f $n.uri, $left),
               'No need to press Sign in again. If you closed that page, wait until it runs out, then press Sign in once.')
    }
  }
  $when = $(if ($since) { "started $since, " } else { '' })
  return @(("'{0}' is still running on this install ({1}process {2}); try again when it finishes." -f $what, $when, $n.pid),
           'If DOC Host was closed while it ran and it never finishes, restart the PC.')
}

# ---- main screens borderless ---------------------------------------------------------------------
# The Right main screen is a second mainlycast.exe process that the Left main starts when the race link
# starts. A Fix picture pressed before then never saw it and still reported success, so it stayed framed and
# resizable; a host then stretched it and the stream rescaled (2026-10-11). This walks every visible, titled (or
# untitled but at least 320x240, so a small helper never counts), unowned top-level window of this install's main-board processes (never dialogs or console windows), strips
# the frame where present, and reports how many distinct main processes have a game window, the same pairing
# the broadcast's mains_combine.py expects, so the caller can say when the Right one is not up yet.
function Set-DhMainsBorderless([string]$root) {
  try {
    Add-Type -ErrorAction SilentlyContinue @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class DocHostMainWin {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  // Game windows of the given processes as (handle, pid) pairs. Dialogs (#32770) and console windows are skipped.
  public static List<KeyValuePair<IntPtr, uint>> WindowsOf(uint[] pids) {
    var set = new HashSet<uint>(pids); var found = new List<KeyValuePair<IntPtr, uint>>();
    EnumWindows(delegate (IntPtr h, IntPtr l) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      RECT rc; bool big = GetWindowRect(h, out rc) && rc.R - rc.L >= 320 && rc.B - rc.T >= 240;
      // untitled render windows count too (PR #40 review), but only screen-sized ones (never a small helper)
      if (set.Contains(pid) && IsWindowVisible(h) && (GetWindowTextLength(h) > 0 || big) && GetWindow(h, 4) == IntPtr.Zero) {
        var c = new System.Text.StringBuilder(256); GetClassName(h, c, 256); string cls = c.ToString();
        if (cls != "#32770" && cls != "ConsoleWindowClass") found.Add(new KeyValuePair<IntPtr, uint>(h, pid));
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
"@
  } catch { }   # already compiled in this session
  $mainDir = (Join-Path $root 'main').TrimEnd('\') + '\'
  $pids = @(Get-OurFlycast $root | Where-Object { $_.Path -and $_.Path.StartsWith($mainDir, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { [uint32]$_.Id })
  $res = [pscustomobject]@{ Found = 0; Changed = 0 }
  if (-not $pids.Count) { return $res }
  $GWL_STYLE = -16
  $FRAME = 0x00C00000 -bor 0x00040000 -bor 0x00800000 -bor 0x00400000   # caption|thickframe|border|dlgframe
  $SWP = 0x0027                                                         # nosize|nomove|nozorder|framechanged
  $owners = @{}
  foreach ($kv in [DocHostMainWin]::WindowsOf([uint32[]]$pids)) {
    $h = $kv.Key; $owners[[string]$kv.Value] = $true
    try {
      $style = [DocHostMainWin]::GetWindowLong($h, $GWL_STYLE)
      if ($style -band $FRAME) {
        [void][DocHostMainWin]::SetWindowLong($h, $GWL_STYLE, ($style -band (-bnot $FRAME)))
        [void][DocHostMainWin]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 0, 0, $SWP)
        $res.Changed++
      }
    } catch { }
  }
  $res.Found = $owners.Count   # distinct main processes with a game window: 2 when Left and Right are both up
  return $res
}
function Get-DhMainsMessage($r, [string]$verb = 'again') {
  if ($r.Found -ge 2) { return ("both main screens borderless ({0} changed)" -f $r.Changed) }
  if ($r.Found -eq 1) { return ("Left main screen borderless. The Right main screen is not up yet: it opens when the race link starts. Once both main screens show the game, press Fix picture {0}." -f $verb).Replace(' Fix picture .', ' Fix picture.') }
  return 'no main screen window found yet: once the game shows on the main screens, press Fix picture'
}

# ---- what is running from THIS install ------------------------------------------------------------
function Get-DhBrokerHealth {
  try {
    $h = Invoke-RestMethod ($script:DH_BROKER + '/api/health') -TimeoutSec 4
    if ($h.ok) { return $h }
  } catch { }
  return $null
}

function Test-DhBrokerOurs {
  return [bool](@(Get-OurPython $script:DH_PACK 'broker.py').Count)
}

# Task names this install owns: same names as the pack (doc_home_*), so the pack's own Stop Hosting and
# Doctor keep working. Another pack on the same PC uses the same names; Start refuses to take them over
# without the host saying so, and exports them first so uninstall can put them back.
# Matching uses the pack folder PLUS a separator (doc-ops #51): "...\pack" never claims "...\pack-old".
$script:DH_TASKS = @('services', 'windowless', 'broadcast', 'game', 'recover')
function Get-DhTaskText($t) { return ((@($t.Actions) | ForEach-Object { [string]$_.Execute + ' ' + [string]$_.Arguments }) -join ' ') }
function Test-DhTaskOurs($t) {
  return ((Get-DhTaskText $t).IndexOf($script:DH_PACK + '\', [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Get-DhForeignTasks {
  $out = @()
  foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like ($script:TASKPFX + '*') })) {
    if (-not (Test-DhTaskOurs $t)) {
      $acts = Get-DhTaskText $t
      $out += [pscustomobject]@{ Name = $t.TaskName; Path = $t.TaskPath; State = [string]$t.State; Args = $acts }
    }
  }
  return $out
}

function Get-DhOurTasks {
  return @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like ($script:TASKPFX + '*') -and (Test-DhTaskOurs $_) })
}

function Write-DhJson([string]$tag, $obj) {
  [Console]::Out.WriteLine('@@' + $tag + ' ' + ($obj | ConvertTo-Json -Depth 6 -Compress))
}
