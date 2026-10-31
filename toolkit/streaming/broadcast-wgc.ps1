# broadcast-wgc.ps1 -- broadcast this cabinet's screens to the DOC relay (window-pinned WGC capture).
# No embedded credentials: reads YOUR cabinet.json (id + host_token); the relay only accepts your token
# for your own cabinet's streams. Mains always; seats with -Seats N (full relay-hosted cabinets).
#
# Put this kit in your PACK ROOT (the folder holding cabinet.json). Needs the streaming runtime
# (runtime\python + runtime\ffmpeg) -- HostPack (local) rigs: use relay-runtime-addon.zip.
#
#   .\broadcast-wgc.ps1              # mains only (spectator broadcast)
#   .\broadcast-wgc.ps1 -Seats 4     # mains + seat1..seat4 (relay-hosted cabinet)
#   .\broadcast-wgc.ps1 -Stop        # stop everything
#   .\broadcast-wgc.ps1 -MainsMode split   # the old two-stream mains (mainl + mainr), the rollback switch
#   .\broadcast-wgc.ps1 -AlsoSplit         # rollout: ALSO publish mainl + mainr beside the combined stream
param(
  [switch]$Stop,
  [int]$Seats = 0,
  [string]$Relay = "5.78.188.88",
  [string]$SeatBitrate = "",  # e.g. "2M" on a thin uplink (mains stay 6M); empty = flat 6M
  [string]$Proto = "rtmp",    # seat feeds: rtmp (default) or "srt"
  [string]$MainsProto = "srt", # the main screens: srt (default, doc-ops #117) or "rtmp" (the old mains transport)
  # MAINS MODE (doc-ops #117, PR #32 v3). "combined" (default) = ONE stream, both main screens side by side,
  # pushed over ONE connection to the bare cab_<id> path: the halves are the same video frame, so they cannot
  # drift apart. "split" = the old two streams (mainl, mainr), the rollback switch.
  [ValidateSet("combined", "split")][string]$MainsMode = "combined",
  [string]$MainsBitrate = "10M", # the combined stream's bitrate: under the 12M the two 6M halves cost together
  # During a rollout, viewers on an older lobby page only know mainl/mainr. -AlsoSplit publishes those TOO
  # (a further 12M of upload), so default OFF: a thin uplink should not pay for both.
  [switch]$AlsoSplit,
  [switch]$NoChromeCrop,      # borderless rigs (windowless pass applied): don't crop title-bar pixels
  [switch]$NoAudio            # skip the audio feeds (race audio + per-seat)
)
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition

