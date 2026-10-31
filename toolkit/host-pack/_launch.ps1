param(
    [Parameter(Mandatory=$true)][string]$ver,
    [string]$boards = ''                           # which boards THIS machine launches; empty = auto-detect
)

# ---- Derby Owners Club multiboard launcher (portable) ----
# Resolves its own folder, so it works no matter where you unzip it.
#
# HOW THE WINDOWS ARE PLACED (learned from the Flycast source, multiboard.cpp):
#  - Flycast reads [window] left/top/width/height from each board's emu.cfg at startup, and
#    writes the last position back on exit. So we re-assert the layout in the cfg files before
#    every launch, and the windows simply OPEN in place. Nothing moves windows around.
#  - The MAIN board is the two-screen terminal: when the link starts (you click its tile), the
#    main process itself spawns a SECOND flycast process for the Right screen, positioned at
#    the main window's own left/top and inheriting the same cfg size. So it appears stacked on
#    the Left at the same sane size; a tiny one-shot watcher slides it one slot to the right.

$ErrorActionPreference = 'SilentlyContinue'
$base    = Split-Path -Parent $MyInvocation.MyCommand.Definition
$content = Join-Path $base "ROMs\$ver"

function Get-BoardExe([string]$station, [string]$version) {
    $relative = if ($version -eq 'docrebal') { 'Rebalance\flycast.exe' } else { 'flycast.exe' }
    return Join-Path (Join-Path $base $station) $relative
}


# This private executable binds local loopback sockets and reads [network] server.
# Force the endpoint for RB01 so older NetworkServer keys cannot trigger broadcast.
function Get-GameLaunchArgs([string]$station, [string]$version, [string]$romPath) {
    if ($version -ne 'docrebal') { return "`"$romPath`"" }
    $isMain = $station -eq 'main'
    if (-not $isMain -and $station -notmatch '^sat([1-8])$') {
        throw "Invalid Rebalance board: $station"
    }
    $port = if ($isMain) { 37391 } else { 37391 + [int]$Matches[1] }
    $role = if ($isMain) { 'yes' } else { 'no' }
    return "-config config:Debug.GDBEnabled=no -config config:Debug.GDBWaitForConnection=no -config network:server=127.0.0.1:37391 -config network:LocalPort=$port -config network:ActAsServer=$role -config network:Enable=yes -config network:EnableUPnP=no `"$romPath`""
}


if (-not (Test-Path (Join-Path $content "$ver.zip"))) {
    Write-Host ""
    Write-Host "  ERROR: game files for '$ver' not found." -ForegroundColor Red
    Write-Host "  Make sure you UNZIPPED the whole folder first (do not run from inside the .zip)."
    Write-Host ""
    Read-Host "  Press Enter to close"
    return
}

# Which boards to launch on THIS machine (distributed setups run a subset, e.g. -boards sat1).
$boardList = @($boards -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { $_.ToLower() })
if (-not $boardList) {
    # AUTO-DETECT. This used to be a hardcoded main + 4 satellites, which is what made an 8-seat
    # cabinet advertise eight seats in the lobby with only four game windows behind them. The pack
    # now runs whatever satN folders are actually installed, so a 4-seat install stays 4 and an
    # 8-seat install runs 8 with no switch to remember.
    $found = @(Get-ChildItem -Path $base -Directory -EA SilentlyContinue |
               Where-Object { $_.Name -match '^sat[1-8]$' } |
               Sort-Object { [int]($_.Name -replace 'sat','') } |
               ForEach-Object { $_.Name })
    # 2.1.1: the seats you chose in SETUP ("Seats to open", saved as seat_count in cabinet.json) decide
    # how many satellites start, so the windows, the video feeds and the seat stations all agree.
    # Without a cabinet.json (before setup) it still runs every satellite that is installed.
    $want = 0
    try { $want = [int](Get-Content (Join-Path $base 'cabinet.json') -Raw -ErrorAction Stop | ConvertFrom-Json).seat_count } catch { $want = 0 }
    if ($want -ge 1 -and $want -lt $found.Count) { $found = @($found | Select-Object -First $want) }
    $boardList = @('main') + $found
}
$hasMain = [bool]($boardList -contains 'main')
$sats    = @($boardList | Where-Object { $_ -match '^sat[1-8]$' } | Sort-Object)

# Clear the Windows "downloaded from the internet" flag so the windows launch without a block.
Get-ChildItem -Path $base -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

# Close only the Flycast instances for the boards we are launching (leave other boards alone).
foreach ($inst in $boardList) {
    $fp = Join-Path (Join-Path $base $inst) 'flycast.exe'
    $rb = Get-BoardExe $inst 'docrebal'
    Get-Process flycast -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $fp -or $_.Path -eq $rb } | Stop-Process -Force
}
Start-Sleep -Seconds 2

