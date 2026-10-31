# cabinet-doctor.ps1 -- "Cabinet Doctor": one-click hardware + video-encoder diagnosis for hosts.
# Inventories GPUs/displays/Windows, then ACTUALLY test-encodes on every H.264 path the bundled ffmpeg
# knows (NVENC / QuickSync / AMF / software), prints a plain-English verdict, and writes
# hardware-report.json + hardware-report.txt next to the pack. Drop hardware-report.json into
# #hosting-beta or #bug-reports and DOC Bot reads it and answers -- no more log-file archaeology.
# Ships in cabinet-pack 0.7.4 (CF-14 / the "sound but no video" trial-and-error killer).
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ((Split-Path -Leaf $root) -eq 'lib') { $root = Split-Path -Parent $root }

function Say($m) { Write-Host $m }
Say ''
Say '=== DOC Cabinet Doctor ==='
Say 'Checking your hardware and testing every video encoder... (takes ~30 seconds)'
Say ''

# ---- ffmpeg (bundled first, then next to the script, then anything on PATH) ----
$ff = @(
    (Join-Path $root 'runtime\ffmpeg\bin\ffmpeg.exe'),
    (Join-Path $root 'ffmpeg.exe'),
    ((Get-Command ffmpeg -EA SilentlyContinue).Source)
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $ff) { Say 'ERROR: ffmpeg not found (is the pack extracted completely?)'; exit 1 }

# ---- hardware inventory ----
$os  = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$ramGB = [math]::Round(($os.TotalVisibleMemorySize / 1MB), 1)
$gpus = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name })
$monitors = @(Get-CimInstance Win32_DesktopMonitor | Where-Object { $_.Status -eq 'OK' })
$gpuList = @()
foreach ($g in $gpus) {
    $driving = ($null -ne $g.CurrentHorizontalResolution -and $g.CurrentHorizontalResolution -gt 0)
    $vendor = 'other'
    if ($g.Name -match 'NVIDIA|GeForce|Quadro|RTX|GTX') { $vendor = 'nvidia' }
    elseif ($g.Name -match 'AMD|Radeon') { $vendor = 'amd' }
    elseif ($g.Name -match 'Intel') { $vendor = 'intel' }
    $gpuList += [ordered]@{
        name = $g.Name; vendor = $vendor; driver = $g.DriverVersion
        driving_display = $driving
        resolution = if ($driving) { "$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution)" } else { $null }
    }
}
$headless = -not ($gpuList | Where-Object { $_.driving_display })

