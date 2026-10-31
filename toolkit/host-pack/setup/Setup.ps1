# Setup.ps1 -- the one-stop DOC HomePack wizard.
# Unzip -> run "SETUP - Start Here" -> answer a few questions -> this machine is a live cabinet in the
# lobby at play.johnreevesiii.com, running whichever of the six games you picked.
#
# What it does, in order: preflight -> pair (device code, one time) -> ask seats/local play/game ->
# write cabinet.json -> register this install's scheduled tasks -> start stations+broker+input+agent,
# the game, the borderless pass (satellites AND mains) and the video broadcast -> verify and report.
#
# The verify step is the point of this script, not the decoration: it checks the lobby actually has
# this cabinet's seat and video addresses, because without them the cabinet looks perfectly healthy
# here while the lobby shows "Cabinet full" over a black board (2026-09-19).
#
#   -DryRun   walk the preflight and the questions, change nothing, pair nothing, start nothing.
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSCommandPath) 'Common.ps1')
$root = Get-PackRoot
$logs = Join-Path $root 'logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null

Write-Host ''
Write-Host '  ===========================================================' -ForegroundColor Cyan
Write-Host '   DERBY OWNERS CLUB - HOME PACK SETUP' -ForegroundColor Cyan
Write-Host '   your machine, all six games, live in the lobby' -ForegroundColor Cyan
Write-Host '  ===========================================================' -ForegroundColor Cyan
if ($DryRun) { Write-Warn 'DRY RUN: nothing will be paired, registered or started.' }

# ---- 1. preflight -----------------------------------------------------------------------------
Write-Head 'Checking this folder'
$fatal = $false

if ($root -match '(?i)\\Temp\\' -or $root -match '(?i)\.zip') {
  Write-Bad "this looks like it is running from INSIDE the zip (path: $root)"
  Write-Note 'Right-click the .zip -> Extract All, open the extracted folder, and run SETUP from there.'
  Write-Note 'A good home for it is C:\DerbyOwnersClub\HomePack.'
  Read-Host '  Press Enter to close'
  return
}
Write-Ok "install folder: $root"

foreach ($need in @('runtime\python\python.exe', 'broker.py', 'slot_station.py', 'relay_agent.py', '_launch.ps1')) {
  if (Test-Path (Join-Path $root $need)) { Write-Ok "found $need" }
  else { Write-Bad "missing $need"; $fatal = $true }
}
$missingRoms = @()
foreach ($g in $script:GAMES) {
  $z = Join-Path $root ("ROMs\{0}\{0}.zip" -f $g.Rom)
  $n = Join-Path $root ("ROMs\{0}\naomi.zip" -f $g.Rom)
  if ((Test-Path $z) -and (Test-Path $n)) { Write-Ok ("game files: {0}" -f $g.Name) } else { $missingRoms += $g.Name }
}
if ($missingRoms.Count) { Write-Bad ('game files missing for: ' + ($missingRoms -join ', ')); $fatal = $true }
# The Play files are only for double-clicking (the game task runs _launch.ps1 itself), so a missing one
# is a warning. It is also the usual sign of a zip that did not fully extract, so say how to fix that.
$missingPlay = @($script:GAMES | Where-Object { -not (Test-Path (Join-Path $root $_.Bat)) } | ForEach-Object { $_.Bat })
if ($missingPlay.Count) {
  Write-Warn ('Play files missing: ' + ($missingPlay -join ', '))
  Write-Note 'The cabinet still starts without them, but the zip may not have extracted completely.'
  Write-Note 'Safest fix: extract the zip again into an EMPTY folder and run SETUP from there.'
} else { Write-Ok 'Play files: all six' }

