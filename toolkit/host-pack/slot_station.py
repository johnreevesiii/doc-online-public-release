#!/usr/bin/env python3
"""DOC relay kit: per-seat SLOT STATION server (the broker's card plane).

The broker talks to one station per seat at http://127.0.0.1:8788+(N-1) with this tiny API
(mirrored from the production pack's station agents):
  GET    /api/ping             -> {"stationId": N}
  GET    /api/slot/<id>        -> {"bytes": "<b64>"} or 404 when the slot is empty
  POST   /api/slot/<id>        {"bytes": "<b64>"} -> write the seat's card slot
  POST   /api/save/<id>        {} -> move the slot card into the local library -> {"file": name}
  GET    /api/library/<name>   -> {"file": name, "bytes": "<b64>"}  (the broker reads a saved card back)
  DELETE /api/library/<name>   -> discard a library file

Slot file = <pack>/sat<N>/data/<rom>.zip.card (what the game's card reader loads).
  py -3 slot_station.py <pack_dir> <rom> <seat_count>
One process binds every seat's port.
"""
import base64, json, os, re, socket, sys, threading, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PACK = sys.argv[1]
ROM = sys.argv[2]
SEATS = int(sys.argv[3])
BASE_PORT = int(os.environ.get("SLOT_STATION_BASE_PORT") or 8788)   # override only for offline tests

def slot_path(n):
    return os.path.join(PACK, "sat%d" % n, "data", ROM + ".zip.card")

def card_name(raw):
    """The horse's name as the card spells it, for the broker's save reply (2026-09-30). World cards only:
    bytes 0-17 of track 1, printable ASCII. A JP card's name is kana and a DOC II card's is enciphered, so
    those come back "" and the server reads the name off the card itself. Anything unclean is "" too: the
    broker posts a name only when it is a real one."""
    if len(raw) != 207 or raw[0x8A:0x92] not in (b"SEGABEF0", b"SEGARE01"):
        return ""
    if (raw[0x20] == 0x03 and raw[0x21] == 0x02) or (raw[0x20] == 0x11 and raw[0x21] == 0x06):
        return ""                       # a JP card over a stale World marker
    name = raw[0:18].rstrip(b"\x00")
    if any(c < 32 or c > 126 for c in name):
        return ""
    return name.decode("ascii").strip()

def lib_dir(n):
    d = os.path.join(PACK, "sat%d" % n, "data", "_library")
    os.makedirs(d, exist_ok=True)
    return d

