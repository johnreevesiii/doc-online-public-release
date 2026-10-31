"""
Stream ONE DOC window (a seat OR a main screen) to MediaMTX via WGC + FFmpeg.
  py -3 stream_window_wgc.py <target>
  <target> = seat1..seat4   -> the satellite Flycast window (found by exe path \satN\)
           = mainl | mainr   -> the master terminal's left / right screen (the two \main\ procs,
                                 told apart by window x-position: leftmost = mainl, rightmost = mainr)
           = mains           -> BOTH main screens in this ONE process, stacked side by side into one picture,
                                 encoded once and pushed over ONE connection (doc-ops #117, v3). The two halves
                                 are the same video frame, so they cannot drift apart (see mains_combine.py).
The MediaMTX/RTSP path == <target>; the player page reads http://<box>:8889/<target>/whep.
MUST run in the interactive session (session 2) so WGC + the windows are reachable.

Carries the proven fixes from the seat path: lock the frame size on frame 0 and coerce every later
frame to it (windows-capture changes size after frame 0, which desyncs FFmpeg's rawvideo pipe -> shear).
"""
import sys
TARGET = (sys.argv[1] if len(sys.argv) > 1 else "seat1").lower()
import os as _os
_BASE = _os.path.dirname(_os.path.abspath(__file__))
_SD = _os.path.join(_BASE, 'stream')
try: _os.makedirs(_SD, exist_ok=True)
except Exception: pass
_FF = _os.path.join(_BASE, 'runtime', 'ffmpeg', 'bin', 'ffmpeg.exe')
_CAP = _os.path.join(_BASE, 'seat_audio_capture.exe')

sys.stdout = sys.stderr = open(_os.path.join(_SD, r"stream_%s.log") % TARGET, "w", buffering=1)
import ctypes, subprocess, time, os
from ctypes import wintypes
import numpy as np
import psutil
from windows_capture import WindowsCapture, Frame, InternalCaptureControl

FFMPEG = _FF

# Per-seat low-res mode: set by flex_seat_stream.ps1 (DOC_SEAT_LORES=1) when a seat flexes to LOCAL.
# When on, the encode drops to 240p + a 600k bitrate for WHATEVER encoder _pick_encoder selects on this
# host; when unset, the full-res (2M) path is byte-for-byte unchanged. Read once at startup (the ps1
# relaunches the process per flip), so it composes with the multi-encoder detection below.
LORES = _os.environ.get("DOC_SEAT_LORES") == "1"

# Pick a working H.264 encoder for THIS host (hosts vary: NVIDIA/Intel/AMD/none). The old hardcoded
# h264_nvenc crash-loops on any box without an NVIDIA GPU ("Cannot load nvcuda.dll"). Detected once.
def _enc_ok(_e):
    try:
        _r = subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                             "-i", "testsrc2=size=256x256:rate=30", "-frames:v", "5",   # 256 not 128: newer NVENC rejects <~145px frames (false-failed good NVIDIA cards -> silent x264 fallback)
                             "-c:v", _e, "-f", "null", "-"], capture_output=True, timeout=25)
        return _r.returncode == 0
    except Exception:
        return False
