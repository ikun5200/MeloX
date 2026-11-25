#!/usr/bin/env python3
"""Local HTTPS server standing in for an LX source backend and QQ's CDN.

    server.py <rig-dir> [port]

`/resolve?mid=<songmid>&q=<lx quality>` answers the test source script.
What it answers is decided per song by `behaviours.json` in the rig
directory, re-read on every request so a scenario can be changed while the
app is running:

    { "<songmid>": { "<lx quality>": "<behaviour>", "*": "<behaviour>" } }

Behaviours:
    ok            the real file for that quality
    as:<quality>  a real file, but of another quality (silent downgrade)
    clip          QQ's short trial clip in place of the song
    fakeclip      the trial clip, behind headers that claim the real file
    garbage       the real file's length in bytes that are not audio
    probeonly     answers the first request, then drops every connection
    reject        the source fails with an error
    dead404       a URL that answers 404
    dead403       a URL that answers 403
    deadjson      a URL that answers 200 with a JSON error body
    refused       a URL nothing listens on
    slow:<secs>   reject after waiting

Every request is appended to `requests.log`.
"""

import json
import os
import ssl
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

RIG = os.path.abspath(sys.argv[1])
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8443
BASE = f"https://localhost:{PORT}"

FILES = {
    "128k": "M500.mp3",
    "320k": "M800.mp3",
    "flac": "F000.flac",
    "flac24bit": "RS01.flac",
    "hires": "RS01.flac",
    "atmos": "Q000.flac",
    "atmos_plus": "Q001.flac",
    "master": "AI00.flac",
}
TYPES = {".mp3": "audio/mpeg", ".flac": "audio/flac"}
SEEN = set()


def behaviour_for(mid, quality):
    try:
        with open(os.path.join(RIG, "behaviours.json"), encoding="utf-8") as f:
            table = json.load(f)
    except (OSError, ValueError):
        table = {}
    song = table.get(mid, table.get("*", {}))
    return song.get(quality, song.get("*", "ok"))


def log(line):
    with open(os.path.join(RIG, "requests.log"), "a", encoding="utf-8") as f:
        f.write(f"{time.strftime('%H:%M:%S')} {line}\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def send_body(self, status, body, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/resolve":
            return self.resolve(parse_qs(url.query))
        if url.path == "/sizes":
            directory = os.path.join(RIG, "audio")
            sizes = {name: os.path.getsize(os.path.join(directory, name))
                     for name in sorted(os.listdir(directory))}
            return self.send_body(200, json.dumps(sizes).encode())
        if url.path.startswith("/audio/"):
            return self.audio(url.path[len("/audio/"):])
        if url.path.startswith("/dead404/"):
            log(f"GET {url.path} -> 404")
            return self.send_body(404, b"not found", "text/plain")
        if url.path.startswith("/dead403/"):
            log(f"GET {url.path} -> 403")
            return self.send_body(403, b"", "application/octet-stream")
        if url.path.startswith("/deadjson/"):
            log(f"GET {url.path} -> 200 json")
            return self.send_body(200, b'{"code":404,"msg":"no such quality"}')
        if url.path.startswith(("/fakeclip/", "/garbage/")):
            return self.impostor(url.path)
        if url.path.startswith("/probeonly/"):
            return self.probe_only(self.path)
        self.send_body(404, b"not found", "text/plain")

    def resolve(self, query):
        mid = query.get("mid", [""])[0]
        quality = query.get("q", [""])[0]
        behaviour = behaviour_for(mid, quality)
        log(f"resolve mid={mid} q={quality} -> {behaviour}")
        name = f"{mid}-{quality}"
        if behaviour.startswith("slow:"):
            time.sleep(float(behaviour.split(":", 1)[1]))
            behaviour = "reject"
        if behaviour == "reject":
            payload = {"error": f"no {quality} for this song"}
        elif behaviour == "ok" and quality in FILES:
            payload = {"url": f"{BASE}/audio/{FILES[quality]}?song={name}"}
        elif behaviour == "clip":
            payload = {"url": f"{BASE}/audio/RS02.mp3?song={name}"}
        elif behaviour in ("fakeclip", "garbage", "probeonly") and quality in FILES:
            payload = {"url": f"{BASE}/{behaviour}/{FILES[quality]}?song={name}&t={time.time_ns()}"}
        elif behaviour.startswith("as:") and behaviour[3:] in FILES:
            payload = {"url": f"{BASE}/audio/{FILES[behaviour[3:]]}?song={name}"}
        elif behaviour in ("dead404", "dead403", "deadjson"):
            payload = {"url": f"{BASE}/{behaviour}/{name}.flac"}
        elif behaviour == "refused":
            payload = {"url": f"https://localhost:9/{name}.flac"}
        else:
            payload = {"error": f"unsupported quality {quality}"}
        self.send_body(200, json.dumps(payload).encode())

    def impostor(self, path):
        """Answers the two-byte probe as the real file would, then serves
        something else: the trial clip, or bytes that are not audio."""
        kind, name = path.strip("/").split("/", 1)
        real = os.path.join(RIG, "audio", os.path.basename(name))
        size = os.path.getsize(real)
        content_type = TYPES.get(os.path.splitext(real)[1], "application/octet-stream")
        header = self.headers.get("Range")
        log(f"{self.command} {path} range={header or '-'}")
        if header == "bytes=0-1":
            self.send_response(206)
            self.send_header("Content-Type", content_type)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", "2")
            self.send_header("Content-Range", f"bytes 0-1/{size}")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(b"\x00\x00")
            return
        if kind == "fakeclip":
            with open(os.path.join(RIG, "audio", "RS02.mp3"), "rb") as f:
                return self.send_body(200, f.read(), "audio/mpeg")
        self.send_body(200, os.urandom(min(size, 512 * 1024)), content_type)

    def probe_only(self, target):
        """An address that is alive when checked and gone when played."""
        name = os.path.basename(urlparse(target).path)
        size = os.path.getsize(os.path.join(RIG, "audio", name))
        if target not in SEEN:
            SEEN.add(target)
            log(f"{self.command} {target.split('?')[0]} -> answered once")
            self.send_response(206)
            self.send_header("Content-Type", TYPES.get(os.path.splitext(name)[1], "application/octet-stream"))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", "2")
            self.send_header("Content-Range", f"bytes 0-1/{size}")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(b"\x00\x00")
            return
        log(f"{self.command} {target.split('?')[0]} -> connection dropped")
        self.close_connection = True
        try:
            self.connection.close()
        except OSError:
            pass

    def audio(self, name):
        path = os.path.join(RIG, "audio", os.path.basename(name))
        if not os.path.isfile(path):
            log(f"GET /audio/{name} -> 404")
            return self.send_body(404, b"not found", "text/plain")
        size = os.path.getsize(path)
        start, end = 0, size - 1
        header = self.headers.get("Range")
        partial = False
        if header and header.startswith("bytes="):
            first, _, last = header[6:].split(",")[0].partition("-")
            if first:
                start = int(first)
                end = int(last) if last else size - 1
            elif last:
                start = max(size - int(last), 0)
            end = min(end, size - 1)
            if start > end:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            partial = True
        length = end - start + 1
        log(f"{self.command} /audio/{name} range={header or '-'}")
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", TYPES.get(os.path.splitext(path)[1], "application/octet-stream"))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(path, "rb") as f:
            f.seek(start)
            remaining = length
            try:
                while remaining > 0:
                    chunk = f.read(min(64 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                pass


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(os.path.join(RIG, "srv.pem"), os.path.join(RIG, "srv.key"))
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(f"serving {RIG} on {BASE}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