# Win32 helper: screen size, one-shot placement (sat fallback + Right watcher), title text.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool SetWindowText(IntPtr h, string t);
  public static int ScreenW(){ return GetSystemMetrics(0); }
  public static int ScreenH(){ return GetSystemMetrics(1); }
  public static void Place(IntPtr h,int x,int y,int w,int ht){ ShowWindow(h,9); SetWindowPos(h,IntPtr.Zero,x,y,w,ht,0x0040); }
  public static void Title(IntPtr h,string t){ SetWindowText(h,t); }
}
"@

# The layout: 4:3 windows in a grid, at most FOUR ACROSS. Main Left top-center-left (its Right
# screen lands beside it), satellites packed along the bottom -- one row up to four seats, two rows
# of four at eight. Seats read left to right, top row first: 1-4 above, 5-8 below.
#
# Tiles are 480x360, matching the house cabinets. On a 1920x1080 screen that tiles exactly: four
# across is 1920, and the main's 360 plus two rows of 360 is 1080, edge to edge with nothing spare.
# On anything narrower the tile falls back to a quarter of the screen width so it still fits.
$sw = [Win]::ScreenW(); $sh = [Win]::ScreenH()
$PER_ROW = 4
$satW = 480; $satH = 360
if (($PER_ROW * $satW) -gt $sw) { $satW = [int]($sw / $PER_ROW); $satH = [int]($satW * 3 / 4) }
$nS = $sats.Count
$cols = [math]::Min($nS, $PER_ROW); if ($cols -lt 1) { $cols = 1 }
$rows = [int][math]::Ceiling($nS / [double]$PER_ROW); if ($rows -lt 1) { $rows = 1 }
$satStartX = [int](($sw - ($cols * $satW)) / 2); if ($satStartX -lt 0) { $satStartX = 0 }
# Keep the taskbar gap when there is room, but NEVER above the main row: reserving 48px for the
# taskbar at 1920x1080 with two seat rows pushed the grid to y=312 and slid it 48px under the main
# board, which ends at y=360. Measured, not guessed. The floor is the main's own height.
$gridH = $rows * $satH
$satTop = [math]::Max($satH, ($sh - 48 - $gridH))
if (($satTop + $gridH) -gt $sh) { $satTop = $sh - $gridH }
if ($satTop -lt 0) { $satTop = 0 }
$satY = $satTop            # kept for the layout log line below
$mainLX = [int](($sw - (2 * $satW)) / 2)

# Set a key in a named section of an emu.cfg (updates in place, or inserts under the header).
function Set-CfgKey([string[]]$lines, [string]$section, [string]$key, [string]$value) {
    $inSec = $false; $found = $false
    $out = foreach ($line in $lines) {
        if ($line -match '^\[(.+)\]') { $inSec = ($Matches[1] -eq $section) }
        if ($inSec -and $line -match ('^' + [regex]::Escape($key) + '\s*=')) { $found = $true; "$key = $value" }
        else { $line }
    }
    if (-not $found) {
        $out = foreach ($line in $out) { $line; if ($line -match ('^\[' + [regex]::Escape($section) + '\]')) { "$key = $value" } }
    }
    return $out
}

