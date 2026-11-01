# DocHostRecover.ps1 -- remote Restart / Refresh screens for a HOST cabinet (DOC Host app, doc-ops #117).
#
# The host-cabinet twin of the house boxes' recover_listener.ps1. A remote player presses Restart or
# Refresh screens on the lobby; the website queues a request for this cabinet; this loop picks it up and
# runs ONE fixed action of THIS install:
#   level 'full'   (Restart)         -> DocHostActions.ps1 -Action RestartGame  (the pack's RestartGame.ps1)
#   level 'bounce' (Refresh screens) -> DocHostActions.ps1 -Action FixPicture   (borderless + republish video;
#                                       Flycast is never restarted)
# It never reboots Windows, never restarts the broker, runs no other command and takes nothing from the
# request except its id, level and timestamps.
#
# Outbound only, authenticated with this cabinet's own token (X-Cabinet-Token, from cabinet.json; the same
# token and site the pack's relay agent uses). Contract: doc-arcade PR #73 (the website side, separate PR):
#   GET  <site>/api/cabinet/recover/poll   -> { ok, request: null | { id, kind: recover|bounce,
#        level: full|bounce, seat, created_at, ack_within_s } }. A returned request is already claimed.
#        401 = token refused (bad, banned, retired) and 403 = house cabinet: stop polling, show it in the window.
#   POST <site>/api/cabinet/recover/ack    { id, outcome, detail? }   within ack_within_s (120 s) of the claim.
#        outcome: triggered | refused_by_host | busy | skipped-cooldown | failed. Only a request this listener
#        claimed is acked. 404 (not ours, answered, or acked too late), 409 (never claimed) and 403 (house
#        token) are final: never retried.
# Polling IS the lobby's signal that this cabinet takes remote restarts: the lobby hides its Restart and
# Refresh screens tiles about 5 minutes after the last poll. So the listener polls every 12 s while hosting,
# and while the host has remote restarts switched OFF it does not poll at all (the tiles go away). A request
# already claimed when the host switches it off is still answered, with refused_by_host.
# "triggered" is sent the moment the action starts (a game restart can outlast the ack window); how it
# finished is in the log.
#
# Guards (house listener + the useful parts of doc-stream PR #9 / doc-arcade PR #48, doc-ops #98):
#   - the host's switch "Let remote players restart and fix screens" (settings.json): off = no polling;
#     a request claimed just before the switch went off is answered refused_by_host
#   - no local clock check: the website hands out only requests younger than its claim window and refuses
#     an ack later than 120 s after the claim, so a PC clock that is off never blocks a request
#   - one at a time: the per-install action mutex shared with the window's buttons (busy)
#   - a Restart within 180 s of the last restart, remote or the host's own Restart game button:
#     skipped-cooldown (the house box cooldown)
#   - not hosting (no game of ours, or the broker on 8770 is not ours or does not answer): failed, fail closed
#   - both kinds: busy while the broker's maintenance flag is up (a recovery or version switch that closes
#     and relaunches boards)
#   - Restart only (John, 2026-10-09; Refresh screens stays available): busy while a seat is reserved
#     for local play (Host Console) or a card save or load is in progress (a draining seat, a held leaver)
#   - a request id is acted on once; a repeat gets the recorded answer again
# Log: <data>\logs\recover_listener.log. Listener state for the window: <data>\recover-status.json.
param(
  [string]$PackRoot = '',      # informational: lets Stop and the window find this listener by command line
  [switch]$Once,               # tests: one poll, then exit
  [int]$PollSeconds = 12
)

. (Join-Path $PSScriptRoot 'DocHostCommon.ps1')

$script:REC_COOLDOWN_S = 180
$script:REC_STATUS = Join-Path $script:DH_DATA 'recover-status.json'
$script:REC_POLL = '/api/cabinet/recover/poll'
$script:REC_ACK = '/api/cabinet/recover/ack'

function L([string]$m) { Write-DhLog 'recover_listener.log' $m; if ($Once) { [Console]::Out.WriteLine($m) } }

$script:lastState = ''
function Set-RecStatus([string]$state, [string]$detail) {
  $script:lastState = $state
  try {
    New-Item -ItemType Directory -Path $script:DH_DATA -Force | Out-Null
    $o = [ordered]@{ state = $state; detail = $detail; at = (Get-Date).ToUniversalTime().ToString('o'); pid = $PID }
    Write-DhFileAtomic $script:REC_STATUS ($o | ConvertTo-Json -Compress)
  } catch { }
}