# Windows / GPU sanity. Warn only: none of this stops a cabinet from running, but all of it shows up
# later as "why is it slow" if it is wrong.
Write-Head 'Checking this machine'
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($os) {
  Write-Ok ("{0} (build {1})" -f $os.Caption.Trim(), $os.BuildNumber)
  $ramGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
  if ($ramGB -ge 12) { Write-Ok ("{0} GB RAM" -f $ramGB) } else { Write-Warn ("only {0} GB RAM - 16 GB+ is comfortable (8 seats = 10 game windows)" -f $ramGB) }
}
$gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
foreach ($g in $gpus) { Write-Ok ("GPU: {0}" -f $g.Name) }
if (-not $gpus) { Write-Warn 'no GPU reported - the game needs a real Direct3D 11 GPU' }
# Virtual displays are the single nastiest performance trap here. A remote-desktop tool attaches one,
# Windows moves the desktop (and the game windows) onto it, and everything renders through the virtual
# adapter instead of the real card: 20 fps with a 4090 idling at 700 MHz, on the office box 2026-09-19.
$virt = @($gpus | Where-Object { $_.Name -match '(?i)virtual|indirect|parsec|citrix|rdp|meta|idd' })
if ($virt.Count) {
  Write-Warn ('virtual display adapter present: ' + (($virt | ForEach-Object { $_.Name }) -join ', '))
  Write-Note 'If races run slow, check the game windows are on the REAL GPU''s monitor. Remote-desktop'
  Write-Note 'tools (Parsec, RDP) can attach a virtual screen and quietly move everything onto it.'
}
Write-Note 'If races later run slow, set the GPU to "Prefer maximum performance" in the NVIDIA control'
Write-Note 'panel (and Windows Graphics settings -> High performance). A downclocked GPU is the usual cause.'
$scr = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
if ($scr -and $scr.CurrentHorizontalResolution) {
  if ([int]$scr.CurrentHorizontalResolution -ge 1920) { Write-Ok ("screen {0}x{1}" -f $scr.CurrentHorizontalResolution, $scr.CurrentVerticalResolution) }
  else { Write-Warn ("screen is {0}x{1} - 1920x1080 or wider keeps every game window on screen (8 seats tile exactly at 1920x1080)" -f $scr.CurrentHorizontalResolution, $scr.CurrentVerticalResolution) }
}
$freeGB = [math]::Round((Get-PSDrive ($root.Substring(0,1))).Free / 1GB, 1)
if ($freeGB -ge 5) { Write-Ok ("{0} GB free on drive {1}" -f $freeGB, $root.Substring(0,1)) } else { Write-Warn ("only {0} GB free" -f $freeGB) }

if ($fatal) {
  Write-Host ''
  Write-Bad 'Setup cannot continue - see the [X] lines above.'
  Read-Host '  Press Enter to close'
  return
}