# ---- encoder self-tests ----
# 256x256, NOT 128x128: newer NVENC generations reject frames under ~145px ("Frame Dimension less
# than the minimum supported value"), so a 128px probe false-fails a perfectly good NVIDIA card.
# Plain call operator + $LASTEXITCODE (Start-Process + redirected stderr misreports exit codes here).
function Test-Encoder($enc, $extra) {
    $out = Join-Path $env:TEMP "docdr_$enc.txt"
    & $ff -hide_banner -loglevel error -f lavfi -i 'testsrc2=size=256x256:rate=30' `
        -frames:v 5 -c:v $enc @extra -f null - 2>$out | Out-Null
    $code = $LASTEXITCODE
    $err = (Get-Content $out -EA SilentlyContinue | Where-Object { $_ } | Select-Object -First 1)
    Remove-Item $out -EA SilentlyContinue
    if ($code -eq 0) { return @{ ok = $true; error = $null } }
    return @{ ok = $false; error = [string]$err }
}
$encoders = [ordered]@{}
Say 'Testing encoders:'
foreach ($e in @(
    @{ id = 'h264_nvenc'; label = 'NVIDIA NVENC' },
    @{ id = 'h264_qsv';   label = 'Intel QuickSync' },
    @{ id = 'h264_amf';   label = 'AMD AMF' },
    @{ id = 'libx264';    label = 'Software (CPU)' })) {
    $r = Test-Encoder $e.id @()
    $encoders[$e.id] = [ordered]@{ label = $e.label; ok = $r.ok; error = $r.error }
    $mark = if ($r.ok) { 'PASS' } else { 'fail' }
    Say ("  {0,-16} {1,-16} {2}" -f $e.id, $e.label, $mark)
}
# Multi-NVIDIA: test each -gpu index so hosts with two NVIDIA cards learn which index works.
$nvidiaCount = @($gpuList | Where-Object { $_.vendor -eq 'nvidia' }).Count
$nvencGpus = @()
if ($encoders['h264_nvenc'].ok -and $nvidiaCount -gt 1) {
    for ($i = 0; $i -lt $nvidiaCount; $i++) {
        $r = Test-Encoder 'h264_nvenc' @('-gpu', "$i")
        $nvencGpus += [ordered]@{ gpu = $i; ok = $r.ok }
    }
}

# ---- current override state (what the streaming scripts will actually use) ----
$override = [ordered]@{
    env_DOC_VIDEO_ENCODER = [string]$env:DOC_VIDEO_ENCODER
    marker_use_software   = (Test-Path (Join-Path $root 'use-software-video.txt'))
    video_json            = $null
}
$vj = Join-Path $root 'video.json'
if (Test-Path $vj) { try { $override.video_json = (Get-Content $vj -Raw | ConvertFrom-Json) } catch { } }

# ---- verdict ----
$verdict = @()
$pick = $null
foreach ($cand in @('h264_nvenc','h264_qsv','h264_amf','libx264')) {
    if ($encoders[$cand].ok) { $pick = $cand; break }
}
$pickLabel = if ($pick) { $encoders[$pick].label } else { 'NONE' }
if (-not $pick) {
    $verdict += 'PROBLEM: no encoder passed, not even software. Something is wrong with the pack extraction or this Windows install. Post your report in Discord.'
} elseif ($pick -eq 'libx264') {
    $verdict += 'No GPU encoder works here, so streaming will use the CPU (software x264). It works, but expect high CPU load; a machine with an NVIDIA/Intel/AMD GPU encoder streams much lighter.'
} else {
    $verdict += "Best encoder on this machine: $pickLabel ($pick). The pack picks this automatically."
}
if ($headless) {
    $verdict += 'HEADLESS: no monitor is attached. Windows often caps capture around 30fps or gives black video on headless rigs. Plug in a monitor or an HDMI dummy plug (see HOST-GUIDE, "running without a monitor").'
}
if ($gpuList.Count -gt 1) {
    $displayGpu = ($gpuList | Where-Object { $_.driving_display } | Select-Object -First 1)
    $encVendor = @{ h264_nvenc = 'nvidia'; h264_qsv = 'intel'; h264_amf = 'amd' }[$pick]
    if ($displayGpu -and $encVendor -and $displayGpu.vendor -ne $encVendor) {
        $verdict += ("MULTI-GPU: your display runs on the {0} ({1}) but the encoder is on your {2} card. Capture and encode on different GPUs is the classic 'sound but no video' setup. If video is black, run '4 - Configure Video' and try the encoder that matches the display GPU, or move your monitor cable to the {2} card." -f $displayGpu.vendor, $displayGpu.name, $encVendor)
    }
}
if ($encoders['h264_nvenc'].ok -and $nvencGpus.Count -gt 1) {
    $okIdx = @($nvencGpus | Where-Object { $_.ok } | ForEach-Object { $_.gpu })
    $verdict += "You have $nvidiaCount NVIDIA GPUs; NVENC works on index(es): $($okIdx -join ', '). '4 - Configure Video' can pin one."
}
if ($override.env_DOC_VIDEO_ENCODER -or $override.marker_use_software -or $override.video_json) {
    $verdict += 'NOTE: a manual encoder override is active on this machine; the streaming scripts will honor it over auto-detect.'
}

# ---- write the report ----
$report = [ordered]@{
    kind = 'doc-cabinet-hardware-report'; version = 1
    generated = (Get-Date -Format s)
    pack = (Get-Content (Join-Path $root 'VERSION') -EA SilentlyContinue | Select-Object -First 1)
    windows = "$($os.Caption) build $($os.BuildNumber)"
    cpu = $cpu.Name; ram_gb = $ramGB
    gpus = $gpuList; monitors = $monitors.Count; headless = $headless
    encoders = $encoders; nvenc_gpu_tests = $nvencGpus
    override = $override
    recommended_encoder = $pick
    verdict = $verdict
}
$json = $report | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText((Join-Path $root 'hardware-report.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
$txt = @("DOC Cabinet Doctor report  $(Get-Date -Format s)", "Windows: $($report.windows)", "CPU: $($cpu.Name)  RAM: ${ramGB}GB")
foreach ($g in $gpuList) { $txt += "GPU: $($g.name) (driver $($g.driver))" + $(if ($g.driving_display) { " [driving display $($g.resolution)]" } else { '' }) }
$txt += "Monitors: $($monitors.Count)$(if ($headless) { ' (HEADLESS)' })"
foreach ($k in $encoders.Keys) { $e = $encoders[$k]; $txt += "Encoder $k ($($e.label)): " + $(if ($e.ok) { 'PASS' } else { "FAIL - $($e.error)" }) }
$txt += ''
$txt += $verdict
[System.IO.File]::WriteAllLines((Join-Path $root 'hardware-report.txt'), $txt)

Say ''
Say '=== Verdict ==='
$verdict | ForEach-Object { Say "* $_" }
Say ''
Say "Report written: hardware-report.json (+ .txt) in the pack folder."
Say 'Need help? Drop hardware-report.json into #hosting-beta or #bug-reports and DOC Bot will read it.'
Say ''
