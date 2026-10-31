#!/usr/bin/env python3
"""DOC relay kit: AUDIO supervisor -- race audio + per-seat audio to the relay, all over SRT.

Ported from the pack's proven stream_main_audio.py / stream_seat_audio.py (WASAPI process-loopback
via seat_audio_capture.exe -- headless-safe, one clean signal per source):
  raceaudio    = the MASTER main's process audio ONLY (capturing the default device grabs BOTH mains
                 phase-shifted -> comb-filter stutter; the master-only capture is the box lesson)
  seatN_audio  = each satellite's own seat-local audio (betting / menu / UI sounds)

Audio is NEVER muxed into the video feeds (that threw the joined mains out of sync on the boxes) and
rides SRT/MPEG-TS because RTMP/FLV cannot carry Opus and WebRTC cannot play AAC.

  py -3 audio_relay_push.py <seat_count>
Env: DOC_CAB_ID, DOC_HOST_TOKEN (required), DOC_RELAY_HOST (default 5.78.188.88).
MUST run in the interactive session (process-loopback is session-bound).
"""
import ctypes, os, subprocess, sys, threading, time
from ctypes import wintypes
import psutil

_BASE = os.path.dirname(os.path.abspath(__file__))
_SD = os.environ.get("DOC_AUDIO_LOGDIR") or os.path.join(_BASE, "stream")
os.makedirs(_SD, exist_ok=True)
FFMPEG = os.path.join(_BASE, "runtime", "ffmpeg", "bin", "ffmpeg.exe")
CAP = os.path.join(_BASE, "seat_audio_capture.exe")

SEATS = int(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].isdigit() else 4
RELAY = os.environ.get("DOC_RELAY_HOST", "5.78.188.88")
CAB = os.environ.get("DOC_CAB_ID", "")
TOK = os.environ.get("DOC_HOST_TOKEN", "")
if __name__ == "__main__" and (not CAB or not TOK):
    print("DOC_CAB_ID / DOC_HOST_TOKEN required"); sys.exit(1)

# Children die with this process (doc-ops #117, PR #32 v2): a bare Popen child outlives its python, so
# Stop-Process -Force on this supervisor (broadcast-wgc.ps1 kill-first, -Stop, the DOC Host app's Stop) left
# every seat_audio_capture.exe + ffmpeg pair running and still publishing. Each child goes into a Windows Job
# Object with KILL_ON_JOB_CLOSE; the handle is held in _JOB for the life of the process and never closed, so
# Windows kills the children whenever this process ends, however it ends.
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
        print("job object unavailable (children will not die with this process):", repr(e), flush=True)
        return None, None

_K32, _JOB = _make_kill_on_close_job()

def _job_adopt(proc, log):
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
        log.write("job assign failed for pid %s: %r\n" % (proc.pid, e))

def srt_url(name):
    return ("srt://%s:8890?streamid=publish:cab_%s/%s:cab:%s&latency=200000" % (RELAY, CAB, name, TOK))

# ONE SHARED PROCESS SCAN (doc-ops #117, PR #32 review). Every pipeline used to call its finder() once a second
# and every finder walked EVERY process reading its command line (4.4 s wall, 0.6 s CPU per scan on a 685-process
# PC, times 9 pipelines). Now one scanner serves all of them: it lists processes by NAME first and reads the
# command line / exe path only of flycast.exe, at most once every SCAN_TTL_S, and every pipeline shares the
# result. It is also scoped to THIS install: a game counts only when its exe lives under this pack's own
# main folder or satN folder (Rebalance/flycast.exe under it), so two packs on one PC cannot cross-attach.
SCAN_TTL_S = 2.5

class FlycastScan:
    def __init__(self, base, ttl=SCAN_TTL_S, clock=time.monotonic, lister=None):
        self._base = os.path.normcase(os.path.abspath(base)).rstrip("\\/") + os.sep
        self._ttl = ttl
        self._clock = clock
        self._lister = lister or self._list_flycast
        self._lock = threading.Lock()
        self._snap = {"master": None, "seats": {}}
        self._at = None
        self.scans = 0

    @staticmethod
    def _list_flycast():
        """[(pid, exe, cmdline)] for every flycast.exe. The name is read for all processes (cheap); the exe path
        and command line are read for flycast.exe ONLY."""
        out = []
        for p in psutil.process_iter(["name", "pid"]):
            try:
                if (p.info["name"] or "").lower() != "flycast.exe":
                    continue
                try:
                    cl = p.cmdline()
                except Exception:
                    cl = []
                try:
                    exe = p.exe()
                except Exception:
                    exe = cl[0] if cl else ""
                out.append((p.info["pid"], exe or "", " ".join(cl)))
            except Exception:
                continue
        return out

    def _classify(self, procs):
        master, seats = None, {}
        for pid, exe, cl in procs:
            path = os.path.normcase(exe or "")
            if not path.startswith(self._base):
                continue                                  # another install's game (or a path we cannot read)
            rel = path[len(self._base):]
            head = rel.split(os.sep, 1)[0]
            if head == "main":
                if "BoardId=1" not in cl and master is None:
                    master = pid
            elif head.startswith("sat") and head[3:].isdigit():
                seats.setdefault(int(head[3:]), pid)
        return {"master": master, "seats": seats}

    def snapshot(self):
        with self._lock:                                   # callers arriving mid-scan wait for it and share it
            now = self._clock()
            if self._at is None or now - self._at >= self._ttl:
                try:
                    self._snap = self._classify(self._lister())
                except Exception:
                    pass                                   # keep the last good answer
                self._at = now
                self.scans += 1
            return self._snap