def _pick_encoder():
    # Pin yuv420p + a baseline / constrained-baseline profile so the H.264 is decodable by EVERY browser
    # WebRTC stack. WITHOUT this, some GPU encoders (seen on newer NVENC and on AMD AMF) publish a
    # valid-looking stream, yet viewers get BLACK video while the muxed audio still plays -- the encoder
    # defaulted to a High profile / format the browser refuses. Baseline+yuv420p is the universal form.
    # LORES (a seat flexed to LOCAL) drops the bitrate to the mains _lo 600k recipe for WHATEVER encoder is
    # picked below; the full-res 2M values are unchanged when DOC_SEAT_LORES is unset.
    # Relay clarity lever (John, live-rig validated 2026-07-24): bitrate, not resolution, is what
    # sharpens the stream -- flat 6M on every non-LORES feed looked "pretty good" at 2-4% CPU on six
    # software encodes (~29 Mbps total upload). Thin uplinks: set DOC_RELAY_BITRATE=2M on seat feeds
    # (mains stay 6M) for ~21 Mbps total. LORES (local-flexed seats) unchanged at 600k.
    if LORES:
        _bv, _mr, _buf = ("600k", "600k", "1200k")
    else:
        # The combined "mains" feed carries both halves in one encode; its default (10M) is under the 12M the
        # two 6M halves used to cost, so the one-connection fix does not add to a congested uplink.
        _rate = _os.environ.get("DOC_RELAY_BITRATE", "10M" if TARGET == "mains" else "6M")
        # bufsize = ~1s at the target rate (was 2s): a tighter VBV smooths the send-rate bursts that
        # make the two mains queue unevenly on the uplink (the observed inter-main desync driver).
        _bv, _mr, _buf = (_rate, _rate, _rate)
    _c = ["-b:v", _bv, "-maxrate", _mr, "-bufsize", _buf, "-bf", "0", "-g", "120", "-pix_fmt", "yuv420p"]
    # Escape hatch for the rare GPU whose H.264 STILL won't decode in browsers even at baseline (black video,
    # audio fine -- e.g. the newest NVENC, too new for the bundled ffmpeg): force browser-safe SOFTWARE by
    # setting env DOC_VIDEO_ENCODER=libx264, OR by dropping an empty file named 'use-software-video.txt' in the
    # pack folder. DOC_VIDEO_ENCODER can also pin nvenc/qsv/amf explicitly.
    _force = _os.environ.get("DOC_VIDEO_ENCODER", "").strip().lower()
    if not _force and _os.path.exists(_os.path.join(_BASE, "use-software-video.txt")): _force = "libx264"
    if not _force:
        # video.json (written by "4 - Configure Video" / the Cabinet Doctor flow): {"encoder": "auto|nvenc|qsv|amf|libx264", "nvenc_gpu": N}
        try:
            import json as _json
            with open(_os.path.join(_BASE, "video.json"), encoding="utf-8") as _f:
                _vjson = _json.load(_f)
            _force = str(_vjson.get("encoder", "")).strip().lower()
            if _force == "auto": _force = ""
        except Exception:
            _vjson = {}
    else:
        _vjson = {}
    _nvgpu = None
    try:
        _nvgpu = int(_vjson.get("nvenc_gpu")) if _vjson.get("nvenc_gpu") is not None else None
    except Exception:
        _nvgpu = None
    global _SWVENC
    _SWVENC = ["-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-profile:v", "baseline"] + _c      # the software variant of this feed, kept for the hardware-encoder fallback (restart_ffmpeg)
    if _force == "libx264": return _SWVENC
    if _enc_ok("h264_nvenc") and _force in ("", "nvenc"): return ["-c:v", "h264_nvenc"] + (["-gpu", str(_nvgpu)] if _nvgpu is not None else []) + ["-preset", "p4", "-tune", "ll", "-rc", "cbr", "-delay", "0", "-profile:v", "baseline"] + _c
    if _enc_ok("h264_qsv") and _force in ("", "qsv"):     return ["-c:v", "h264_qsv", "-preset", "veryfast", "-profile:v", "baseline"] + _c
    if _enc_ok("h264_amf") and _force in ("", "amf"):     return ["-c:v", "h264_amf", "-usage", "lowlatency", "-rc", "cbr", "-profile:v", "constrained_baseline"] + _c
    return _SWVENC
_SWVENC = None
_VENC = _pick_encoder()
print("video encoder =", _VENC[1], flush=True)
RTSP   = "rtsp://127.0.0.1:8554/" + TARGET
# RELAY PORT (Phase 1.5, 2026-07-24): DOC_OUT_URL overrides the output. An rtmp:// URL pushes OUTBOUND
# to the DOC relay (flv muxer); unset = the stock local-RTSP path, byte-identical to the pack original.
OUT_URL = os.environ.get("DOC_OUT_URL") or RTSP
# rtmp -> flv/TCP (default); srt -> mpegts/UDP (latency-bounded, drops-late instead of TCP stalling --
# the tighter-sync transport for relay mains); anything else -> the stock local-RTSP path.
if OUT_URL.lower().startswith("rtmp"):
    OUT_FLAGS = ["-f", "flv", OUT_URL]
elif OUT_URL.lower().startswith("srt"):
    OUT_FLAGS = ["-f", "mpegts", OUT_URL]
else:
    OUT_FLAGS = ["-f", "rtsp", "-rtsp_transport", "tcp", OUT_URL]
TITLE  = "DOC-" + TARGET.upper()

# SINGLETON (0.7.5): a self-heal recovery and a re-run of Step 2 can race and launch a SECOND capture
# for the same target; both publish the same RTSP path, MediaMTX kicks one publisher, and the two
# ffmpegs broken-pipe each other forever (crash-looping mains). Newest wins: kill any older capture
# of this same target (and its ffmpeg children) before we start.
try:
    import psutil as _ps
    _me = _os.getpid()
    for _pr in _ps.process_iter(["pid", "cmdline"]):
        try:
            _cl = _pr.info["cmdline"] or []
            if (_pr.info["pid"] != _me and any("stream_window_wgc" in str(a) for a in _cl)
                    and any(str(a).strip().lower() == TARGET for a in _cl)):
                for _ch in _pr.children(recursive=True):
                    try: _ch.kill()
                    except Exception: pass
                _pr.kill()
                print("killed duplicate capture pid", _pr.info["pid"], flush=True)
        except Exception:
            pass