# Point every board at THIS version's game folder + assert its window geometry in the cfg.
foreach ($inst in $boardList) {
    $cfg = Join-Path $base "$inst\emu.cfg"
    if (Test-Path $cfg) {
        $out = [string[]](Get-Content $cfg)
        $set = $false
        $out = foreach ($line in $out) {
            if ($line -match '^Dreamcast\.ContentPath\s*=') { $set = $true; "Dreamcast.ContentPath = $content" }
            else { $line }
        }
        if (-not $set) {
            $out = foreach ($line in $out) { $line; if ($line -match '^\[config\]') { "Dreamcast.ContentPath = $content" } }
        }
        if ($inst -eq 'main') { $wx = $mainLX; $wy = 0 }
        else {
            $idx = [Array]::IndexOf($sats, $inst); if ($idx -lt 0) { $idx = 0 }
            $wx = $satStartX + (($idx % $PER_ROW) * $satW)
            $wy = $satTop + ([int][math]::Floor($idx / $PER_ROW) * $satH)
        }
        $out = Set-CfgKey $out 'window' 'left'       "$wx"
        $out = Set-CfgKey $out 'window' 'top'        "$wy"
        $out = Set-CfgKey $out 'window' 'width'      "$satW"
        $out = Set-CfgKey $out 'window' 'height'     "$satH"
        $out = Set-CfgKey $out 'window' 'maximized'  'no'
        $out = Set-CfgKey $out 'window' 'fullscreen' 'no'
        Set-Content -Path $cfg -Value $out
    }
}