_SCAN = FlycastScan(_BASE)

def find_master():
    return _SCAN.snapshot()["master"]

def find_seat(n):
    return _SCAN.snapshot()["seats"].get(n)

# SURVIVING A GAME RESTART (doc-ops #117, PR #32). DOC Host's "Restart game" kills flycast, relaunches it, then
# restarts the feeds. This supervisor used to start while the OLD flycast processes were still listed (or before
# the new ones existed), attach seat_audio_capture to a pid that was about to die, and then sit there: a capture
# attached to a dead pid logs "frame size not set" and never writes a byte, never exits, and the pipeline waited
# on it forever (live: 9 video paths, 0 audio). Now:
#   * start-up waits until the whole game (master + every seat) is up with an unchanged pid set for a few seconds;
#   * a capture is bound to the target's (pid, create_time); the target vanishing, or being replaced by a new
#     process, restarts the capture on the new one;
#   * a capture that writes no byte within STARTUP_SILENCE_S of starting is restarted (it is attached to nothing);
#   * a capture or ffmpeg child that exits is restarted; restarts back off 2, 4, 8 .. 30 s and the count resets
#     after a run of HEALTHY_RUN_S;
#   * nothing a pipeline thread does can end the thread (every error is logged and retried; the backoff exponent
#     is capped, because 2 ** (fails - 1) overflows a float at 1025 consecutive failures, about 26 h of absence).
WAIT_SOURCE_S = 60          # how long one attempt waits for its game process to appear
STARTUP_SILENCE_S = 20.0    # no capture output this long after start = attached to nothing
HEALTHY_RUN_S = 30.0        # a run this long resets the backoff
BACKOFF_MIN_S, BACKOFF_MAX_S = 2.0, 30.0
POLL_S = 1.0

def cap_cmd(pid):
    return [CAP, str(pid)]

def ff_cmd(url, bitrate):
    return [FFMPEG, "-hide_banner", "-loglevel", "warning",
            "-f", "s16le", "-ar", "48000", "-ac", "2", "-thread_queue_size", "1024", "-i", "pipe:0",
            "-c:a", "libopus", "-b:a", bitrate, "-ac", "2", "-application", "audio",
            "-f", "mpegts", url]

def proc_identity(pid):
    """(pid, create_time) of a live process, else None. A recycled pid has a different create_time."""
    try:
        return (pid, psutil.Process(pid).create_time())
    except Exception:
        return None

def _still_there(ident):
    if ident is None:
        return False
    try:
        pr = psutil.Process(ident[0])
        return abs(pr.create_time() - ident[1]) < 0.01 and pr.status() != psutil.STATUS_ZOMBIE
    except Exception:
        return False

def _kill(proc):
    try:
        if proc.poll() is None: proc.kill()
    except Exception: pass
    try: proc.wait(3)
    except Exception: pass