# ---- 2. pairing --------------------------------------------------------------------------------
Write-Head 'Pairing this cabinet to your account'
$cab = Read-Cab $root
if (Test-Paired $cab) {
  Write-Ok ("already paired: {0} ({1}), {2} seats" -f $cab.label, $cab.id, (Get-SeatCount $cab))
  Write-Note 'Delete cabinet.json and re-run SETUP if you ever want to pair as a different cabinet.'
} elseif ($DryRun) {
  Write-Warn 'not paired yet (dry run skips pairing)'
  $cab = [pscustomobject]@{ id = 'dryrun'; label = 'Dry Run'; host_token = 'dryrun'; seat_count = 4 }
} else {
  $defaultLabel = [System.Net.Dns]::GetHostName()
  $label = Read-Host ("  What should this cabinet be called in the lobby? [{0}]" -f $defaultLabel)
  if (-not $label) { $label = $defaultLabel }
  # Seats are capped at what the pack ships (MAX_SEATS, MAIN + 8 satellites since 2.1.0). John picked 8
  # on the first 2.0 install and got four seats with no game window behind them: the lobby advertised
  # them, players could claim them, and nothing was there. Ask, but never promise more than exists.
  $seatAsk = Read-Host ("  How many seats should it run? 1-{0} [{0}]" -f $script:MAX_SEATS)
  $seatWant = $script:MAX_SEATS
  if ($seatAsk -match '^\s*[1-8]\s*$') { $seatWant = [int]$seatAsk.Trim() }
  if ($seatWant -gt $script:MAX_SEATS) {
    Write-Warn ("this pack installs MAIN + {0} satellites - asking for {1} would advertise seats with no game behind them" -f $script:MAX_SEATS, $seatWant)
    $seatWant = $script:MAX_SEATS
    Write-Note ("using {0}." -f $seatWant)
  }

  $start = Invoke-RestMethod -Method Post -Uri "$($script:LOBBY)/api/cabinet/pair/start" -ContentType 'application/json' `
             -Body (@{ device_label = $label; seats = $seatWant } | ConvertTo-Json)
  if (-not $start.ok) { throw "couldn't start pairing: $($start.error)" }
  Write-Host ''
  Write-Host '  A browser is opening so you can approve this cabinet.' -ForegroundColor White
  Write-Host ("  If it does not, go to {0} and enter code:  " -f $start.verification_uri) -NoNewline -ForegroundColor White
  Write-Host $start.user_code -ForegroundColor Yellow
  Write-Host ''
  Start-Process $start.verification_uri_complete
  Write-Host '  Waiting for you to approve' -NoNewline
  $deadline = (Get-Date).AddSeconds([int]$start.expires_in_s)
  $pollS = [int]$start.poll_interval_s
  if ($pollS -lt 2) { $pollS = 3 }
  $approved = $null
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $pollS
    Write-Host '.' -NoNewline
    try { $r = Invoke-RestMethod -Method Post -Uri "$($script:LOBBY)/api/cabinet/pair/poll" -ContentType 'application/json' -Body (@{ device_code = $start.device_code } | ConvertTo-Json) } catch { continue }
    if ($r.status -eq 'approved') { $approved = $r; break }
    if (@('expired','claimed','not_found') -contains $r.status) { throw "`n  pairing $($r.status) - run SETUP again." }
  }
  if (-not $approved) { throw "`n  pairing timed out - run SETUP again." }
  Write-Host ''
  Write-Ok ("paired: {0} ({1})" -f $approved.label, $approved.cabinet_id)
  $cab = [pscustomobject]@{
    id = $approved.cabinet_id; label = $approved.label; host_token = $approved.host_token
    seat_count = $(if ([int]$approved.seat_count -ge 1) { [int]$approved.seat_count } else { $seatWant })
    rom_ver = $(if ($approved.rom) { [string]$approved.rom } else { 'derbyoc2' })
    pack_dir = $root; connector_base = $script:LOBBY; local_seats = @()
    clerk_jwks_url = "$($script:CLERK)/.well-known/jwks.json"; clerk_issuer = $script:CLERK
    pack_version = ((Get-Content (Join-Path $root 'VERSION') -Raw -ErrorAction SilentlyContinue) -as [string]).Trim()
  }
}

# ---- 3. the questions --------------------------------------------------------------------------
Write-Head 'How should this cabinet run?'
$seats = Get-SeatCount $cab
if ($seats -gt $script:MAX_SEATS) { $seats = $script:MAX_SEATS }
$seatAsk = Read-Host ("  Seats to open, 1-{0} [{1}]" -f $script:MAX_SEATS, $seats)
if ($seatAsk -match '^\s*[1-8]\s*$') { $seats = [int]$seatAsk.Trim() }
if ($seats -gt $script:MAX_SEATS) {
  Write-Warn ("capped at {0} - the launcher only lays out MAIN + {0} satellites" -f $script:MAX_SEATS)
  $seats = $script:MAX_SEATS
}

$localSeats = @()
$ans = Read-Host '  Will YOU play at this machine yourself? Reserves seat 1 for the local keyboard; the rest open to the lobby. [y/N]'
if ($ans -match '^\s*(y|yes)\s*$') { $localSeats = @(1); Write-Ok 'seat 1 reserved for your keyboard here' }
else { Write-Ok 'all seats open to the lobby' }

