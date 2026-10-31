"""
Compose the two DOC main screens into ONE frame stream (doc-ops #117, PR #32 v3).

Why: over a home uplink each main half used to be its own connection, so each half stalled on its own
packet loss and the two drifted 100-400 ms apart (RTMP), or sat a constant ~160 ms apart (SRT, because
the relay fixes each connection's latency at its handshake). Two connections cannot be made to agree.
One picture carrying BOTH halves side by side, encoded once and sent over ONE connection, has no skew
between the halves by construction: they are the same video frame.

This module is pure numpy + threading, so the pusher (wgc_relay_push.py, target "mains") and the offline
simulator import the very same code.

  mixer = MainsMixer(open_sink)         # open_sink(width, height) -> write(bytes); called once, when the
                                        # geometry is known, so the caller can start ffmpeg at that size
  left  = SideFeed(mixer, "L", chrome_l)   # chrome = (top, bottom, left, right) pixels to crop off a capture
  right = SideFeed(mixer, "R", chrome_r)
  left.on_frame(bgra_hwc)  /  right.on_frame(bgra_hwc)   # from each WGC capture callback (copies at once)
  threading.Thread(target=mixer.run, daemon=True).start()

The mixer ticks at a fixed rate (default 60 Hz, absolute deadlines, no drift). A tick emits the composite
only if at least one half changed since the last emit, so a still screen costs nothing and the output
never exceeds the tick rate. Each half is written into the shared composite buffer the moment it arrives
(under a lock), so the tick always sends the freshest half of each side. ffmpeg then stamps the frame
by wall clock (-use_wallclock_as_timestamps 1), exactly as the v2 per-half pushers do.
"""
import threading
import time

import numpy as np


def _even(n):
    return int(n) - (int(n) % 2)


def crop_geometry(th, tw, chrome):
    """Where the cropped picture sits in a th x tw capture: (y0, x0, h, w), width and height even.
    chrome = (top, bottom, left, right), the same convention as stream_window_wgc / wgc_relay_push."""
    ct, cb, cl, cr = chrome
    return ct, cl, _even(th - ct - cb), _even(tw - cl - cr)


# Host resizes must not reach the lobby (2026-10-11). A feed locks its picture size on frame 0. Before, a later
# size change was pasted at the top-left corner of the locked size: a host who enlarged a game window streamed
# only its corner, and one who shrank it streamed black borders (the "morphing" seen on a host cab). Now every
# frame's game picture (chrome cropped off) is scaled to the locked size, keeping its aspect ratio, centred,
# black around it. Same size as the lock: a plain crop. Within DRIFT_PX of the lock (windows-capture's own
# few-pixel size wobble after frame 0): centre-crop or pad with plain slices, no resample, so a 2 px drift
# neither costs a rescale nor duplicates a row. A real resize: nearest-neighbour, indices cached per source size,
# gathered as 32-bit pixels (one value per BGRA pixel, about 4x faster than gathering bytes).
_FIT_CACHE = {}
DRIFT_PX = 8