# Pure decision: everything it needs is passed in, so tests can drive every branch.
#   $req     { id, kind, level, seat, created_at }
#   $health  broker /api/health object, or $null when it did not answer
# Returns @{ Run = 'RestartGame' | 'FixPicture' | $null; Outcome; Detail }
function Get-RecoverDecision($req, [bool]$allowed, $health, [bool]$brokerOurs, [int]$ourGame, [double]$lastRestartAt, [double]$now) {
  $level = [string]$req.level
  if (-not $level) {
    if ([string]$req.kind -eq 'bounce') { $level = 'bounce' } elseif ([string]$req.kind -eq 'recover') { $level = 'full' }
  }
  if ($level -ne 'full' -and $level -ne 'bounce') { return @{ Run = $null; Outcome = 'failed'; Detail = 'unknown request kind' } }
  if (-not $allowed) { return @{ Run = $null; Outcome = 'refused_by_host'; Detail = 'the host has turned remote restarts off' } }
  if ($ourGame -lt 1 -or -not $health -or -not $brokerOurs) { return @{ Run = $null; Outcome = 'failed'; Detail = 'this cabinet is not hosting right now' } }
  $f = $health.flags
  # The broker's maintenance flag (a recovery chain or a version switch closing and relaunching boards)
  # blocks BOTH: a screen refresh in the middle of that fights the relaunch.
  if ($f -and $f.maintenance -eq $true) { return @{ Run = $null; Outcome = 'busy'; Detail = 'maintenance or a version switch is in progress' } }
  # Refresh screens never touches the game or a card, so it stays available while seats are reserved or
  # a horse is being saved (John, 2026-10-09). The busy guards below are for Restart only.
  if ($level -eq 'bounce') { return @{ Run = 'FixPicture'; Outcome = 'triggered'; Detail = 'screen refresh started' } }
  if ($f -and @($f.local_seats).Count -gt 0) { return @{ Run = $null; Outcome = 'busy'; Detail = 'a seat is reserved for the host at this PC' } }
  $leavers = 0
  if ($health.holds -and $health.holds.seats) {
    foreach ($p in $health.holds.seats.PSObject.Properties) { if ($null -ne $p.Value.leaver_held_s) { $leavers++ } }
  }
  if (($f -and @($f.draining).Count -gt 0) -or $leavers -gt 0) {
    return @{ Run = $null; Outcome = 'busy'; Detail = 'a horse is being saved or loaded' }
  }
  if ($level -eq 'full') {
    if ($lastRestartAt -gt 0 -and ($now - $lastRestartAt) -lt $script:REC_COOLDOWN_S) {
      return @{ Run = $null; Outcome = 'skipped-cooldown'; Detail = ('restarted {0} s ago' -f [int]($now - $lastRestartAt)) }
    }
    return @{ Run = 'RestartGame'; Outcome = 'triggered'; Detail = 'game restart started' }
  }
  return @{ Run = 'FixPicture'; Outcome = 'triggered'; Detail = 'screen refresh started' }
}