def make_handler(n):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *a): pass
        def _json(self, code, obj):
            out = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(out)))
            if self.close_connection:
                self.send_header("Connection", "close")
            self.end_headers(); self.wfile.write(out)
        def _refuse(self, code, msg):
            # Never leave an unread body on a kept-alive connection: it would be parsed as a second request without
            # this one's headers, which smuggles a write past every check here (doc-ops #117 review P1-1).
            self.close_connection = True
            self._json(code, {"error": msg})
            return True
        def _guard(self, write):
            """True when the request was refused (the reply is already sent). Every request: the Host header must
            name this station on 127.0.0.1 or localhost (a DNS-rebinding page sends its own name), and a body this
            server will not read closes the connection. Writes, saves and deletes also: no browser markers, an
            exact application/json Content-Type (a browser cannot send it without a preflight, and the station
            answers no OPTIONS), and a sane Content-Length. The broker's calls meet all of these."""
            port = BASE_PORT + n - 1
            # One Host and at most one Content-Length: a repeated header could make this check and the body framing
            # read different values (review of 48dd872, P3-1).
            if len(self.headers.get_all("Host") or []) > 1 or len(self.headers.get_all("Content-Length") or []) > 1:
                return self._refuse(400, "repeated Host or Content-Length header")
            if (self.headers.get("Host") or "").strip().lower() not in ("127.0.0.1:%d" % port, "localhost:%d" % port):
                return self._refuse(403, "this station answers on 127.0.0.1 or localhost at its own port only")
            if self.headers.get("Transfer-Encoding"):
                return self._refuse(400, "chunked bodies are not accepted")
            cl = self.headers.get("Content-Length")
            if cl is not None:
                try:
                    cln = int(cl)
                except ValueError:
                    return self._refuse(400, "bad Content-Length")
                if cln < 0 or cln > 65536:
                    return self._refuse(400, "bad Content-Length")
            else:
                cln = 0
            if cln and (not write or self.command != "POST"):
                # Only POST reads its body. A GET or DELETE that carries one closes after its reply, so the unread
                # bytes are never parsed as a second request (review of 48dd872, P3-1: a DELETE body smuggled a write).
                self.close_connection = True
            if not write:
                return False
            if self._from_browser():
                return self._refuse(403, "card writes from a web browser are not accepted")
            if (self.headers.get("Content-Type") or "").split(";")[0].strip().lower() != "application/json":
                return self._refuse(415, "card writes must be application/json")
            return False
        def _from_browser(self):
            """A web browser marks its requests (Origin on cross-site and same-origin POSTs, Sec-Fetch-* on
            current browsers); the broker's own calls carry neither. Card writes from a browser are refused, so
            no web page (or card editor) can put a card into a seat (doc-ops #117)."""
            return bool(self.headers.get("Origin") or self.headers.get("Sec-Fetch-Site") or self.headers.get("Sec-Fetch-Mode"))
        def do_GET(self):
            if self._guard(False):
                return
            if self.path == "/api/ping":
                # ok + rom, as the Station Manager answers (2026-09-30): the pack's Doctor and the house
                # tools read `ok`, and `rom` says which game's slot file this station serves.
                return self._json(200, {"ok": True, "stationId": n, "rom": ROM})
            if re.match(r"^/api/slot/\d+$", self.path):
                p = slot_path(n)
                if not os.path.exists(p): return self._json(404, {"error": "empty"})
                with open(p, "rb") as f: data = f.read()
                return self._json(200, {"bytes": base64.b64encode(data).decode()})
            # GET /api/library/<name> (2026-09-19). The broker's save moves the slot card into the library
            # and then READS IT BACK from here to upload it -- and this endpoint didn't exist, so the read
            # 404'd, the broker reported "station unreachable", and every save left the horse stranded in
            # the library with the seat emptied. No broker save on this cabinet had ever completed.
            m = re.match(r"^/api/library/([A-Za-z0-9_.%-]+)$", self.path)
            if m:
                fn = os.path.basename(urllib.parse.unquote(m.group(1)))
                p = os.path.join(lib_dir(n), fn)
                if not os.path.exists(p): return self._json(404, {"error": "no such file"})
                with open(p, "rb") as f: data = f.read()
                return self._json(200, {"file": fn, "bytes": base64.b64encode(data).decode()})
            self._json(404, {"error": "not found"})
        def do_POST(self):
            if self._guard(True):
                return
            ln = int(self.headers.get("Content-Length") or 0)
            try: body = json.loads(self.rfile.read(ln)) if ln else {}
            except Exception: body = {}
            if re.match(r"^/api/slot/\d+$", self.path):
                b64 = body.get("bytes") or ""
                try: raw = base64.b64decode(b64)
                except Exception: return self._json(400, {"error": "bad b64"})
                if len(raw) != 207: return self._json(400, {"error": "not a 207-byte card"})
                rb = raw[0x8A:0x92] == b"SEGARE01"
                jp = (raw[0x20], raw[0x21]) in ((3, 2), (17, 6))
                if (ROM == "docrebal" and (not rb or jp)) or (ROM != "docrebal" and rb):
                    return self._json(409, {"error": "Card belongs to another game version"})
                p = slot_path(n)
                os.makedirs(os.path.dirname(p), exist_ok=True)
                tmp = p + ".tmp"
                with open(tmp, "wb") as f: f.write(raw)
                os.replace(tmp, p)
                return self._json(200, {"ok": True})
            if re.match(r"^/api/save/\d+$", self.path):
                p = slot_path(n)
                if not os.path.exists(p): return self._json(404, {"error": "empty"})
                fn = "slot-%d-%d.card" % (n, int(time.time()))
                with open(p, "rb") as f: raw = f.read()
                os.replace(p, os.path.join(lib_dir(n), fn))
                # horse + rom in the save reply (2026-09-30), as the Station Manager gives them. Without a
                # name the 2.1.2 broker posted "Unnamed" over real names, and without a rom it tagged every
                # card drbyocwc. The unified broker depends on neither, but a reply that says what it moved
                # costs nothing.
                return self._json(200, {"ok": True, "file": fn, "horse": card_name(raw), "rom": ROM})
            self._json(404, {"error": "not found"})
        def do_DELETE(self):
            if self._guard(True):
                return
            m = re.match(r"^/api/library/([A-Za-z0-9_.%-]+)$", self.path)
            if m:
                fn = os.path.basename(m.group(1))
                p = os.path.join(lib_dir(n), fn)
                try: os.remove(p); return self._json(200, {"ok": True})
                except OSError: return self._json(404, {"error": "no such file"})
            self._json(404, {"error": "not found"})
    return H

class ExclusiveServer(ThreadingHTTPServer):
    """NEVER share a port (2026-09-30, doc-ops #65). Python's HTTPServer sets SO_REUSEADDR, and on Windows
    that lets a second socket bind a port another process is already listening on; after that either one
    may answer. The game launcher's Station Managers (Tools\\doc_suite_server.ps1) use these same 8788+
    ports, so a broker save could be MOVED by one process and read back from the other's library, and the
    card was stranded. Now a port that is taken stays with whoever holds it, and one this station holds
    cannot be taken from it."""
    allow_reuse_address = False
    def server_bind(self):
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()

if __name__ == "__main__":
    for i in range(1, SEATS + 1):
        try:
            srv = ExclusiveServer(("127.0.0.1", BASE_PORT + i - 1), make_handler(i))
        except OSError as e:
            print("station seat%d: port %d is already taken (%s); leaving that seat to the process holding it"
                  % (i, BASE_PORT + i - 1, e), flush=True)
            continue
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        print("station seat%d on %d -> %s" % (i, BASE_PORT + i - 1, slot_path(i)), flush=True)
    while True: time.sleep(3600)