def _run_once(name, finder, bitrate, log):
    """One capture attempt. Returns seconds it ran after producing audio (0 = it never produced any)."""
    pid = None
    t_end = time.monotonic() + WAIT_SOURCE_S
    while time.monotonic() < t_end:
        pid = finder()
        if pid: break
        time.sleep(POLL_S)
    if not pid:
        log.write("no source process after %ds; retrying\n" % WAIT_SOURCE_S)
        return 0.0
    ident = proc_identity(pid)
    if ident is None:
        log.write("pid %d vanished before capture started; retrying\n" % pid)
        return 0.0
    log.write("capturing pid=%d -> %s\n" % (pid, name))
    cap = ff = None
    try:
        cap = subprocess.Popen(cap_cmd(pid), stdout=subprocess.PIPE, stderr=log)
        _job_adopt(cap, log)
        ff = subprocess.Popen(ff_cmd(srt_url(name), bitrate), stdin=subprocess.PIPE, stderr=log)
        _job_adopt(ff, log)
        # The audio goes capture -> this pump -> ffmpeg, so we can SEE whether any arrives (the capture's own
        # io counters also count its log writes, which hides a capture that is attached to nothing).
        moved = {"n": 0}
        def pump(src=cap.stdout, dst=ff.stdin):
            try:
                while True:
                    b = os.read(src.fileno(), 65536)
                    if not b: break
                    moved["n"] += len(b)
                    dst.write(b); dst.flush()
            except Exception:
                pass
            finally:
                try: dst.close()
                except Exception: pass
        threading.Thread(target=pump, daemon=True).start()
        t0 = time.monotonic()
        got_audio_at = None
        while True:
            time.sleep(POLL_S)
            if ff.poll() is not None:
                log.write("ffmpeg exited rc=%s; restarting\n" % ff.returncode); break
            if cap.poll() is not None:
                log.write("capture exited rc=%s; restarting\n" % cap.returncode); break
            if not _still_there(ident):
                log.write("source pid %d is gone; restarting on the new one\n" % pid); break
            cur = finder()
            if cur and cur != pid:
                log.write("source pid changed %d -> %d; restarting\n" % (pid, cur)); break
            if got_audio_at is None:
                if moved["n"]:
                    got_audio_at = time.monotonic()
                elif time.monotonic() - t0 > STARTUP_SILENCE_S:
                    log.write("capture wrote nothing in %.0fs (attached to nothing); restarting\n" % STARTUP_SILENCE_S); break
        return (time.monotonic() - got_audio_at) if got_audio_at else 0.0
    finally:
        for proc in (ff, cap):
            if proc is not None: _kill(proc)

BACKOFF_MAX_EXP = 6          # 2 ** 6 already exceeds BACKOFF_MAX_S; an uncapped exponent overflows a float at 1025

def backoff_delay(fails):
    """Seconds to wait after `fails` consecutive failed runs: 2, 4, 8 .. capped at BACKOFF_MAX_S, for any count."""
    return min(BACKOFF_MAX_S, BACKOFF_MIN_S * (2 ** min(max(0, fails - 1), BACKOFF_MAX_EXP)))

def pipeline(name, finder, bitrate):
    """Run one feed for the life of the process. NOTHING in an iteration can end this thread: every exception
    is logged and the loop carries on (an unlogged dead daemon thread means a feed that never has audio again)."""
    fails = 0
    log = None
    while True:
        delay = BACKOFF_MAX_S
        try:
            if log is None:
                log = open(os.path.join(_SD, "stream_%s.log" % name), "a", buffering=1)
            try:
                ran = _run_once(name, finder, bitrate, log)
            except Exception as e:
                ran = 0.0
                log.write("pipeline error %r; retrying\n" % (e,))
            fails = 0 if ran >= HEALTHY_RUN_S else fails + 1
            delay = backoff_delay(fails)
            log.write("restart in %.0fs (attempt %d)\n" % (delay, fails))
        except Exception as e:
            fails += 1
            try:
                if log is not None: log.write("pipeline loop error %r; continuing\n" % (e,))
            except Exception:
                pass
        time.sleep(delay)

def wait_for_game(seats, timeout=120.0, stable_s=4.0, sleep=time.sleep, clock=time.monotonic):
    """Block until the master and every seat have a game process and the set of pids has not changed for
    stable_s (so a game that is still being killed or still booting is not mistaken for the new one).
    Gives up after timeout and carries on (the pipelines keep retrying on their own)."""
    t_end = clock() + timeout
    last, since = None, clock()
    while clock() < t_end:
        cur = (find_master(),) + tuple(find_seat(i) for i in range(1, seats + 1))
        if all(cur):
            if cur != last:
                last, since = cur, clock()
            elif clock() - since >= stable_s:
                return True
        else:
            last, since = None, clock()
        sleep(0.5)
    return False

def main():
    ok = wait_for_game(SEATS)
    print("game windows %s" % ("up and stable" if ok else "NOT all up after 120s; pipelines will keep retrying"), flush=True)
    threading.Thread(target=pipeline, args=("raceaudio", find_master, "96k"), daemon=True).start()
    for i in range(1, SEATS + 1):
        threading.Thread(target=pipeline, args=("seat%d_audio" % i, (lambda n=i: find_seat(n)), "64k"), daemon=True).start()
    print("audio supervisor: raceaudio + %d seat feeds -> relay (SRT/Opus)" % SEATS, flush=True)
    while True: time.sleep(3600)

if __name__ == "__main__":
    main()