def _crop_or_pad(src, oh, ow):
    """src: h x w x 4 near oh x ow. Centre it: crop what is over, pad black what is under."""
    h, w = src.shape[0], src.shape[1]
    sy, sx = max(0, (h - oh) // 2), max(0, (w - ow) // 2)
    dy, dx = max(0, (oh - h) // 2), max(0, (ow - w) // 2)
    hh, ww = min(h, oh), min(w, ow)
    if h >= oh and w >= ow:
        return src[sy:sy + oh, sx:sx + ow, :4]
    out = np.zeros((oh, ow, 4), np.uint8)
    out[dy:dy + hh, dx:dx + ww] = src[sy:sy + hh, sx:sx + ww, :4]
    return out


def fit_frame(buf, chrome, oh, ow):
    """buf: an H x W x 4 capture. Returns an oh x ow x 4 uint8 picture: the chrome-cropped game area scaled to
    fit (aspect kept, centred, black bars), or None when the crop leaves nothing."""
    th, tw = buf.shape[0], buf.shape[1]
    y0, x0, ch, cw = crop_geometry(th, tw, chrome)
    if ch <= 0 or cw <= 0:
        return None
    if ch == oh and cw == ow:
        return buf[y0:y0 + ch, x0:x0 + cw, :4]
    if abs(ch - oh) <= DRIFT_PX and abs(cw - ow) <= DRIFT_PX:
        return _crop_or_pad(buf[y0:y0 + ch, x0:x0 + cw], oh, ow)
    key = (th, tw, tuple(chrome), oh, ow)
    m = _FIT_CACHE.get(key)
    if m is None:
        s = min(oh / float(ch), ow / float(cw))
        nh = max(1, min(oh, int(round(ch * s))))
        nw = max(1, min(ow, int(round(cw * s))))
        yi = y0 + np.clip(((np.arange(nh) + 0.5) * ch / nh).astype(np.intp), 0, ch - 1)
        xi = x0 + np.clip(((np.arange(nw) + 0.5) * cw / nw).astype(np.intp), 0, cw - 1)
        m = ((oh - nh) // 2, (ow - nw) // 2, nh, nw, yi, xi)
        if len(_FIT_CACHE) > 64:
            _FIT_CACHE.clear()
        _FIT_CACHE[key] = m
    oy, ox, nh, nw, yi, xi = m
    if buf.dtype == np.uint8 and buf.ndim == 3 and buf.shape[2] == 4 and buf.strides[2] == 1 and buf.strides[1] == 4:
        b32 = buf.view(np.uint32).reshape(th, tw)          # one 32-bit value per BGRA pixel, no copy
        out = np.zeros((oh, ow), np.uint32)
        out[oy:oy + nh, ox:ox + nw] = b32.take(yi, axis=0)[:, xi]
        return out.view(np.uint8).reshape(oh, ow, 4)
    out = np.zeros((oh, ow, 4), np.uint8)
    out[oy:oy + nh, ox:ox + nw] = buf[yi[:, None], xi[None, :], :4]
    return out


class MainsMixer:
    def __init__(self, open_sink, hz=60.0, grace_s=6.0, clock=time.monotonic, on_error=None, err_sleep_s=1.0):
        self._open_sink = open_sink
        self._on_error = on_error or (lambda e: print("mixer error", repr(e), flush=True))
        self._err_sleep = float(err_sleep_s)
        self._period = 1.0 / float(hz)
        self._grace = float(grace_s)
        self._clock = clock
        self._lock = threading.Lock()
        self._first = {}          # side -> copy of its first cropped frame (kept until the geometry is known)
        self._born = clock()
        self._geom = None         # (wl, wr, h)
        self._buf = None          # composite (h, wl + wr, 4) BGRA
        self._dirty = False
        self._sink = None
        self._stop = threading.Event()
        self.stats = {"ticks": 0, "emitted": 0, "clean_skips": 0, "late_ticks": 0, "errors": 0, "puts_L": 0, "puts_R": 0}

    # -- geometry ------------------------------------------------------------------------------------
    @property
    def geometry(self):
        return self._geom

    def _decide_geometry(self, now):
        """Caller holds the lock. Both halves seen -> their sizes; one half only for grace_s -> that
        size for both (the missing half stays black until it shows up)."""
        f = self._first
        if "L" in f and "R" in f:
            wl, wr, h = f["L"].shape[1], f["R"].shape[1], max(f["L"].shape[0], f["R"].shape[0])
        elif f and now - self._born >= self._grace:
            one = next(iter(f.values()))
            wl = wr = one.shape[1]
            h = one.shape[0]
        else:
            return
        wl, wr, h = _even(wl), _even(wr), _even(h)
        if min(wl, wr, h) < 16:
            return
        self._geom = (wl, wr, h)
        self._buf = np.zeros((h, wl + wr, 4), np.uint8)
        for side, a in f.items():
            self._blit(side, a)
        self._first = {}
        self._dirty = True

    def _blit(self, side, a):
        wl, wr, h = self._geom
        x0, w = (0, wl) if side == "L" else (wl, wr)
        fh, fw = a.shape[0], a.shape[1]
        if fh == h and fw == w:
            self._buf[:, x0:x0 + w] = a[:, :, :4]
        else:                                           # size drifted after the lock: coerce, never shear
            self._buf[:, x0:x0 + w] = 0
            hh, ww = min(h, fh), min(w, fw)
            self._buf[:hh, x0:x0 + ww] = a[:hh, :ww, :4]

    # -- input (called from the capture callbacks) -----------------------------------------------------
    def put(self, side, frame):
        """frame: (h, w, 4) uint8 view of the CROPPED capture. Copied before this returns, because the
        capture library reuses its buffer after the callback."""
        with self._lock:
            self.stats["puts_" + side] += 1
            if self._geom is None:
                if side not in self._first:
                    self._first[side] = np.array(frame, dtype=np.uint8, copy=True)
                return
            self._blit(side, frame)
            self._dirty = True

    # -- output ----------------------------------------------------------------------------------------
    def tick(self, now=None):
        """One mixer tick: the composite as bytes if anything changed since the last emit, else None."""
        now = self._clock() if now is None else now
        with self._lock:
            self.stats["ticks"] += 1
            if self._geom is None:
                self._decide_geometry(now)
                if self._geom is None:
                    return None
            if not self._dirty:
                self.stats["clean_skips"] += 1
                return None
            self._dirty = False
            self.stats["emitted"] += 1
            return self._buf.tobytes()

    def run(self):
        """Tick forever. NOTHING in a tick or in the sink can end this thread: an exception (a Popen failure while
        starting ffmpeg, a write that raises something other than a dead pipe) is reported, the unsent frame is
        marked changed so it goes out again, and the loop carries on after err_sleep_s. A silently dead mixer
        thread would leave a frozen last picture on a healthy-looking pusher."""
        nxt = self._clock()
        while not self._stop.is_set():
            try:
                nxt += self._period
                d = nxt - self._clock()
                if d > 0:
                    time.sleep(d)
                elif d < -self._period:                     # fell behind (encoder pipe blocked): do not burst
                    self.stats["late_ticks"] += 1
                    nxt = self._clock()
                data = self.tick()
                if data is None:
                    continue
                if self._sink is None:
                    self._sink = self._open_sink(self._geom[0] + self._geom[1], self._geom[2])
                self._sink(data)
            except Exception as e:
                self.stats["errors"] += 1
                with self._lock:
                    self._dirty = True
                try:
                    self._on_error(e)
                except Exception:
                    pass
                time.sleep(self._err_sleep)
                nxt = self._clock()

    def stop(self):
        self._stop.set()


class SideFeed:
    """One main window's capture callback: lock the cropped picture size on frame 0, then scale every frame's
    game picture to it with fit_frame (a later size change, from windows-capture after frame 0 or from a host
    resizing the window, is never passed on: a rawvideo pipe shears), and hand the picture to the mixer."""

    def __init__(self, mixer, side, chrome):
        self.mixer, self.side, self.chrome = mixer, side, chrome
        self.locked = None   # (h, w) of the cropped picture

    def on_frame(self, buf):
        if self.locked is None:
            _, _, ch, cw = crop_geometry(buf.shape[0], buf.shape[1], self.chrome)
            if ch <= 0 or cw <= 0:
                return
            self.locked = (ch, cw)
        pic = fit_frame(buf, self.chrome, self.locked[0], self.locked[1])
        if pic is not None:
            self.mixer.put(self.side, pic)


# --- finding the two main windows (doc-ops #117, PR #32 review) -----------------------------------------------
def pick_main_pair(cands):
    """cands = [(x, hwnd, pid, w, h)] for the visible windows of the main-board flycast processes. Returns
    (left_hwnd, right_hwnd) ONLY when two DIFFERENT game processes each own a window; otherwise None. With one
    main up (the other still booting or crashed) the old pick gave cands[0] to the left half and cands[-1] to
    the right half, which is the same window, so the composite showed the left screen twice and looked healthy."""
    first = {}
    for c in sorted(cands):
        first.setdefault(c[2], c)                            # the leftmost window of each process
    if len(first) < 2:
        return None
    ordered = sorted(first.values())
    return ordered[0][1], ordered[-1][1]


def attach_backoff(fails, base=5.0, cap=60.0):
    """Seconds to wait before the next attempt to attach a capture, for any failure count (exponent capped)."""
    return min(cap, base * (2 ** min(max(0, fails), 6)))


# --- hardware encoder that will not open (NVENC session cap, init error) ---------------------------------------
HARDWARE_ENCODERS = ("h264_nvenc", "h264_qsv", "h264_amf")
_ENC_FAIL_MARKERS = ("openencodesessionex", "error while opening encoder", "nvenc", "nvcuda", "no capable devices",
                     "h264_qsv", "h264_amf", "encoder initialization failed", "cannot init")


def looks_like_encoder_failure(log_tail, encoder_name):
    """True when ffmpeg's own stderr says the ENCODER could not start (as opposed to the relay refusing the
    connection, which must not make a healthy GPU feed fall back to software)."""
    t = (log_tail or "").lower()
    if encoder_name and encoder_name.lower() in t:
        return True
    return any(m in t for m in _ENC_FAIL_MARKERS)


class EncoderFallback:
    """Counts consecutive QUICK exits of a feed's ffmpeg. After `limit` of them with a hardware encoder whose
    log says the encoder failed, the caller must switch that feed to libx264 (once). A GeForce refuses an
    11th concurrent NVENC session; before this the feed respawned the same failing command every 3 s forever."""

    def __init__(self, limit=3, quick_s=5.0):
        self.limit, self.quick_s = limit, quick_s
        self.quick = 0
        self.software = False

    def note_exit(self, lifetime_s, encoder_name, log_tail):
        """Call once per real ffmpeg respawn. Returns True exactly once: when to switch to software now."""
        if self.software or encoder_name not in HARDWARE_ENCODERS:
            self.quick = 0
            return False
        if lifetime_s < self.quick_s and looks_like_encoder_failure(log_tail, encoder_name):
            self.quick += 1
        else:
            self.quick = 0
        if self.quick >= self.limit:
            self.software = True
            return True
        return False


def swap_video_encoder(cmd, old_args, new_args):
    """Replace the contiguous `old_args` (the encoder block) in an ffmpeg command by `new_args`, and drop the
    NVENC-only `-forced-idr 1` pair. Returns a new list; the command is returned unchanged if old_args is absent."""
    n = len(old_args)
    for i in range(len(cmd) - n + 1):
        if cmd[i:i + n] == list(old_args):
            out = cmd[:i] + list(new_args) + cmd[i + n:]
            for j in range(len(out) - 1):
                if out[j] == "-forced-idr" and out[j + 1] == "1":
                    del out[j:j + 2]
                    break
            return out
    return list(cmd)