Write-Host ''
Write-Host '  Which game should it run?' -ForegroundColor White
foreach ($g in $script:GAMES) { Write-Host ("    {0}) {1}" -f $g.Key, $g.Name) }
$cur = [string]$cab.rom_ver
$curGame = Get-GameByRom $cur
$defKey = if ($curGame) { $curGame.Key } else { '1' }
$pick = Read-Host ("  Pick 1-6 [{0}]" -f $defKey)
if (-not $pick) { $pick = $defKey }
$game = $script:GAMES | Where-Object { $_.Key -eq $pick.Trim() } | Select-Object -First 1
if (-not $game) { $game = $script:GAMES | Where-Object { $_.Key -eq $defKey } | Select-Object -First 1 }
Write-Ok ("game: {0}" -f $game.Name)
if ($cur -and $cur -ne $game.Rom) {
  Write-Warn ("the lobby has this cabinet listed as '{0}'." -f $cur)
  Write-Note ("Change its version to '{0}' on the website (cabinet settings) or the lobby will offer" -f $game.Rom)
  Write-Note 'players the wrong game. The cabinet itself will run whatever you picked here.'
}

$doVideo = $true
$ans = Read-Host '  Broadcast video so remote players can see and play? [Y/n]'
if ($ans -match '^\s*(n|no)\s*$') { $doVideo = $false; Write-Warn 'video off - remote seats will not be playable, local play only' }

$startNow = $true
$ans = Read-Host '  Start everything now? [Y/n]'
if ($ans -match '^\s*(n|no)\s*$') { $startNow = $false }

# ---- 4. write the cabinet config (no per-seat station files since doc-ops #117) ----------------
Write-Head 'Writing this cabinet''s settings'
$cab | Add-Member -NotePropertyName seat_count  -NotePropertyValue $seats      -Force
$cab | Add-Member -NotePropertyName local_seats -NotePropertyValue $localSeats -Force
$cab | Add-Member -NotePropertyName rom_ver     -NotePropertyValue $game.Rom   -Force
$cab | Add-Member -NotePropertyName pack_dir    -NotePropertyValue $root       -Force
$cab | Add-Member -NotePropertyName connector_base -NotePropertyValue $script:LOBBY -Force
if ($DryRun) { Write-Warn 'dry run: cabinet.json not written' }
else {
  Write-Cab $cab $root
  Write-Ok 'cabinet.json written (it holds your host token - keep this folder to yourself)'
  # No station.json any more (doc-ops #117): it configured the per-seat Station Managers and their card editor,
  # which community packs no longer ship. Card editing is operator-only; the broker's card plane is
  # slot_station.py, configured on its command line.
}

# ---- 5. register this install's tasks ------------------------------------------------------------
Write-Head 'Registering this install''s background tasks'
$ps = 'powershell.exe'
$tasks = @(
  @{ Suffix = 'services';   Exe = $ps; Arg = (New-TaskPsLine $root (Join-Path $root 'start-services.ps1') ''            (Join-Path $logs 'services.log')) }
  @{ Suffix = 'windowless'; Exe = $ps; Arg = (New-TaskPsLine $root (Join-Path $root 'windowless.ps1')     ''            (Join-Path $logs 'windowless.log')) }
  # -NoChromeCrop, always: this pack runs BORDERLESS mains, and without the switch the capture cuts
  # 43px off the top and 13 off the bottom of each half (broadcast-wgc.ps1 clears the env var itself).
  @{ Suffix = 'broadcast';  Exe = $ps; Arg = (New-TaskPsLine $root (Join-Path $root 'broadcast-wgc.ps1')  "-Seats $seats -NoChromeCrop" (Join-Path $logs 'broadcast.log')) }
  @{ Suffix = 'game';       Exe = $ps; Arg = (New-GameTaskArg $root $game) }
)
if ($DryRun) {
  foreach ($t in $tasks) { Write-Note ("would register {0}" -f (Get-TaskName $t.Suffix)) }
} else {
  foreach ($t in $tasks) {
    try { $n = Register-HomeTask $t.Suffix $t.Exe $t.Arg; Write-Ok ("task {0}" -f $n) }
    catch { Write-Warn ("could not register {0}: {1}" -f (Get-TaskName $t.Suffix), $_.Exception.Message) }
  }
}