# Start a fresh layout log for this launch (numbers beat screenshots when debugging layout).
$layoutLog = Join-Path $base '_layout.log'
("[{0}] launch ver={1} boards={2} screen={3}x{4} satW={5} satH={6} mainLX={7} satY={8} satStartX={9} grid={10}x{11}" -f `
    (Get-Date -Format 'HH:mm:ss'), $ver, ($boardList -join ','), $sw, $sh, $satW, $satH, $mainLX, $satY, $satStartX, $cols, $rows) |
    Set-Content -Path $layoutLog
$snap = Join-Path $base '_layoutsnap.ps1'
if (Test-Path $snap) {
    Start-Process powershell -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$snap+'"'),'-LogFile',('"'+$layoutLog+'"'))
}

# Launch the boards: MAIN first (it is the network server), then the satellites ONE second apart.
# Windows open in place (from cfg). Two clocks in this Flycast (v2.6, core/network/naomi_network.cpp):
#   * once the main is up it takes satellites for 20 seconds, then starts the link with whoever joined
#     and turns later ones away (it only starts sooner if 8 have joined, so under 8 seats it always
#     waits the full 20);
#   * a satellite gives up 30 seconds after it comes up unless the main has STARTED the link by then.
# So every satellite has to come up between about 10 seconds before and 20 seconds after the main.
# The 2.1.1 order (main, 5 seconds, then a satellite every 3) brought sat7 and sat8 up after the 20,
# so an 8-seat cabinet linked only 6 (2026-09-28). Satellites-first fails the other clock whenever the
# main boots slowly. Main then 1-second steps keeps all of them inside both, with about 11 seconds of
# slack either way for boards that boot faster or slower than the main.
$savedDocLabEnv = @{}
if ($ver -eq 'docrebal') {
    Get-ChildItem Env:DOC_SOLO_* | ForEach-Object { $savedDocLabEnv[$_.Name] = $_.Value; Remove-Item -LiteralPath "Env:$($_.Name)" }
}
try {
$procByDir = @{}
$order = @(); if ($hasMain) { $order += 'main' }; $order += $sats
for ($i = 0; $i -lt $order.Count; $i++) {
    $d = $order[$i]
    # Hand flycast the rom path, exactly as the house cabinets do (their _launch.ps1 line 166). Without
    # it Flycast opens its GAME LIST and waits for a click, which is why this rig sat on a tile screen
    # while every house cab boots straight in. ContentPath alone only populates the list.
    $rom = Join-Path $content "$ver.zip"
    $procByDir[$d] = Start-Process -FilePath (Get-BoardExe $d $ver) -WorkingDirectory (Join-Path $base $d) -ArgumentList (Get-GameLaunchArgs $d $ver $rom) -PassThru
    try { Add-Content -Path $layoutLog -Value ("[{0}] started {1} pid={2}" -f (Get-Date -Format 'HH:mm:ss.fff'), $d, $procByDir[$d].Id) } catch {}
    if ($i -lt $order.Count - 1) { Start-Sleep -Seconds 1 } else { Start-Sleep -Seconds 3 }
}

} finally {
    foreach ($name in $savedDocLabEnv.Keys) { Set-Item -LiteralPath "Env:$name" -Value $savedDocLabEnv[$name] }
}

# Fallback only: if a satellite ignored its cfg slot, set it once. (Normally a no-op.)
for ($k = 0; $k -lt $nS; $k++) {
    $sp = $procByDir[$sats[$k]]
    if ($sp) {
        $sp.Refresh(); $h = $sp.MainWindowHandle
        if ($h -ne [IntPtr]::Zero) {
            [Win]::Place($h,
                ($satStartX + (($k % $PER_ROW) * $satW)),
                ($satTop + ([int][math]::Floor($k / $PER_ROW) * $satH)),
                $satW, $satH)
        }
    }
}

# Keep the window NAMES applied (Flycast renames them to the game name as it loads). Titles
# only - never moves or resizes a window.
$pairs = @()
for ($k = 0; $k -lt $nS; $k++) { $sp = $procByDir[$sats[$k]]; if ($sp) { $num = $sats[$k] -replace 'sat',''; $pairs += ("{0}|Sat {1}" -f $sp.Id, $num) } }
if ($hasMain -and $procByDir['main']) { $pairs += ("{0}|Main L" -f $procByDir['main'].Id) }
$pairs = $pairs -join ';'
$retitle = Join-Path $base '_retitle.ps1'
if ($pairs -and (Test-Path $retitle)) {
    Start-Process powershell -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$retitle+'"'),'-Pairs',('"'+$pairs+'"'))
}

# One-shot watcher for the MAIN's two screens: when the Right window spawns (after you click
# the main tile), align Main L + Main R side by side top-center, named. Then it exits.
$mainright = Join-Path $base '_mainright.ps1'
if ($hasMain -and (Test-Path $mainright)) {
    $mrArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$mainright+'"'),'-SW',"$sw")
    Start-Process powershell -WindowStyle Hidden -ArgumentList $mrArgs
}

Write-Host ""
Write-Host "  ===== Derby Owners Club is opening ====="
Write-Host "  Click the GAME PICTURE once in EACH window (MAIN first)."
if ($hasMain) {
    Write-Host "  The MAIN board's second screen (Right) appears after you click its tile - it"
    Write-Host "  slides in next to Main L automatically."
}
Write-Host "  The satellites are placed along the bottom. After a few seconds they connect."
Write-Host ""

# ===== Station Managers (per-satellite card management) =====
# One card manager per satellite this machine runs (own slot + private stable, shared pool,
# owner gear PIN 1234). Delete the Tools\ folder to turn this off.
# Card support is per-version: DOC II (derbyoc2) plays fine, but its card format is still
# being reverse-engineered, so no card managers are started for it yet.
$cardVersions = @('drbyocwc','derbyocw','derbyo2k','derbyoc','derbyoc2','docrebal')
$startRig = Join-Path $base 'Tools\Start-Rig.ps1'
if ($cardVersions -notcontains $ver) {
    Write-Host "  (Card managers are not yet available for this game version - card reader"
    Write-Host "   support for it is still in development. The game itself plays normally.)"
    Write-Host ""
}
elseif ((Test-Path $startRig) -and $sats.Count -gt 0) {
    $satNums = ($sats | ForEach-Object { $_ -replace 'sat','' }) -join ','
    # THIS install's card managers only (doc-ops #51): both are started by their full script path under
    # $base\Tools, so match those exact paths instead of every Start-Rig/doc_suite_server on the machine.
    $rigScripts = @('Tools\Start-Rig.ps1', 'Tools\doc_suite_server.ps1') | ForEach-Object { Join-Path $base $_ }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $cl = [string]$_.CommandLine; $cl -and @($rigScripts | Where-Object { $cl.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0 } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 500
    $rigArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Base "{1}" -Rom "{2}" -Sats "{3}" -OwnerPin 1234' -f $startRig, $base, $ver, $satNums
    # Hidden (2026-10-11): this console sat behind the Station Manager window for the whole session and a
    # host closing it killed the managers. The gate window Start-Rig opens is a normal GUI window.
    Start-Process powershell -WindowStyle Hidden -ArgumentList $rigArgs
    Write-Host "  Station Managers for satellite(s) $satNums - a gate window opens with a button each."
    Write-Host "  Each satellite keeps its own stable; the gear (PIN 1234) locks/unlocks editing."
    Write-Host ""
} elseif (Test-Path $startRig) {
    Write-Host "  (Main only - no card managers needed for the main board.)"
    Write-Host ""
}