# KILL-FIRST (rig finding #4): capture publishers ACCUMULATE across relaunches (a stacked-publisher
# crash-loop was found live). Always evict every old capture before starting fresh ones.
# THIS install's pushers only (doc-ops #51): each is started by its full script path under $here.
$pushers = @(@('wgc_relay_push.py', 'audio_relay_push.py') | ForEach-Object { Join-Path $here $_ })
$cfgPath = Join-Path $here "cabinet.json"
# CHILDREN TOO (doc-ops #117, PR #32 v2): killing a pusher python did NOT kill its ffmpeg (a bare Popen child),
# so the old ffmpeg kept publishing cab_<id>/<feed> while the new pusher's ffmpeg fought it for the same path.
# Pushers now put their children in a kill-on-close Job Object; this sweep also covers pushers started before
# that, and orphans. Matched by THIS cabinet's publish path (cab_<id>/<feed> for a seat or a main half, or the bare
# cab_<id> followed by ':' or '?' for the combined mains stream) or THIS install's capture exe path, or
# by parent PID = one of our pushers. Never by process name alone.
$cabTags = @()
if (Test-Path $cfgPath) { try { $i = [string](Get-Content $cfgPath -Raw | ConvertFrom-Json).id; if ($i) { $cabTags = @("cab_${i}/", "cab_${i}:", "cab_${i}?") } } catch { } }
$capExe = Join-Path $here "seat_audio_capture.exe"
function Get-OurFeedProcs([int[]]$parents) {
  @(Get-CimInstance Win32_Process | Where-Object {
    $cl = [string]$_.CommandLine; $nm = [string]$_.Name
    ($cl -and @($pushers | Where-Object { $cl.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0) -or
    (($nm -ieq 'ffmpeg.exe' -or $nm -ieq 'seat_audio_capture.exe') -and $parents -contains [int]$_.ParentProcessId) -or
    ($nm -ieq 'ffmpeg.exe' -and $cl -and @($cabTags | Where-Object { $cl.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0) -or
    ($nm -ieq 'seat_audio_capture.exe' -and $cl -and $cl.IndexOf($capExe, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
  })
}
# Pushers first (a live pusher respawns a dead ffmpeg), then their children; wait (10 s cap) until none remain.
$found = @(Get-OurFeedProcs @())
$pusherPids = @($found | Where-Object { $_.Name -ieq 'python.exe' -or $_.Name -ieq 'pythonw.exe' } | ForEach-Object { [int]$_.ProcessId })
$found | Sort-Object { if ($pusherPids -contains [int]$_.ProcessId) { 0 } else { 1 } } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
$deadline = (Get-Date).AddSeconds(10)
# @(...) at the CALL SITE: a function's own @() is unrolled on return, so ONE survivor arrives as a bare
# CimInstance and .Count is $null (Windows PowerShell 5.1) -- the sweep would skip exactly that one leftover.
$left = @()
while (($left = @(Get-OurFeedProcs $pusherPids)).Count -gt 0 -and (Get-Date) -lt $deadline) {
  $left | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
  Start-Sleep -Milliseconds 250
}
if (@($left).Count -gt 0) { Write-Host ("{0} old feed process(es) still running after 10 s: {1}" -f @($left).Count, (($left | ForEach-Object { "$($_.Name) $($_.ProcessId)" }) -join ', ')) -ForegroundColor Red }
if ($Stop) { Write-Host "relay broadcasts stopped." -ForegroundColor Yellow; return }

if (-not (Test-Path $cfgPath)) { Write-Host "cabinet.json not found - put this kit in your pack ROOT and pair first (1 - Start Cabinet)." -ForegroundColor Red; return }
$CAB = Get-Content $cfgPath -Raw | ConvertFrom-Json
$id = [string]$CAB.id; $tok = [string]$CAB.host_token
if (-not $id -or -not $tok -or $tok -like "*PASTE*") { Write-Host "cabinet.json has no id/host_token - pair first." -ForegroundColor Red; return }

$py = Join-Path $here "runtime\python\python.exe"
if (-not (Test-Path $py)) { Write-Host "runtime\python not found - HostPack rigs need relay-runtime-addon.zip (it ships the streaming runtime)." -ForegroundColor Red; return }

# Fresh CA bundle (rig finding #6): the embedded runtime's cacert can be EXPIRED, killing every HTTPS/WSS
# call with CERTIFICATE_VERIFY_FAILED. The kit ships a current cacert.pem; point python at it.
$ca = Join-Path $here "cacert.pem"
if (Test-Path $ca) { $env:SSL_CERT_FILE = $ca; $env:REQUESTS_CA_BUNDLE = $ca }

& $py -c "import windows_capture, numpy, psutil" 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "This runtime lacks the WGC deps - re-extract the relay runtime add-on." -ForegroundColor Red; return }

$mainFeeds = @(if ($MainsMode -eq "split") { @("mainl", "mainr") } elseif ($AlsoSplit) { @("mains", "mainl", "mainr") } else { @("mains") })
$feeds = $mainFeeds + @(if ($Seats -gt 0) { 1..$Seats | ForEach-Object { "seat$_" } })
if ($NoChromeCrop) { $env:DOC_CHROME_CROP = "0" } else { Remove-Item Env:DOC_CHROME_CROP -EA SilentlyContinue }
# MAINS RIDE ONE STREAM (doc-ops #117, PR #32 v3). Each main half used to be its own connection over the host's
# congested uplink: every connection loses packets and stalls on its own (the relay saw ~1 loss recovery per
# second per socket, ping 48-472 ms), so the two halves drifted 100-400 ms apart over RTMP. SRT removed the
# stalls (it re-paces each packet and re-sends a loss inside a fixed window) but the relay fixes each
# connection's latency at its handshake, which left a constant ~160 ms between the halves. Two connections
# cannot be made to agree, so the combined mode sends ONE: both screens in one picture, one encode, one
# connection. SRT (200 ms, the latency the race audio already rides) is the transport for the mains; seats keep
# $Proto (rtmp): their latency is the player's input lag. -MainsProto rtmp restores the old mains transport,
# -MainsMode split restores the two-stream mains.
foreach ($feed in $feeds) {
  $isMain = ($feed -eq "mains" -or $feed -like "main[lr]")
  $fp = if ($isMain) { $MainsProto } else { $Proto }
  $pth = if ($feed -eq "mains") { "cab_$id" } else { "cab_$id/$feed" }   # the combined stream is the BARE cab_<id> path
  if ($fp -eq "srt") {
    $env:DOC_OUT_URL = "srt://{0}:8890?streamid=publish:{1}:cab:{2}&latency=200000" -f $Relay, $pth, $tok
  } else {
    $env:DOC_OUT_URL = "rtmp://{0}:1935/{1}?user=cab&pass={2}" -f $Relay, $pth, $tok
  }
  if ($feed -eq "mains") { $env:DOC_RELAY_BITRATE = $MainsBitrate }
  elseif ($SeatBitrate -and $feed -like "seat*") { $env:DOC_RELAY_BITRATE = $SeatBitrate }
  else { Remove-Item Env:DOC_RELAY_BITRATE -EA SilentlyContinue }
  Start-Process -FilePath $py -ArgumentList ('"' + (Join-Path $here "wgc_relay_push.py") + '" ' + $feed) -WindowStyle Hidden
  Write-Host "started $feed -> $pth" -ForegroundColor Green
}
Remove-Item Env:DOC_OUT_URL, Env:DOC_RELAY_BITRATE -EA SilentlyContinue
if (-not $NoAudio) {
  # Audio rides SRT (RTMP can't carry Opus; WebRTC can't play AAC): ONE supervisor = race audio
  # (master main only, the comb-filter lesson) + a per-seat feed when hosting seats.
  $env:DOC_CAB_ID = $id; $env:DOC_HOST_TOKEN = $tok; $env:DOC_RELAY_HOST = $Relay
  Start-Process -FilePath $py -ArgumentList ('"' + (Join-Path $here "audio_relay_push.py") + '" ' + $Seats) -WindowStyle Hidden
  Remove-Item Env:DOC_CAB_ID, Env:DOC_HOST_TOKEN, Env:DOC_RELAY_HOST -EA SilentlyContinue
  Write-Host ("started audio (raceaudio" + $(if ($Seats -gt 0) { " + $Seats seat feeds" }) + ")") -ForegroundColor Green
}
Write-Host "`nBroadcasting to your lobby card. Logs: .\stream\stream_*.log   Stop: .\broadcast-wgc.ps1 -Stop" -ForegroundColor Cyan
Write-Host "Windows can move or be covered freely (WGC captures by window handle). Encode: mains $MainsBitrate combined (6M per half with -MainsMode split), 6M per seat (set -SeatBitrate 2M on thin uplinks)." -ForegroundColor DarkGray