# ---- 6. start it -------------------------------------------------------------------------------
if (-not $startNow) {
  Write-Head 'Done - not started'
  Write-Note 'Run "SETUP - Start Here" again (or Doctor) when you want to bring it up.'
  Read-Host '  Press Enter to close'
  return
}
if ($DryRun) {
  Write-Head 'Dry run complete'
  Write-Note 'Nothing was paired, written or started.'
  return
}

Write-Head 'Starting the cabinet'
Write-Host '  Stations, broker, input service and the relay agent...' -ForegroundColor White
if (Start-HomeTask 'services') { Write-Ok 'services task started' } else { Write-Warn 'services task would not start' }
Start-Sleep -Seconds 8
Write-Host '  The game...' -ForegroundColor White
if (Start-HomeTask 'game') { Write-Ok 'game task started' } else { Write-Warn 'game task would not start' }
$rebalanceBootOk = $false
if ($game.Rom -eq 'docrebal') {
  . (Join-Path $root 'setup\RebalanceBoot.ps1')
  Write-Note ("Starting Main plus {0} seats automatically. Waiting for all boards and both Main displays..." -f $seats)
  $deadline = (Get-Date).AddSeconds(75)
  do {
    $rbState = Get-RebalanceBootState $root $seats
    if ($rbState.Ready) { $rebalanceBootOk = $true; break }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  if (-not $rebalanceBootOk) { Write-Bad ('Rebalance startup incomplete. Missing: ' + ($rbState.MissingBoards -join ', ') + '. See logs\game.log; check main\Rebalance\flycast.exe for a Windows error.') }
} else {
  Write-Note ("{0} windows open: Main plus {1} satellite{2}. Click the game picture once in each (MAIN first); the Main's right screen appears once they link." -f ($seats + 1), $seats, $(if ($seats -eq 1) { '' } else { 's' }))
  Start-Sleep -Seconds 25
}
Start-HomeTask 'windowless' | Out-Null          # satellites: strip their frames for edge-to-edge capture
$m = Set-MainsBorderless $root                  # mains: same, and the broadcast below runs -NoChromeCrop
if ($m) { Write-Ok ("{0} main board(s) borderless (full picture, no seam)" -f $m) }
$n = Set-GamePriority $root 'AboveNormal'
if ($n) { Write-Ok ("game priority raised on {0} window(s)" -f $n) }
if ($doVideo -and ($game.Rom -ne 'docrebal' -or $rebalanceBootOk)) {
  Write-Host '  Video broadcast...' -ForegroundColor White
  if (Start-HomeTask 'broadcast') { Write-Ok 'broadcast task started' } else { Write-Warn 'broadcast task would not start' }
  Start-Sleep -Seconds 10
  $e = Set-EncoderPriority $root 'BelowNormal'
  if ($e) { Write-Ok ("encoder priority lowered on {0} feed(s) so they never starve the game" -f $e) }
}

# ---- 7. verify ---------------------------------------------------------------------------------
Write-Head 'Checking it actually came up'
$fly = @(Get-OurFlycast $root)
if ($game.Rom -eq 'docrebal') {
  $rbState = Get-RebalanceBootState $root $seats
  $rebalanceBootOk = $rbState.Ready
  if ($rebalanceBootOk) { Write-Ok ("All {0} Rebalance seats and both Main displays have running Flycast processes ({1} expected)." -f $seats, $rbState.ExpectedProcesses) }
  else { Write-Bad ('Rebalance startup incomplete. Missing: ' + ($rbState.MissingBoards -join ', ') + '. See logs\game.log.') }
} else {
  if ($fly.Count -ge 2) { Write-Ok ("{0} game windows running" -f $fly.Count) } else { Write-Bad ("only {0} game window(s) - click the game picture in each window, then run Doctor" -f $fly.Count) }
}

$store = $null
foreach ($i in 1..10) { $store = Test-BrokerHealth; if ($store) { break }; Start-Sleep -Seconds 3 }
if ($store) { Write-Ok ("broker healthy on 8770 (store: {0})" -f $store) } else { Write-Bad 'broker not answering on 8770 - see logs\services.log' }

$down = @()
foreach ($p in (Get-SeatPorts $seats)) { if (-not (Test-Port $p)) { $down += $p } }
if ($down.Count -eq 0) { Write-Ok ("all {0} seat stations listening ({1})" -f $seats, ((Get-SeatPorts $seats) -join ', ')) }
else { Write-Bad ('seat stations not listening on: ' + ($down -join ', ')) }

if (Test-Tunnel $cab.id) { Write-Ok 'the lobby can reach this cabinet through the relay hub' }
else { Write-Warn 'the hub tunnel is not answering yet - give the agent a minute, then run Doctor' }

# THE check that would have saved an evening. Until the agent reported these, the cabinet was live and
# healthy on this machine while the lobby showed "Cabinet full" over a black board, and it was missing
# from the Host section. Give the beat a couple of tries - the first one lands within ~45s of start.
$ep = Get-LobbyEndpoints $cab.id
if (-not $ep.Ok) { foreach ($i in 1..6) { Start-Sleep -Seconds 10; $ep = Get-LobbyEndpoints $cab.id; if ($ep.Ok) { break } } }
if ($ep.Ok) {
  Write-Ok 'the lobby has this cabinet''s seat + video addresses (players can claim seats and see the board)'
  Write-Note ("broker: {0}" -f $ep.Broker)
  Write-Note ("video:  {0}" -f $ep.Whep)
} else {
  Write-Bad 'the lobby has NO addresses for this cabinet yet'
  Write-Note 'Until it does the lobby says "Cabinet full" over a black board and the cabinet will not'
  Write-Note 'appear in your Stable''s Host section. The relay agent reports them on its heartbeat, so:'
  Write-Note '  1. check the agent is running:  Doctor.cmd'
  Write-Note '  2. if it is not:                Doctor.cmd -FixBroker'
  Write-Note '  3. wait a minute and run Doctor again - one beat is all it takes'
}

if (Test-LobbyLive $cab.id $cab.label) { Write-Ok 'the cabinet is showing as LIVE in the lobby' }
else { Write-Warn 'not listed as live yet - the heartbeat takes a few seconds; run Doctor to re-check' }

Write-Host ''
Write-Host '  ===========================================================' -ForegroundColor Green
if ($game.Rom -eq 'docrebal' -and -not $rebalanceBootOk) {
  Write-Host ("   {0} is configured, but Rebalance has not started completely." -f $cab.label) -ForegroundColor Red
} else {
  Write-Host ("   {0} is set up." -f $cab.label) -ForegroundColor Green
}
Write-Host ("   Game:  {0}" -f $game.Name) -ForegroundColor Green
Write-Host ("   Seats: {0}{1}" -f $seats, $(if ($localSeats.Count) { ' (seat 1 reserved for you here)' } else { '' })) -ForegroundColor Green
Write-Host ("   Play:  {0}" -f $script:LOBBY) -ForegroundColor Green
Write-Host '  ===========================================================' -ForegroundColor Green
Write-Host ''
Write-Note 'Everyday buttons: Doctor (health), Restart Game, Switch Game, Stop Hosting.'
Write-Note 'Board looking cropped or seamed after a manual relaunch? "Fix Mains (borderless + full picture)".'
Read-Host '  Press Enter to close'