# Returns the HTTP status (200 ok, 404 final, 0 no answer). Never retried: 404 means not ours or answered.
function Send-Ack([string]$tok, [string]$id, [string]$outcome, [string]$detail) {
  $o = [ordered]@{ id = $id; outcome = $outcome }
  if ($detail) { $o.detail = $detail.Substring(0, [Math]::Min(200, $detail.Length)) }
  try {
    Invoke-RestMethod -Method Post -Uri ($script:LOBBY + $script:REC_ACK) -Headers @{ 'X-Cabinet-Token' = $tok } `
      -ContentType 'application/json' -Body ($o | ConvertTo-Json -Compress) -TimeoutSec 20 | Out-Null
    return 200
  } catch {
    $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch { }
    if ($code -eq 404) { L ("ack {0}: 404, not ours, already answered or too late (final, not retried)" -f $id) }
    elseif ($code -eq 409) { L ("ack {0}: 409, the website never handed this request out (final, not retried)" -f $id) }
    elseif ($code -eq 403) { L ("ack {0}: 403, the website treats this as a house cabinet (final)" -f $id) }
    else { L ("ack {0} failed ({1}): {2}" -f $id, $code, $_.Exception.Message) }
    return $code
  }
}

function Test-DhActionFree {
  $m = Enter-DhAction 0
  if ($m) { Exit-DhAction $m; return $true }
  return $false
}

function Invoke-ActionChild([string]$verb) {
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $actions = Join-Path $script:DH_SCRIPTS 'DocHostActions.ps1'
  $out = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $actions -Action $verb 2>&1
  $code = $LASTEXITCODE
  foreach ($line in @($out)) { L ("  " + [string]$line) }
  return $code
}

# One poll. Returns seconds to wait, or -1 to stop the loop (token refused, house cabinet).
function Invoke-RecoverPoll {
  $cab = Read-Cab $script:DH_PACK
  if (-not (Test-Paired $cab)) { Set-RecStatus 'not-paired' ''; return 30 }
  $tok = [string]$cab.host_token
  # Switched off by the host: do not poll, so the lobby stops offering the buttons for this cabinet.
  if (-not [bool](Get-DhSettings).remote_recover) {
    if ($script:lastState -ne 'off') { L 'remote restarts are switched off by the host: not polling' }
    Set-RecStatus 'off' 'switched off by the host'
    return 5
  }
  try {
    $r = Invoke-RestMethod -Uri ($script:LOBBY + $script:REC_POLL) -Headers @{ 'X-Cabinet-Token' = $tok } -TimeoutSec 20
  } catch {
    $code = 0
    try { $code = [int]$_.Exception.Response.StatusCode } catch { }
    if ($code -eq 401) {
      L 'the website refused this cabinet''s token (401): remote restarts stopped. Pair again or ask the operator.'
      Set-RecStatus 'token-refused' 'the website refused this cabinet''s token'
      return -1
    }
    if ($code -eq 403) {
      L 'the website says this is a house cabinet (403): this listener stops'
      Set-RecStatus 'house-cabinet' 'house cabinets use their own listener'
      return -1
    }
    if ($code -in @(404, 405, 501)) {
      if (((Get-Date) - $script:lastMissingLog).TotalMinutes -ge 60) { L 'the website does not offer host-cabinet restarts yet; checking again in 5 minutes'; $script:lastMissingLog = Get-Date }
      Set-RecStatus 'site-not-ready' 'the website does not offer host restarts yet'
      return 300
    }
    L ("poll failed: {0}" -f $_.Exception.Message)
    Set-RecStatus 'offline' $_.Exception.Message
    return $PollSeconds
  }
  if ($script:lastState -ne 'listening') { L 'polling for remote restart requests' }
  Set-RecStatus 'listening' ''
  $req = $r.request
  if (-not $req -or -not $req.id) { return $PollSeconds }
  $id = [string]$req.id
  if ($id -notmatch '^[A-Za-z0-9-]{1,64}$') { L 'ignored a request with a malformed id'; return $PollSeconds }

  $state = Read-DhRecState
  $seen = @($state.handled | Where-Object { $_.id -eq $id }) | Select-Object -First 1
  if ($seen) {
    L ("request {0} was already handled ({1}); answering the same again" -f $id, $seen.outcome)
    Send-Ack $tok $id ([string]$seen.outcome) ([string]$seen.detail) | Out-Null
    return $PollSeconds
  }

  # Test hook (sandbox test builds only): the host switches remote restarts off between poll and answer.
  if ($script:DH_SANDBOX -and $env:DOCHOST_TEST_OFF_AFTER_POLL -eq '1') { $t = Get-DhSettings; $t.remote_recover = $false; Set-DhSettings $t }
  $settings = Get-DhSettings
  $health = Get-DhBrokerHealth
  $ours = Test-DhBrokerOurs
  $game = @(Get-OurFlycast $script:DH_PACK).Count
  $now = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $d = Get-RecoverDecision $req ([bool]$settings.remote_recover) $health $ours $game $state.last_restart_at $now
  if ($d.Run -and -not (Test-DhActionFree)) { $d = @{ Run = $null; Outcome = 'busy'; Detail = 'another DOC Host action is running' } }
  L ("request {0} level={1} seat={2} created={3} -> {4} ({5})" -f $id, $req.level, $req.seat, $req.created_at, $d.Outcome, $d.Detail)

  if ($d.Run -eq 'RestartGame') { $state.last_restart_at = $now }
  $state.handled = @($state.handled) + @([pscustomobject]@{ id = $id; outcome = $d.Outcome; detail = $d.Detail; at = $now })
  Save-DhRecState $state          # recorded BEFORE running: a crash mid-run never replays the request
  $ackCode = @(Send-Ack $tok $id $d.Outcome $d.Detail)[-1]
  if ($d.Run -and $ackCode -ne 200) {
    # The lobby did not take "triggered" (expired, answered, unreachable): it is not showing a restart, so
    # nothing runs behind its back.
    L ("request {0} not run: the website did not accept the answer (code {1})" -f $id, $ackCode)
  } elseif ($d.Run) {
    $code = Invoke-ActionChild $d.Run
    $how = "failed (code $code)"
    if ($code -eq 0) { $how = 'ok' } elseif ($code -eq 2) { $how = 'another action took the lock first' }
    L ("request {0} finished: {1}" -f $id, $how)
  }
  return $PollSeconds
}

if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced by a test: functions only

$script:lastMissingLog = [datetime]::MinValue
# One listener per install. The task used to be "ignore a new start while running", which kept a second copy
# out; launched through "DocHostTask.exe --hidden-run" the task ends at once, so the listener guards itself.
if (-not $Once) {
  $script:recMutex = New-Object Threading.Mutex($false, ('Local\DOCHost_Recover_' + (Get-DhRootTag)))
  $got = $false
  try { $got = $script:recMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $got = $true }
  if (-not $got) { L 'another recover listener is already running for this install: exiting'; return }
}
L ("recover listener start; pack={0} site={1} poll={2}s sandbox={3}" -f $script:DH_PACK, $script:LOBBY, $PollSeconds, $script:DH_SANDBOX)
while ($true) {
  $wait = $PollSeconds
  try { $wait = @(Invoke-RecoverPoll)[-1] } catch { L ("loop error: " + $_.Exception.Message) }
  if ($wait -lt 0) { L 'listener stopped'; break }
  if ($Once) { break }
  Start-Sleep -Seconds ([Math]::Max(5, [int]$wait))
}
