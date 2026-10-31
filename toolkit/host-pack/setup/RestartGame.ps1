# RestartGame.ps1 -- restart only the emulator windows for THIS install.
# The relay side (stations, broker, input service, agent) keeps running, so seats stay claimed in the
# lobby and nothing has to re-pair. Use this when a window is stuck, a seat is wedged, or the layout
# got shuffled.
#
# Restarting the game is never JUST the game (learned the hard way on the office cabinet, 2026-09-19):
#   * the video encoders capture window handles, so they die with the windows and the lobby card goes
#     black until they are restarted - nothing does that automatically;
#   * a relaunched flycast comes back with its window frame, and the feed then crops 43px of live game
#     off the top of each main instead of chrome;
#   * a relaunched flycast also comes back at default priority.
# So this puts all three back: windows, borderless mains + video, priorities.
param([switch]$Quiet)

$ErrorActionPreference = 'Continue'
. (Join-Path (Split-Path -Parent $PSCommandPath) 'Common.ps1')
$root = Get-PackRoot
$cab  = Read-Cab $root
if (-not (Test-Paired $cab)) {
  Write-Bad 'not paired yet - run "SETUP - Start Here" first.'
  if (-not $Quiet) { Read-Host '  Press Enter to close' }
  return
}
$game = Get-GameByRom ([string]$cab.rom_ver)
if (-not $game) { $game = $script:GAMES[0] }

Write-Host ''
Write-Host '  === RESTART GAME ===' -ForegroundColor Cyan
Write-Ok ("game: {0}" -f $game.Name)

$fly = @(Get-OurFlycast $root)
if ($fly.Count) {
  Write-Host ("  closing {0} window(s)..." -f $fly.Count) -ForegroundColor White
  foreach ($p in $fly) { try { $p.Kill() } catch { } }
  Start-Sleep -Seconds 4
} else { Write-Note 'nothing running to close' }

Write-Host '  launching...' -ForegroundColor White
if (-not (Start-HomeTask 'game')) {
  # No task registered (hand-copied pack, or setup never ran): run the launcher directly, same as the task.
  Start-Process -FilePath 'powershell.exe' -ArgumentList (New-GameTaskArg $root $game) -WindowStyle Hidden
}
$seats = Get-SeatCount $cab
if ($game.Rom -eq 'docrebal') {
  . (Join-Path $root 'setup\RebalanceBoot.ps1')
  $deadline = (Get-Date).AddSeconds(75)
  do {
    $rbState = Get-RebalanceBootState $root $seats
    if ($rbState.Ready) { break }
    Start-Sleep -Seconds 2
  } while ((Get-Date) -lt $deadline)
  if (-not $rbState.Ready) { Write-Bad ('Rebalance startup incomplete. Missing: ' + ($rbState.MissingBoards -join ', ') + '. See logs\game.log.') }
} else { Start-Sleep -Seconds 25 }
Start-HomeTask 'windowless' | Out-Null          # satellites borderless
$m = Set-MainsBorderless $root                  # mains borderless (they come back framed)
if ($m) { Write-Ok ("{0} main board(s) borderless again" -f $m) }

# The feeds died with the old windows. Bring them back, with the crop off to match the borderless mains.
$seats = Get-SeatCount $cab
Write-Host '  restarting the video feeds (they die with the game windows)...' -ForegroundColor White
if ($game.Rom -eq 'docrebal' -and -not $rbState.Ready) { Write-Warn 'Video waits until all Rebalance boards are running.' }
elseif (Restart-Broadcast $root $seats) { Write-Ok ("video publishing again for {0} seat(s), full picture" -f $seats) }
else { Write-Warn 'could not restart the video - run Doctor.cmd -FixVideo' }

$n = Set-GamePriority $root 'AboveNormal'
$e = Set-EncoderPriority $root 'BelowNormal'
$fly = @(Get-OurFlycast $root)
if ($game.Rom -eq 'docrebal') {
  $rbState = Get-RebalanceBootState $root $seats
  if ($rbState.Ready) { Write-Ok ("All {0} Rebalance seats and both Main displays have running processes." -f $seats) }
  else { Write-Bad ('Rebalance startup incomplete: ' + ($rbState.MissingBoards -join ', ')) }
} else {
  if ($fly.Count -ge 2) { Write-Ok ("{0} game windows running" -f $fly.Count) } else { Write-Warn ("only {0} window(s) - click the game picture in each, MAIN first" -f $fly.Count) }
  Write-Note 'Click the game picture once in each window (MAIN first) to boot and link them.'
}
Write-Ok ("priorities set: game AboveNormal ({0}), encoders BelowNormal ({1})" -f $n, $e)
Write-Note 'Then hard-refresh the lobby page (Ctrl+Shift+R) - an open page holds the old video stream.'

$store = Test-BrokerHealth
if ($store) { Write-Ok 'broker still healthy - seats keep working' } else { Write-Warn 'broker is down - run Doctor -FixBroker' }
Write-Host ''
if (-not $Quiet) { Read-Host '  Press Enter to close' }