except Exception as _se:
    print("singleton check skipped:", _se, flush=True)

# Race broadcast audio: captured from this Windows audio device and muxed onto the mainl stream ONLY.
# Override with env DOC_AUDIO_DEV. If the device is absent (VB-CABLE not installed yet), mainl stays
# video-only -- so this is always safe to run; audio just turns on once the device shows up.
AUDIO_MATCH = os.environ.get("DOC_AUDIO_MATCH", "virtual-audio-capturer")  # WASAPI-loopback dshow filter (screen-capture-recorder); Server has no native dshow audio devices

def find_audio_device(match):
    """Find the dshow audio capture device whose name contains `match` (the VB-CABLE loopback).
    Returns the exact name ffmpeg uses (or None), and logs every device it saw so we can verify."""
    try:
        r = subprocess.run([FFMPEG, "-hide_banner", "-f", "dshow", "-list_devices", "true", "-i", "dummy"],
                           capture_output=True, text=True, timeout=12)
        raw = (r.stderr or "") + (r.stdout or "")
        print("audio: RAW device list >>>", raw.replace("\n", " | ")[:1600], "<<<", flush=True)
        names = []
        for ln in raw.splitlines():
            if ln.count('"') >= 2 and "@device" not in ln:        # a device line: [dshow] "Friendly Name"
                names.append(ln.split('"')[1])
        print("audio: dshow devices seen:", names, flush=True)
        for nm in names:
            if match.lower() in nm.lower():
                return nm
        return None
    except Exception as e:
        print("audio: device probe failed", repr(e), flush=True)
        return None

# Windows title-bar + border to crop off the captured window so the feed is clean game, no chrome.
# (top, bottom, left, right) in captured pixels. Measured at the box's 150% DPI; tweak if windows change.
_CHROME_TABLE = {
    # 0.7.2: crops assume BORDERLESS satellite windows (lib\windowless.ps1 strips them in Step 2) —
    # the proven 2026-07-06 windowless-satellites fix baked in. Mains keep borders; inner seam edges = 0
    # so the two halves meet with no missing columns.
    "mainl": (43, 13, 14, 0), "mainr": (43, 13, 0, 21),
    # seats pillarbox ~26px left / ~19px right / ~8px bottom -> crop to pure content (433x308)
    "seat1": (2, 2, 2, 2), "seat2": (2, 2, 2, 2), "seat3": (2, 2, 2, 2), "seat4": (2, 2, 2, 2),
    "seat5": (2, 2, 2, 2), "seat6": (2, 2, 2, 2),
    "seat7": (2, 2, 2, 2), "seat8": (2, 2, 2, 2),   # 8-seat cabinet (same crop as seats 1-6)
}
CHROME = _CHROME_TABLE.get(TARGET, (0, 0, 0, 0))
# Borderless rigs (the windowless pass strips ALL chrome): DOC_CHROME_CROP=0 disables the crop so no
# game pixels get sliced -- the default mains crop assumes BORDERED windows and cut ~43px of live game
# on a borderless rig (rig finding, 2026-07-24).
if _os.environ.get("DOC_CHROME_CROP") == "0":
    CHROME = (0, 0, 0, 0)
    _CHROME_TABLE = {k: (0, 0, 0, 0) for k in _CHROME_TABLE}

# --- ffmpeg dies with this process (doc-ops #117, PR #32 v2) ---------------------------------------
# A bare Popen child outlives its python: Stop-Process -Force on the pusher (broadcast-wgc.ps1 kill-first,
# -Stop, the DOC Host app's Stop) left the ffmpeg running, still publishing the old path, and the restarted
# pusher's ffmpeg then fought it for the same relay path. Every ffmpeg this pusher starts goes into a Windows
# Job Object with KILL_ON_JOB_CLOSE. The job handle is held in _JOB for the life of the process and never
# closed, so when python exits for ANY reason (clean exit, crash, Stop-Process -Force) Windows closes the
# handle and kills the job's processes.
def _make_kill_on_close_job():
    try:
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.CreateJobObjectW.restype = wintypes.HANDLE
        k32.CreateJobObjectW.argtypes = (ctypes.c_void_p, wintypes.LPCWSTR)
        k32.SetInformationJobObject.restype = wintypes.BOOL
        k32.SetInformationJobObject.argtypes = (wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD)
        k32.OpenProcess.restype = wintypes.HANDLE
        k32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        k32.AssignProcessToJobObject.restype = wintypes.BOOL
        k32.AssignProcessToJobObject.argtypes = (wintypes.HANDLE, wintypes.HANDLE)
        k32.CloseHandle.argtypes = (wintypes.HANDLE,)

        class _IO(ctypes.Structure):
            _fields_ = [(n, ctypes.c_ulonglong) for n in ("ReadOperationCount", "WriteOperationCount",
                        "OtherOperationCount", "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

        class _BASIC(ctypes.Structure):
            _fields_ = [("PerProcessUserTimeLimit", ctypes.c_int64), ("PerJobUserTimeLimit", ctypes.c_int64),
                        ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                        ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                        ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD),
                        ("SchedulingClass", wintypes.DWORD)]

        class _EXT(ctypes.Structure):
            _fields_ = [("BasicLimitInformation", _BASIC), ("IoInfo", _IO), ("ProcessMemoryLimit", ctypes.c_size_t),
                        ("JobMemoryLimit", ctypes.c_size_t), ("PeakProcessMemoryUsed", ctypes.c_size_t),
                        ("PeakJobMemoryUsed", ctypes.c_size_t)]

        job = k32.CreateJobObjectW(None, None)
        if not job:
            raise OSError(ctypes.get_last_error(), "CreateJobObject")
        info = _EXT()
        info.BasicLimitInformation.LimitFlags = 0x2000          # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not k32.SetInformationJobObject(job, 9, ctypes.byref(info), ctypes.sizeof(info)):  # 9 = ExtendedLimitInformation
            raise OSError(ctypes.get_last_error(), "SetInformationJobObject")
        return k32, job
    except Exception as e:
        print("job object unavailable (ffmpeg will not die with this process):", repr(e), flush=True)
        return None, None

_K32, _JOB = _make_kill_on_close_job()

def _job_adopt(proc):
    """Put a child we just started into _JOB (PROCESS_SET_QUOTA | PROCESS_TERMINATE). Never raises."""
    if not _JOB:
        return
    try:
        h = _K32.OpenProcess(0x0100 | 0x0001, False, proc.pid)
        if not h:
            raise OSError(ctypes.get_last_error(), "OpenProcess")
        try:
            if not _K32.AssignProcessToJobObject(_JOB, h):
                raise OSError(ctypes.get_last_error(), "AssignProcessToJobObject")
        finally:
            _K32.CloseHandle(h)
    except Exception as e:
        print("job assign failed for pid %s: %r" % (proc.pid, e), flush=True)

user32 = ctypes.windll.user32
EnumWindowsProc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

def flycast_pids(path_frag):
    frag = path_frag.lower()
    return [p.info["pid"] for p in psutil.process_iter(["name", "exe", "pid"])
            if (p.info["name"] or "").lower() == "flycast.exe" and frag in (p.info["exe"] or "").lower()]

def windows_for_pids(pids, min_dim=80):
    out = []  # (x, hwnd, pid, w, h)
    def cb(h, _):
        if user32.IsWindowVisible(h):
            wp = wintypes.DWORD(); user32.GetWindowThreadProcessId(h, ctypes.byref(wp))
            if wp.value in pids:
                r = wintypes.RECT(); user32.GetWindowRect(h, ctypes.byref(r))
                w, ht = r.right - r.left, r.bottom - r.top
                if w >= min_dim and ht >= min_dim:
                    out.append((r.left, h, wp.value, w, ht))
        return True
    user32.EnumWindows(EnumWindowsProc(cb), 0)
    out.sort()
    return out

def resolve_hwnd(target):
    if target in ("mainl", "mainr"):
        # the two \main\ processes launch staggered; WAIT for BOTH windows before picking, else
        # both captures grab the only one that's up yet (-> two left screens).
        pids, cands = [], []
        for attempt in range(40):                       # up to ~20s
            pids = flycast_pids("\\main\\")
            cands = windows_for_pids(pids)
            if len(pids) >= 2 and len(cands) >= 2:
                break
            time.sleep(0.5)
        print("main pids", pids, "candidate windows (x,hwnd,pid,w,h):", cands, "attempts", attempt + 1, flush=True)
        if not cands:
            return 0
        return cands[0][1] if target == "mainl" else cands[-1][1]   # leftmost vs rightmost by x
    else:  # seatN -> satN folder
        satdir = target.replace("seat", "sat")
        pids, wins = [], []
        for attempt in range(40):                       # retry up to ~20s (the seat window can lag startup)
            pids = flycast_pids("\\" + satdir + "\\")
            wins = windows_for_pids([pids[0]]) if pids else []
            if wins:
                break
            time.sleep(0.5)
        if not wins and pids:                           # debug: what does the pid actually own from in here?
            dbg = []
            def _cb(h, _):
                wp = wintypes.DWORD(); user32.GetWindowThreadProcessId(h, ctypes.byref(wp))
                if wp.value == pids[0]:
                    r = wintypes.RECT(); user32.GetWindowRect(h, ctypes.byref(r))
                    b = ctypes.create_unicode_buffer(120); user32.GetWindowTextW(h, b, 120)
                    dbg.append((h, user32.IsWindowVisible(h), r.right - r.left, r.bottom - r.top, b.value))
                return True
            user32.EnumWindows(EnumWindowsProc(_cb), 0)
            print(target, "pids", pids, "NO visible match; pid owns:", dbg, flush=True)
        else:
            print(target, "pids", pids, "wins", wins, "attempt", attempt + 1, flush=True)
        return wins[0][1] if wins else 0

def _acquire():
    hwnd = resolve_hwnd(TARGET)
    print("hwnd", hwnd, flush=True)
    if not hwnd:
        return None
    user32.SetWindowTextW(hwnd, TITLE)
    # Flycast rewrites its own window title while booting; if it overwrote ours between the retitle
    # and WGC's find-by-name, attach fails ("Failed to find window") -- verify + re-stamp.
    _b = ctypes.create_unicode_buffer(64)
    user32.GetWindowTextW(hwnd, _b, 64)
    if _b.value != TITLE:
        user32.SetWindowTextW(hwnd, TITLE); time.sleep(0.2)
    return hwnd
# Settle-before-lock: the boot resize means frame 0 is often a transient size. Locking the crop to it
# makes later (settled) frames get padded with black -> a black bar on one side (the seat4 bug). So we
# wait for the window size to hold steady before locking, which makes every seat boot up clean.
SETTLE_FRAMES = 30      # size must repeat this many frames in a row to count as "settled" (~0.5s @ 60fps)
SETTLE_MAX    = 240     # but never wait longer than this before locking anyway (~4s safety net)
S = {"ff": None, "n": 0, "tw": 0, "th": 0, "shapes": set(), "seen": 0, "settle_shape": None, "settle_count": 0,
     "ffcmd": None, "ffrestarts": 0, "last_spawn": 0.0}

# --- ffmpeg self-heal (added 2026-06-22) -------------------------------------------------------
# BEFORE: if the encoder exited, every frame's pipe write raised OSError(22) 'Invalid argument' and was
# logged as "frame err" forever -- the feed stayed dead until a human ran Restart Capture Service (the
# 06-22 ~80-min outage). NOW we detect the dead encoder and respawn it (throttled), so a dropped ffmpeg
# self-recovers in ~1 frame instead of wedging the feed.
FF_RESTART_COOLDOWN = 3.0   # min seconds between respawns, so a hard-failing ffmpeg can't spin-launch

# HARDWARE ENCODER THAT WILL NOT OPEN (doc-ops #117, PR #32 review). A GeForce refuses an 11th concurrent NVENC
# session (and any driver/init error does the same), so a feed whose ffmpeg dies within seconds of every start
# used to respawn the SAME failing command every 3 s forever and never publish. After FB.limit quick exits whose
# own stderr names the encoder, that feed is switched to libx264 (once) and keeps running.
try:
    if _BASE not in sys.path:
        sys.path.insert(0, _BASE)         # the pack's embedded Python runs isolated: the script folder is not on sys.path
    from mains_combine import EncoderFallback, swap_video_encoder
    FB = EncoderFallback()
except Exception as _fe:
    FB = None
    print("encoder fallback unavailable:", repr(_fe), flush=True)
try:
    from mains_combine import fit_frame   # host resizes are scaled to the locked size, never corner-cropped
except Exception as _fe:
    fit_frame = None
    print("fit_frame unavailable (resized windows fall back to the corner coercion):", repr(_fe), flush=True)
FF_LOG = _os.path.join(_SD, r"ffmpeg_") + TARGET + ".log"

def _ff_log_tail(since):
    try:
        with open(FF_LOG, "rb") as f:
            f.seek(max(0, since))
            return f.read()[-4000:].decode("utf-8", "replace")
    except Exception:
        return ""

def start_ffmpeg():
    try: S["logpos"] = _os.path.getsize(FF_LOG)
    except Exception: S["logpos"] = 0
    S["ff"] = subprocess.Popen(S["ffcmd"], stdin=subprocess.PIPE, stderr=open(FF_LOG, "a"))
    _job_adopt(S["ff"])
    S["last_spawn"] = time.monotonic()

def restart_ffmpeg(why):
    """Respawn ffmpeg after it died, throttled by FF_RESTART_COOLDOWN. Returns True if it actually respawned."""
    if time.monotonic() - S["last_spawn"] < FF_RESTART_COOLDOWN:
        return False
    old = S["ff"]
    if old is not None:
        try: old.stdin.close()
        except Exception: pass
        try: old.kill()
        except Exception: pass
    if FB is not None and old is not None:
        try:
            if FB.note_exit(time.monotonic() - S["last_spawn"], _VENC[1] if S.get("venc") is None else S["venc"][1],
                            _ff_log_tail(S.get("logpos", 0))) and _SWVENC:
                S["ffcmd"] = swap_video_encoder(S["ffcmd"], S.get("venc") or _VENC, _SWVENC)
                S["venc"] = _SWVENC
                print("ENCODER FALLBACK: %s would not stay up (session cap or init error) -> libx264 for this feed"
                      % _VENC[1], flush=True)
        except Exception as e:
            print("encoder fallback check failed", repr(e), flush=True)
    S["ffrestarts"] += 1
    start_ffmpeg()
    print("ffmpeg RESTARTED (#%d, %s) at frame %d -> pid %d" % (S["ffrestarts"], why, S["n"], S["ff"].pid), flush=True)
    return True

def on_frame_arrived(frame, ctrl):
    try:
        buf = frame.frame_buffer
        sh = (buf.shape[0], buf.shape[1])
        if sh not in S["shapes"]:
            S["shapes"].add(sh); print("NEW shape", sh, "at frame#", S["n"], flush=True)
        if S["ff"] is None:
            # lock on the FIRST frame (proven behavior). NOTE: the earlier "settle" gate broke video --
            # the window oscillates between two sizes during boot, so it never settled and never locked.
            # seat4's cosmetic black bar will be handled a different way (re-lock after a resize), not here.
            th, tw = sh[0], sh[1]
            ct, cb, cl, cr = CHROME
            cw = tw - cl - cr; cw -= cw % 2          # cropped width  (drop side borders)
            ch = th - ct - cb; ch -= ch % 2          # cropped height (drop title bar + bottom border)
            if cw <= 0 or ch <= 0:                   # a frame smaller than the chrome: wait for a real one
                return                               # (locking it gave a negative -video_size and a respawn loop)
            S["th"], S["tw"] = th, tw
            S["ch"], S["cw"] = ch, cw
            print("locked target", tw, "x", th, "-> crop", cw, "x", ch, "at", cl, ct, flush=True)
            # With fit_frame the crop happens here, per frame, and ffmpeg gets the cropped picture at a fixed
            # size; without it (import failed) ffmpeg crops the raw capture as before.
            _vin = ("%dx%d" % (cw, ch)) if fit_frame else ("%dx%d" % (tw, th))
            _vf = "format=yuv420p" if fit_frame else ("crop=%d:%d:%d:%d,format=yuv420p" % (cw, ch, cl, ct))
            # mainl carries the race broadcast audio (the others stay video-only). Probe for the device so a
            # missing/renamed VB-CABLE never breaks the video -- it just falls back to the exact video-only cmd.
            # PURE VIDEO for every feed (incl. mainl). Audio is a SEPARATE stream (stream_audio.py -> /raceaudio)
            # so it can never disturb the video timing -- muxing it into mainl threw off the joined mains (58 vs 46 fps).
            S["ffcmd"] = [
                FFMPEG, "-hide_banner", "-loglevel", "warning",
                # Stamp each frame when it ARRIVES (doc-ops #117, as director_stream.py since 2026-08-06). Without
                # this ffmpeg stamps frame n at n/60 s, but the pushers deliver about 43 fps, so the stream clock ran
                # at about 0.70x real time and the two main halves' jitter buffers wandered apart (32-347 ms).
                "-f", "rawvideo", "-pixel_format", "bgra", "-video_size", _vin, "-framerate", "60",
                "-use_wallclock_as_timestamps", "1", "-i", "pipe:0",
                # LORES appends a 240p downscale to the crop chain (fewer pixels to encode + send); the
                # full-res path (no scale) is unchanged when DOC_SEAT_LORES is unset.
                "-vf", _vf + (",scale=-2:240" if LORES else ""),
            ] + _VENC + [
                # passthrough, NOT cfr: every captured frame goes out once, the moment it arrives, with its
                # wall-clock stamp. v1 used "-fps_mode cfr -r 60" (as director_stream.py): live on a host cab that
                # was worse, because cfr can only emit gap-filling duplicates when the NEXT frame arrives (late
                # bursts, up to 0.5 s) and it pads still screens to the full CBR rate (about 7x the upload on 10
                # feeds), which back-pressured the capture pipes. WebRTC plays variable frame rate natively.
                "-fps_mode", "passthrough",
                # A keyframe every 2 s of wall time, whatever the frame rate: a still seat sending 5 fps
                # otherwise waits 120 frames (about 24 s) between keyframes, so a new viewer or a lost packet
                # waits that long for a picture. NVENC turns a forced frame into an IDR only with -forced-idr.
                "-force_key_frames", "expr:gte(t,n_forced*2)",
            ] + (["-forced-idr", "1"] if _VENC[1] == "h264_nvenc" else []) + OUT_FLAGS
            start_ffmpeg()
        elif S["ff"].poll() is not None:
            # encoder died (the 06-22 OSError(22) broken-pipe storm) -> respawn instead of writing to a dead pipe
            restart_ffmpeg("ffmpeg exited rc=%s" % S["ff"].returncode)
        th, tw = S["th"], S["tw"]
        if fit_frame:
            pic = fit_frame(buf, CHROME, S["ch"], S["cw"])
            if pic is None:
                return
            data = np.ascontiguousarray(pic)
        elif buf.shape[0] == th and buf.shape[1] == tw:
            data = np.ascontiguousarray(buf)
        else:
            data = np.zeros((th, tw, 4), np.uint8)
            h = min(th, buf.shape[0]); w = min(tw, buf.shape[1])
            data[:h, :w] = buf[:h, :w]
        try:
            S["ff"].stdin.write(data.tobytes())
        except (OSError, ValueError) as e:
            # dead/closing encoder pipe -> respawn (throttled), drop this frame; no more OSError(22) spam
            restart_ffmpeg("write %r" % e)
        S["n"] += 1
        if S["n"] % 300 == 0:
            print("frames", S["n"], flush=True)
    except Exception as e:
        print("frame err", repr(e), flush=True)

def on_closed():
    print("closed", flush=True)

def _run_capture(c):
    c.start(); print("cap.start returned (capture stopped)", flush=True)

def _mk(border):
    c = WindowsCapture(cursor_capture=False, draw_border=border, window_name=TITLE)
    c.event(on_frame_arrived); c.event(on_closed)
    return c

# --- TARGET "mains": both halves, ONE picture, ONE connection (doc-ops #117, PR #32 v3) -------------------------
# Root cause of the left/right desync: each half was its own RTMP/TCP (or SRT) push over the host's congested
# uplink, so each stalled on its own packet loss, and over SRT the relay fixes each connection's delay at its
# handshake, which left a constant ~160 ms between the halves. Two connections cannot be made to agree. This
# target captures BOTH main windows in this process, writes each into one side-by-side composite (mains_combine),
# encodes that once (wall-clock stamps, passthrough, 2 s forced keyframes: as v2) and pushes it over a single
# connection to the bare cab_<id> path. The halves are then the same video frame: skew zero by construction.
# It also frees one NVENC session (a GeForce refuses the 11th), and halves the keyframe/header overhead.
def _run_mains():
    import threading
    # The pack's embedded Python runs isolated (python312._pth): the script's own folder is NOT on sys.path,
    # so the sibling module has to be found by path. (Found by running the real pusher against the pack runtime.)
    if _BASE not in sys.path:
        sys.path.insert(0, _BASE)
    from mains_combine import MainsMixer, SideFeed, pick_main_pair, attach_backoff
    lock_chrome = {"mainl": _CHROME_TABLE.get("mainl", (0, 0, 0, 0)), "mainr": _CHROME_TABLE.get("mainr", (0, 0, 0, 0))}

    def open_sink(W, H):
        print("mains composite %dx%d" % (W, H), flush=True)
        S["tw"], S["th"] = W, H
        S["ffcmd"] = [
            FFMPEG, "-hide_banner", "-loglevel", "warning",
            "-f", "rawvideo", "-pixel_format", "bgra", "-video_size", "%dx%d" % (W, H), "-framerate", "60",
            "-use_wallclock_as_timestamps", "1", "-i", "pipe:0",
            "-vf", "format=yuv420p",
        ] + _VENC + [
            "-fps_mode", "passthrough",
            "-force_key_frames", "expr:gte(t,n_forced*2)",
        ] + (["-forced-idr", "1"] if _VENC[1] == "h264_nvenc" else []) + OUT_FLAGS
        start_ffmpeg()

        def write(data):
            if S["ff"].poll() is not None:
                restart_ffmpeg("ffmpeg exited rc=%s" % S["ff"].returncode)
            try:
                S["ff"].stdin.write(data)
            except (OSError, ValueError) as e:
                restart_ffmpeg("write %r" % e)
        return write

    mixer = MainsMixer(open_sink)
    feeds = {"mainl": SideFeed(mixer, "L", lock_chrome["mainl"]), "mainr": SideFeed(mixer, "R", lock_chrome["mainr"])}
    border = {"v": False}                       # the Win10 border-toggle fallback (0.6.3), shared by both halves

    def start_side(target, hwnd):
        title = "DOC-" + target.upper()
        user32.SetWindowTextW(hwnd, title)
        b = ctypes.create_unicode_buffer(64)
        user32.GetWindowTextW(hwnd, b, 64)
        if b.value != title:
            user32.SetWindowTextW(hwnd, title); time.sleep(0.2)
        feed = feeds[target]

        def on_frame_arrived(frame, ctrl):
            try:
                feed.on_frame(frame.frame_buffer)
            except Exception as e:
                print(target, "frame err", repr(e), flush=True)

        def on_closed():
            print(target, "closed", flush=True)

        def mk(bd):
            c = WindowsCapture(cursor_capture=False, draw_border=bd, window_name=title)
            c.event(on_frame_arrived); c.event(on_closed)
            return c
        try:
            return mk(border["v"]).start_free_threaded()
        except Exception as e:
            if "capture border" in repr(e).lower() and border["v"] is False:
                print(target, "cap.start: border-toggle unsupported -> retry with draw_border=None", flush=True)
                border["v"] = None
                return mk(None).start_free_threaded()
            raise

    def main_pair():
        """(left_hwnd, right_hwnd) when TWO different main processes each own a window, else None. Never hands the
        same window to both halves (one main up used to mean the left screen twice, looking healthy)."""
        return pick_main_pair(windows_for_pids(flycast_pids("\\main\\")))

    ctl = {"mainl": None, "mainr": None}
    fails = {"mainl": 0, "mainr": 0}
    pair_fails = 0
    mt = threading.Thread(target=mixer.run, daemon=True)
    mt.start()
    last_log = time.monotonic()
    # This loop NEVER exits the pusher: a missing window or a failed attach is retried with a capped backoff
    # (it used to quit after 12 failures of either half, killing the healthy half too, with nothing to
    # restart it). Until BOTH distinct windows exist nothing new is attached; the mixer publishes nothing before
    # its first picture and holds the last picture after.
    while True:
        try:
            need = [t for t in ("mainl", "mainr") if ctl[t] is None or ctl[t].is_finished()]
            for t in need:
                if ctl[t] is not None:
                    print(t, "capture ended -> re-attach", flush=True)
                    ctl[t] = None
            if need:
                pair = main_pair()
                if pair is None:
                    pair_fails += 1
                    d = attach_backoff(pair_fails - 1)
                    print("waiting for BOTH main windows (attempt %d, next look in %.0fs)" % (pair_fails, d), flush=True)
                    time.sleep(d)
                    continue
                pair_fails = 0
                hw = {"mainl": pair[0], "mainr": pair[1]}
                for t in need:
                    try:
                        ctl[t] = start_side(t, hw[t])
                    except Exception as e:
                        print(t, "cap.start error", repr(e), flush=True)
                        ctl[t] = None
                    if ctl[t] is None:
                        fails[t] += 1
                        print("could not attach", t, "(attempt %d)" % fails[t], flush=True)
                    else:
                        fails[t] = 0
                        print("capturing", t, flush=True)
                if any(ctl[t] is None for t in need):
                    time.sleep(attach_backoff(max(fails[t] for t in need) - 1))
            if not mt.is_alive():                    # the mixer guards itself; this is the belt to that brace
                print("mixer thread was dead -> restarting it", flush=True)
                mt = threading.Thread(target=mixer.run, daemon=True)
                mt.start()
            if time.monotonic() - last_log >= 10:
                last_log = time.monotonic()
                print("mixer", dict(mixer.stats), flush=True)
        except Exception as e:
            print("mains supervisor error", repr(e), "-- continuing", flush=True)
            time.sleep(2)
        time.sleep(1)

if TARGET == "mains":
    _run_mains()
    sys.exit(0)

# Attach with RETRIES (0.7.5): after a hands-free recovery (or a fast Step-2 re-run) a capture could
# lose the attach race -- flycast rewrites its own window title during boot, so find-by-name failed
# and the capture DIED with no retry -> a black main/seat in the lobby until a human relaunched.
# Re-resolve + re-title + re-attach instead. The Win10 border-toggle fallback (draw_border=None,
# the 0.6.3 fix) is preserved inside each attempt.
_started = False
_border = False
for _attempt in range(12):
    if _acquire() is None:
        print("no window yet (attempt %d)" % (_attempt + 1), flush=True)
        time.sleep(5)
        continue
    print("capturing", TITLE, "(attempt %d)" % (_attempt + 1), flush=True)
    try:
        _run_capture(_mk(_border))
        _started = True
        break
    except Exception as e:
        if "capture border" in repr(e).lower() and _border is False:
            # Older Windows builds (Win10 / pre-Win11) can't toggle the WGC capture border; retry the
            # SAME attempt borderless and remember it ("audio but no video" fix, 0.6.3).
            print("cap.start: border-toggle unsupported on this Windows build -> retry with draw_border=None", flush=True)
            _border = None
            try:
                _run_capture(_mk(_border))
                _started = True
                break
            except Exception as e2:
                print("cap.start error (no-border retry)", repr(e2), "attempt", _attempt + 1, flush=True)
        else:
            print("cap.start error", repr(e), "attempt", _attempt + 1, flush=True)
        time.sleep(5)
if not _started:
    print("FAILED to attach after retries -- giving up", flush=True)
    sys.exit(1)
