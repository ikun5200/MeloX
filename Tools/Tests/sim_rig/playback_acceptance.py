#!/usr/bin/env python3
"""Controlled-source playback acceptance. Run ONLY on an exclusively assigned rig.

  python3 -I Tools/Tests/sim_rig/playback_acceptance.py \
      --udid "$UDID" --rig-dir "$RIG" --port "$PORT" --exclusive-loopback

Prerequisites: an already booted disposable simulator, installed simulator Debug
build, ONLY the source seeded from test_source.js, trusted fixture CA, server.py
already listening. Use the simulator's fixture-only Debug entry (default), or
supply --externally-isolated ONLY with independent proof of loopback-only egress.
This tool does not change network policy. No build/boot/seed/install/erase,
source import, keychain access or real-song API. Each case cold-launches just
MeloX on the exact UDID, checks the isolation marker before any playback and
keeps home, lyrics, account refresh and saved queue restoration out of the test. The player itself, resolver, probes and decks are the production path.

Mailbox actions: state, quality?q=high|hiResolution (session), play?index=N
with the fixture sizes endpoint, and seek?to=SECONDS. No special mutation or
forced end/ready command. Require debug-state.evidence keyed by QQ enum case,
nextPreparation, and the safe next/format/resolver rigTrace events.

Use --case to repeat one case. Output is an allowlist of fixture events, not a
console dump. Redirect stdout to retain a comparison. App times have 10 ms
resolution, server times 1 s. EOF->playing is an engine interval, NOT a measure
of sample continuity. The old baseline asked only for 320k on TESTMP3, probed
but did not decode before EOF, and could resolve the same slow tier twice.
"""

import argparse
import fcntl
import http.client
import json
import mmap
import os
from pathlib import Path
import plistlib
import re
import ssl
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from dataclasses import dataclass
from uuid import uuid4


HERE = Path(__file__).resolve().parent
BUNDLE = "azki.moye.MeloX"
SIMCTL = ["/usr/bin/xcrun", "simctl"]
SOURCE = "MeloX 测试音源"
# Indices, not engine identifiers. Learn the latter from the active deck trace.
SONGS = ("TESTALL", "TESTNOHIRES", "TESTMP3", "TESTUNKNOWN", "TEST128", "TESTALL2", "TESTLONG")
TIERS = {"128k": "standard", "320k": "high", "flac": "lossless", "hires": "hiResolution",
         "flac24bit": "hiResolution", "atmos": "highDefinitionSurround",
         "atmos_plus": "immersiveSurround", "master": "ultraClearMaster"}
HI = "hiResolution"
PHASES = {"idle", "resolving", "resolved", "buffering", "ready", "failed"}
FILES = {"standard": ("M500.mp3", 44100), "high": ("M800.mp3", 44100), HI: ("RS01.flac", 96000)}
TOKEN = r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}"
NEXT = re.compile(rf"(?:prepare token={TOKEN} from=\d+ to=\d+|ready token={TOKEN} to=\d+|"
                  rf"eof from=\d+|handoff kind=(?:standby|source|automix) token={TOKEN} from=\d+ to=\d+|playing id=\d+)")
CLOCK = re.compile(r"(\d{1,2}):(\d{2}):(\d{2})[.,](\d{2})(?!\d)")


class Failure(Exception):
    """Only raise with fixed descriptions or allowlisted fixture data."""


def need(condition, message):
    if not condition:
        raise Failure(message)


def say(message):
    print(message, flush=True)


def atomic(path, data, mode=None):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as f:
        tmp = Path(f.name)
        try:
            if mode is not None:
                os.fchmod(f.fileno(), mode)
            f.write(data)
            f.flush()
            os.replace(tmp, path)
        finally:
            tmp.unlink(missing_ok=True)


def regular(path):
    need(path.is_file() and not path.is_symlink() and path.stat().st_uid == os.getuid(),
         "expected an owned regular rig file")
    return path


def exclusive_source(container, port):
    path = container / "Library/Application Support/MeloX/LXSources.json"
    sources = json.loads(regular(path).read_bytes())
    need(isinstance(sources, list) and len(sources) == 1, "refusing a non-exclusive source store")
    src = sources[0]
    need(src.get("isEnabled") is True and src.get("name") == SOURCE and not src.get("scriptURL")
         and not src.get("homepage"), "refusing a non-fixture source")
    caps = src.get("capabilities", [])
    need(len(caps) == 1 and caps[0].get("id") == "tx" and caps[0].get("actions") == ["musicUrl"],
         "wrong fixture capabilities")
    q = caps[0]["qualitys"]
    need({"128k", "320k", "flac", "hires"} <= set(q) <= TIERS.keys() and len(q) == len(set(q)),
         "fixture must declare the test ladder")
    # Match ALL executable JS, not its display name or a localhost substring.
    template = (HERE / "test_source.js").read_text().replace("__BACKEND__", f"https://localhost:{port}")
    before, after = template.split("__QUALITYS__")
    raw = src["rawScript"]
    m = re.fullmatch(re.escape(before) + r"(\[[\s\w,\"_]*\])" + re.escape(after), raw)
    need(m and json.loads(m[1]) == q, "fixture script/backend does not match this rig exactly")
    return f"{SOURCE} [on] " + ",".join(q)


def verify_server(root, port):
    # Bind the server, its TLS identity, audio files and the observed log to this
    # directory. Connecting to a bare port (or trusting a source label) is not enough.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.load_verify_locations(cafile=str(regular(root / "ca.pem")))
    conn = http.client.HTTPSConnection("127.0.0.1", port, timeout=4, context=context)
    marker = "RIGCHECK" + uuid4().hex
    with regular(root / "requests.log").open("rb") as log:
        log.seek(0, 2)
        try:
            conn.request("GET", "/sizes")
            resp = conn.getresponse()
            need(resp.status == 200, "fixture sizes endpoint unavailable")
            sizes = json.loads(resp.read(8192))
            for name, _ in FILES.values():
                need(sizes.get(name, 0) == regular(root / "audio" / name).stat().st_size > 0,
                     "fixture sizes do not match the rig")
            conn.request("GET", f"/resolve?mid={marker}&q=rigcheck")
            resp = conn.getresponse()
            need(resp.status == 200, "fixture identity check failed")
            resp.read(4096)
            need(f"resolve mid={marker} q=rigcheck -> ".encode() in log.read(),
                 "server is not writing this rig's request log")
        finally:
            conn.close()


@dataclass
class Event:
    name: str
    time: int  # app centiseconds of day; receipt/polling time is NOT the event time
    fields: dict


def elapsed(first, last):
    # The locale can use a 12-hour clock; cases last under two minutes.
    return ((last.time - first.time) % (12 * 3600 * 100)) / 100


class Run:
    def __init__(self, root, docs, port, source, externally_isolated):
        self.root, self.docs, self.port, self.source = root, docs, port, source
        self.externally_isolated = externally_isolated
        self.events, self.queries, self.media = [], [], []
        self.pending = b""
        self.sent = None
        self.state = {}
        self.proc = None

    def read_events(self):
        # --console is a pipe. Never persist or print raw stdout, stderr, state,
        # source script, exceptions, URLs, issue/notice/note, or unknown labels.
        while True:
            try:
                chunk = os.read(self.proc.stdout.fileno(), 65536)
            except BlockingIOError:
                break
            if not chunk:
                break
            lines = (self.pending + chunk).split(b"\n")
            self.pending = lines.pop()
            for raw in lines:
                m = re.fullmatch(r"\[(next|format|resolver)\] (.+?) "
                                 r"(prepare .+|ready .+|eof .+|handoff .+|playing .+|source rate=.+|event=probe .+)",
                                 raw.decode("utf-8", "replace").strip())
                if not m:
                    continue
                clock = CLOCK.search(m[2])
                if not clock:
                    continue
                h, minute, sec, cs = map(int, clock.groups())
                stamp = ((h * 60 + minute) * 60 + sec) * 100 + cs
                if m[1] == "next" and NEXT.fullmatch(m[3]):
                    name, *parts = m[3].split()
                    fields = dict(part.split("=") for part in parts)
                    self.events.append(Event(name, stamp, fields))
                    say(f"APP {clock[0]} {m[3]}")
                elif m[1] == "resolver":
                    probe = re.match(rf"event=probe source={TOKEN} asked=(hires|flac|320000|128000) "
                                     r"actual=(hires|flac|320000|128000) container=(flac|mpeg) size=([0-9]+) "
                                     r"rate=(\d+) bits=(\d+) rule=(streamInfo|catalogAndAudio|estimate) "
                                     r"verified=(true|false)(?:\s|$)", m[3])
                    if probe:
                        keys = ("asked", "actual", "container", "size", "rate", "bits", "rule", "verified")
                        fields = dict(zip(keys, probe.groups()))
                        self.events.append(Event("probe", stamp, fields))
                        say(f"PROBE {clock[0]} " + " ".join(f"{k}={v}" for k, v in fields.items()))
                elif m[1] == "format":
                    fmt = re.match(r"source rate=(\d+(?:\.\d+)?) channels=(\d+)(?:\s|$)", m[3])
                    if fmt:
                        self.events.append(Event("format", stamp, {"rate": float(fmt[1]), "channels": int(fmt[2])}))
                        say(f"APP {clock[0]} format rate={fmt[1]} channels={fmt[2]}")
        for raw in iter(self.log.readline, b""):
            line = raw.decode("ascii", "replace").rstrip()
            m = re.fullmatch(r"(\d\d:\d\d:\d\d) resolve mid=(\w+) q=(\w+) -> (\S+)", line)
            if m:
                need(m[2] in SONGS and m[3] in TIERS, "unexpected requester on the exclusive server")
                need(m[4] in {"ok", "reject", "as:320k", "slow:8", "slow:14", "dead404"},
                     "unexpected fixture response on the exclusive server")
                self.queries.append((m[2], m[3], m[4]))
                say(f"RESOLVE {m[1]} {m[2]} {m[3]} {m[4]}")
                continue
            m = re.fullmatch(r"(\d\d:\d\d:\d\d) GET /audio/(\w+\.(?:mp3|flac)) range=(-|bytes=\d+-\d*)", line)
            if m and m[2] in {f for f, _ in FILES.values()}:
                # Old resolver: 42 B. New resolver: 8 KiB (optionally another
                # small range past an ID3 tag). Neither is decoder payload.
                extent = re.fullmatch(r"bytes=(\d+)-(\d+)", m[3])
                if m[3] in {"bytes=0-41", "bytes=0-8191"}:
                    kind = "probe"
                elif extent and int(extent[2]) - int(extent[1]) < 8192:
                    kind = "header"
                else:
                    kind = "body"
                if (m[2], kind) not in self.media:
                    say(f"MEDIA {m[1]} {m[2]} {kind}")
                self.media.append((m[2], kind))

    def command(self, text, timeout=6):
        cmd, state = self.docs / "debug-command.txt", self.docs / "debug-state.json"
        need(not cmd.exists() and not cmd.is_symlink() and not state.is_symlink(), "debug mailbox is busy/unsafe")
        old = state.stat().st_ino if state.exists() else None
        self.sent = text.encode()
        atomic(cmd, self.sent)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.read_events()
            need(self.proc.poll() is None, "fixture app exited before acknowledging the command")
            # Swift writes atomically AFTER removing the command. Existence alone
            # would accept the previous response. Open before checking identity.
            if not cmd.exists() and state.is_file():
                with state.open("rb") as f:
                    if os.fstat(f.fileno()).st_ino != old:
                        s = json.load(f)
                        need(self.externally_isolated or s.get("fixtureOnly") is True,
                             "fixture-only Debug entry is not active; no playback permitted")
                        need(s.get("sources") == [self.source], "runtime source store is not the isolated fixture")
                        need(s.get("mid") in ("", *SONGS), "non-fixture song in the app; stopping")
                        need(s.get("nextPreparation") in PHASES and isinstance(s.get("evidence"), dict),
                             "build lacks debug nextPreparation/evidence")
                        if self.state.get("nextPreparation") != s["nextPreparation"]:
                            say(f"STATE {s['mid'] or '-'} progress={float(s['progress']):.1f} next={s['nextPreparation']}")
                        self.state = s
                        self.read_events()
                        return s
            time.sleep(0.025)
        raise Failure("timed out waiting for a fresh debug-state acknowledgement")

    def until(self, label, predicate, timeout=20):
        limit = time.monotonic() + timeout
        while time.monotonic() < limit:
            s = self.command("state")
            if predicate(s):
                return s
        s = self.state
        quality = s.get("playing") if s.get("playing") in TIERS.values() else "-"
        raise Failure(f"timeout: {label}; fixture={s['mid'] or '-'} actual={quality} "
                      f"progress={float(s['progress']):.1f} next={s['nextPreparation']}")

    def play(self, mid):
        # Never play the two unknown-metadata fixtures: those can fetch QQ detail.
        need(mid in {"TESTALL", "TESTNOHIRES", "TESTMP3", "TEST128", "TESTALL2"}, "unknown test track")
        self.command(f"play?index={SONGS.index(mid)}&sizes=https://localhost:{self.port}/sizes")

    def quality(self, q):
        self.command(f"quality?q={q}")  # session only, never change the Wi-Fi/cellular preference

    def seek_remaining(self, seconds):
        self.command(f"seek?to={self.state['seconds'] - seconds}")

    def matching(self, name, **fields):
        return [e for e in self.events if e.name == name and e.fields.items() >= fields.items()]

    def requests(self, mid):
        return [(q, b) for song, q, b in self.queries if song == mid]

    def playing(self, mid, q, requested, progress=0.4, timeout=22):
        s = self.until(f"{mid} playing {q}", lambda s: s["mid"] == mid and s["requested"] == requested
                       and s["playing"] == q and s["isPlaying"] and not s["isLoading"] and not s["switching"]
                       and s["progress"] >= progress, timeout)
        need(s["evidence"].get(q) == "verified", f"{mid}: actual mapped QQ tier {q} not verified")
        need(not s["issue"], f"{mid}: foreground playback raised an issue")
        say(f"PLAY {mid} requested={requested} actual={q} evidence=verified progress={s['progress']:.1f}")
        return s

    def verified_probe(self, asked, actual):
        raw = {HI: "hires", "high": "320000", "standard": "128000"}
        name, rate = FILES[actual]
        hits = self.matching("probe", asked=raw[asked], actual=raw[actual], verified="true",
                             container="flac" if actual == HI else "mpeg",
                             size=str((self.root / "audio" / name).stat().st_size))
        need(hits, f"no checked {asked} -> {actual} probe for this fixture")
        if actual == HI:
            need(all(int(e.fields["rate"]) == rate and int(e.fields["bits"]) >= 24 for e in hits),
                 "Hi-Res probe did not read 96 kHz / 24-bit-or-higher FLAC STREAMINFO")
        return hits

    def decoded(self, q):
        name, rate = FILES[q]
        need((name, "probe") in self.media, f"missing real {name} probe")
        need((name, "body") in self.media, f"missing non-probe {name} media read")
        need(self.matching("format", rate=rate, channels=2), f"missing source format {rate} Hz stereo")

    def mark(self):
        self.read_events()
        self.events.clear()
        self.queries.clear()
        self.media.clear()


def configure(root, table):
    # A missing per-song key defaults to ok on this server. Explicitly bound all
    # other tracks/aliases to reject: a surprise candidate cannot pass by luck.
    atomic(root / "behaviours.json", json.dumps({"*": {"*": "reject"}, **table}).encode())


def answers(**rules):
    return {"*": "reject", **rules}


def hires(rule="ok"):
    return answers(hires=rule, flac24bit=rule, **{"320k": "ok"})


def positive(r):
    configure(r.root, {"TESTMP3": hires()})
    r.quality("high")
    r.play("TESTMP3")
    s = r.playing("TESTMP3", "high", "high")
    need(s["evidence"].get(HI) == "untested" and HI in s["offered"],
         "QQ omission hid or marked the untested Hi-Res choice as unavailable")
    r.mark()
    r.quality(HI)
    r.playing("TESTMP3", HI, HI)
    need(r.requests("TESTMP3") == [("hires", "ok")], "missing/duplicate proactive Hi-Res request")
    r.verified_probe(HI, HI)
    r.decoded(HI)


def spoof(r):
    # No genuine MP3 request succeeds: only the response to Hi-Res returns M800.
    configure(r.root, {"TESTMP3": answers(hires="as:320k", flac24bit="as:320k")})
    r.quality(HI)
    r.play("TESTMP3")
    s = r.playing("TESTMP3", "high", HI)
    need(r.requests("TESTMP3")[:1] == [("hires", "as:320k")], "did not probe the spoofed high request")
    need(s["evidence"].get(HI) == "unavailable", "MP3 was accepted as Hi-Res evidence")
    r.verified_probe(HI, "high")
    r.decoded("high")


def ladder(r):
    configure(r.root, {"TESTNOHIRES": answers(flac="dead404", **{"128k": "ok"}), "TESTMP3": hires()})
    r.quality(HI)
    r.play("TESTNOHIRES")
    s = r.playing("TESTNOHIRES", "standard", HI)
    req = r.requests("TESTNOHIRES")
    # A source can be asked under its second Hi-Res alias after a rejection.
    need([q for q, _ in req] in (["hires", "flac", "320k", "128k"],
                                 ["hires", "flac24bit", "flac", "320k", "128k"]),
         "did not traverse the QQ ladder once in descending order")
    need(all(s["evidence"].get(q) == "unavailable" for q in (HI, "lossless", "high")),
         "failed mapped tiers missing from this song's evidence")
    r.verified_probe("standard", "standard")
    r.decoded("standard")
    # Same low-catalog TESTMP3 and probe as the foreground positive case, but
    # resolved in standby after three misses on the outgoing song.
    old = outgoing_id(r)
    r.seek_remaining(12)
    r.until("Hi-Res standby on the low-catalog successor", lambda s: s["mid"] == "TESTNOHIRES" and
            s["nextPreparation"] == "ready" and r.matching("ready"), 12)
    start = prepared(r, old)
    new, token = start.fields["to"], start.fields["token"]
    need(r.matching("ready", token=token, to=new) and not r.matching("eof"), "wrong or late Hi-Res standby")
    r.playing("TESTMP3", HI, HI, progress=1)  # no quality command, no manual advance
    need(r.requests("TESTMP3") == [("hires", "ok")], "preference/evidence did not recover on next song")
    need(len(r.matching("handoff", kind="standby", token=token, to=new, **{"from": old})) == 1
         and len(r.matching("prepare")) == 1 and r.matching("playing", id=new),
         "did not promote the Hi-Res preparation from the same resolver")
    r.verified_probe(HI, HI)
    r.decoded(HI)


def outgoing_id(r):
    plays = r.matching("playing")
    need(plays and len({e.fields['id'] for e in plays}) == 1, "missing/ambiguous outgoing engine id")
    return plays[-1].fields["id"]


def tail_setup(r, rule):
    configure(r.root, {"TESTALL": answers(**{"320k": "ok"}),
                       "TESTNOHIRES": answers(**{"320k": rule, "128k": "ok"}),
                       "TEST128": answers(**{"128k": "ok"}), "TESTALL2": answers(**{"320k": "ok"})})
    r.quality("high")
    r.play("TESTALL")
    r.playing("TESTALL", "high", "high")
    return outgoing_id(r)


def prepared(r, old):
    starts = r.matching("prepare")
    need(len(starts) == 1 and starts[0].fields["from"] == old and starts[0].fields["to"] != old,
         "duplicate preparation or wrong outgoing/incoming identity")
    return starts[0]


def tail(r, inflight=False):
    rule = "slow:14" if inflight else "slow:8"
    old = tail_setup(r, rule)
    remaining = 6 if inflight else 67
    need(not r.requests("TESTNOHIRES") and not r.matching("prepare"), "prepared too early")
    r.seek_remaining(remaining)

    def started(s):
        need(s["mid"] == "TESTALL", "advanced before preparation began")
        return r.requests("TESTNOHIRES") and r.matching("prepare")

    s = r.until("incoming resolve while outgoing is playing", started, 16)
    left = s["seconds"] - s["progress"]
    if not inflight:
        need(55 <= left <= 62, "preparation did not start near 60 seconds remaining")
    start = prepared(r, old)
    new, token = start.fields["to"], start.fields["token"]
    say(f"WINDOW remaining_s={left:.1f}")
    if not inflight:
        def warmed(s):
            need(s["mid"] == "TESTALL" and not r.matching("eof"), "next deck not decoded/buffered before EOF")
            return (s["isPlaying"] and s["nextPreparation"] == "ready" and
                    r.matching("ready", token=token, to=new) and ("M500.mp3", "body") in r.media)
        r.until("decoded standby before EOF", warmed, 62)
        r.decoded("standard")
    # Let the real engine clock reach EOF. Another seek could invalidate a
    # prepared deck, disguise a late preparation or generate a new token.
    r.playing("TESTNOHIRES", "standard", "high", progress=1, timeout=75 if not inflight else 27)
    r.decoded("standard")
    need(r.requests("TESTNOHIRES") == [("320k", rule), ("128k", "ok")], "duplicate/missing resolve at EOF")
    need(r.media.count(("M500.mp3", "probe")) == 1, "duplicate/missing incoming verification probe")
    need(prepared(r, old) == start, "preparation was restarted")
    ends, plays = r.matching("eof", **{"from": old}), r.matching("playing", id=new)
    need(len(ends) == 1 and plays, "missing outgoing EOF or actual incoming engine playing")
    eof, play = ends[0], plays[0]
    need(r.events.index(start) < r.events.index(eof) < r.events.index(play), "wrong EOF/playing order")
    handoffs = r.matching("handoff")
    need(old != new and len(handoffs) == 1 and handoffs[0].fields["kind"] in {"standby", "source"} and
         handoffs[0].fields.items() >= {"from": old, "to": new, "token": token}.items()
         and r.events.index(eof) < r.events.index(handoffs[0]), "handoff did not consume the prepared token once")
    probes = r.verified_probe("standard", "standard")
    need(len(probes) == 1, "incoming stream was verified more than once")
    ix = r.events.index
    ready = r.matching("ready", token=token, to=new)
    if not inflight:
        # Both songs are 44.1 kHz. Exactly one deck opens after the incoming
        # M500 verdict: before ready, and no second (cold) decode at EOF.
        formats = [e for e in r.events[ix(probes[0]) + 1:] if e.name == "format"]
        need(len(ready) == len(formats) == 1 and formats[0].fields == {"rate": 44100, "channels": 2}
             and ix(start) < ix(probes[0]) < ix(formats[0]) < ix(ready[0]) < ix(eof)
             and handoffs[0].fields["kind"] == "standby", "standby was not decoded once before EOF and promoted")
        say(f"METRIC decoded_ready_before_eof_s={elapsed(ready[0], eof):.2f}")
    else:
        need(ix(eof) < ix(probes[0]) < ix(play) and not any(ix(e) < ix(eof) for e in ready),
             "incoming resolution was not in flight across the real EOF")
    gap = elapsed(eof, play)
    say(f"METRIC eof_to_engine_playing_s={gap:.2f} kind={handoffs[0].fields['kind']}")
    need(gap < 75, "engine timestamps inconsistent with the bounded observation")


def stale(r):
    # Original successor delivers 320k; manual selection delivers different
    # media, M500 at 128k. A renamed/relabelled old deck must not pass.
    old = tail_setup(r, "ok")
    r.seek_remaining(12)
    s = r.until("standby ready for the original successor", lambda s: s["mid"] == "TESTALL" and
                s["nextPreparation"] == "ready" and r.matching("ready"), 10)
    start = prepared(r, old)
    target, token = start.fields["to"], start.fields["token"]
    need(r.matching("ready", to=target, token=token) and not r.matching("eof"), "wrong standby before manual switch")
    left = s["seconds"] - s["progress"]
    need(left > 1, "manual switch missed the old EOF window")
    r.play("TEST128")  # NOT the prepared TESTNOHIRES; its own successor is TESTALL2.
    s = r.playing("TEST128", "standard", "high", progress=left + 1.5, timeout=22)
    need(s["nextPreparation"] == "idle", "selection kept the obsolete standby alive")
    r.verified_probe("standard", "standard")
    r.decoded("standard")
    r.seek_remaining(6)
    r.playing("TESTALL2", "high", "high", timeout=18)
    need(not r.matching("playing", id=target) and not r.matching("handoff", token=token),
         "stale standby played or was consumed after manual selection")


def failure(r):
    old = tail_setup(r, "reject")
    configure(r.root, {"TESTALL": answers(**{"320k": "ok"}), "TESTNOHIRES": answers(),
                       "TESTMP3": answers(**{"320k": "ok"})})
    r.seek_remaining(16)
    s = r.until("terminal background failure", lambda s: s["mid"] == "TESTALL" and s["isPlaying"] and
                s["nextPreparation"] == "failed", 10)
    token = prepared(r, old).fields["token"]
    goal = s["progress"] + 3
    def unaffected(s):
        need(s["mid"] == "TESTALL" and s["isPlaying"] and not s["isLoading"] and not s["issue"],
             "background failure interrupted or surfaced on the outgoing song")
        return s["progress"] >= goal
    r.until("outgoing decoded clock continues after failure", unaffected, 8)
    # Once there is a real EOF, an explicit failure for the target (or normal
    # advance to the following fixture) is legitimate; a second ladder is not.
    def terminal(s):
        if not r.matching("eof", **{"from": old}):
            return False
        return ((s["mid"] == "TESTNOHIRES" and not s["isLoading"] and not s["isPlaying"] and s["issue"])
                or (s["mid"] == "TESTMP3" and s["isPlaying"] and s["playing"] == "high"))
    r.until("bounded foreground outcome for failed preparation", terminal, 23)
    need(r.requests("TESTNOHIRES") == [("320k", "reject"), ("128k", "reject")] and
         not r.matching("ready", token=token) and not r.matching("handoff", token=token) and
         len(r.matching("prepare")) == 1, "failed prefetch was promoted or resolved again")


CASES = {"positive": positive, "spoof": spoof, "ladder": ladder, "tail": tail,
         "inflight": lambda r: tail(r, inflight=True), "stale": stale, "failure": failure}


def stop_fixture_app(udid):
    subprocess.run(SIMCTL + ["terminate", udid, BUNDLE], stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL, timeout=10, check=False)


def installed_fixture_entry(udid):
    # An old app ignores unknown launch arguments: the first safety check must
    # happen before launching it. Xcode may put Swift code in the debug dylib.
    lookup = subprocess.run(SIMCTL + ["get_app_container", udid, BUNDLE, "app"], capture_output=True, timeout=10)
    need(lookup.returncode == 0, "cannot verify the installed fixture-only build")
    app = Path(lookup.stdout.decode().strip()).resolve(strict=True)
    info = plistlib.loads((app / "Info.plist").read_bytes())
    need(info["CFBundleIdentifier"] == BUNDLE, "unexpected installed application")
    exe = info["CFBundleExecutable"]
    for path in (app / exe, app / f"{exe}.debug.dylib"):
        if path.is_file():
            with path.open("rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as binary:
                if binary.find(b"MeloXFixtureOnly") >= 0:
                    return
    raise Failure("installed binary lacks the fixture-only entry; refusing to launch")


@contextmanager
def cold_app(root, container, udid, port, externally_isolated):
    source = exclusive_source(container, port)
    if not externally_isolated:
        installed_fixture_entry(udid)
    run = Run(root, container / "Documents", port, source, externally_isolated)
    need(not (run.docs / "debug-command.txt").exists(), "pending command: refusing to launch")
    # Wait for the known fixture process to stop BEFORE publishing a command:
    # a previous app still polling that path must not acknowledge the new state.
    stop_fixture_app(udid)
    with regular(root / "requests.log").open("rb") as run.log:
        run.log.seek(0, 2)
        # Launch-only arguments: do not delete a snapshot, change defaults or seed.
        run.proc = subprocess.Popen(SIMCTL + ["launch", "--console", udid, BUNDLE, "-MeloXFixtureOnly", "YES",
                                    "-melox.hasCompletedOnboarding", "NO", "-checksUpdatesOnLaunch", "NO",
                                    "-usesAppleMusicQualityOptions", "NO"], stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        try:
            os.set_blocking(run.proc.stdout.fileno(), False)
            s = run.command("state", timeout=20)
            need(s["mid"] == "" and not s["isPlaying"] and s["nextPreparation"] == "idle", "not a cold fixture-only session")
            yield run
        finally:
            try:
                stop_fixture_app(udid)
            finally:
                if run.proc.poll() is None:
                    run.proc.terminate()
                run.proc.wait(timeout=8)
                run.proc.stdout.close()
                # A build without DebugAutomation might never consume our command.
                cmd = run.docs / "debug-command.txt"
                if cmd.is_file() and not cmd.is_symlink() and cmd.read_bytes() == run.sent:
                    cmd.unlink()


def main():
    class Parser(argparse.ArgumentParser):
        def error(self, message):
            # argparse otherwise echoes arbitrary input (possibly an address).
            self.exit(2, "Invalid arguments; use --help for the fixture-only invocation.\n")
    p = Parser(description="Controlled-source simulator playback acceptance (see module docstring).")
    p.add_argument("--udid", required=True, help="exact UDID of the disposable, booted simulator")
    p.add_argument("--rig-dir", type=Path, required=True, help="owned directory of the running local fixture server")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--exclusive-loopback", action="store_true", required=True,
                   help="confirm this is your exclusively assigned, local synthetic rig")
    p.add_argument("--externally-isolated", action="store_true",
                   help="only for a device with independently confirmed loopback-only egress; otherwise require fixture-only Debug")
    p.add_argument("--case", choices=["all", *CASES], default="all")
    args = p.parse_args()
    need(re.fullmatch(TOKEN, args.udid) and 1024 <= args.port <= 65535, "an exact simulator UDID and fixture port are required")
    udid, root = args.udid.upper(), args.rig_dir.resolve(strict=True)
    need(root.is_dir() and root.stat().st_uid == os.getuid(), "not an owned rig directory")
    lookup = subprocess.run(SIMCTL + ["get_app_container", udid, BUNDLE, "data"], capture_output=True, timeout=10)
    need(lookup.returncode == 0, "no installed app on the specified booted simulator")
    container = Path(lookup.stdout.decode().strip()).resolve(strict=True)
    need(udid in (part.upper() for part in container.parts) and (container / "Documents").is_dir(),
         "the app container does not belong to the specified simulator")
    exclusive_source(container, args.port)
    behaviour = regular(root / "behaviours.json")
    # Lock the directory (behaviours.json is replaced atomically, so locking that
    # inode would not protect a second runner). Never truncate either original log.
    lock = os.open(root, os.O_RDONLY)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        verify_server(root, args.port)
        original, mode = behaviour.read_bytes(), behaviour.stat().st_mode & 0o777
        try:
            for name in CASES if args.case == "all" else [args.case]:
                say(f"CASE {name}")
                with cold_app(root, container, udid, args.port, args.externally_isolated) as run:
                    say("ISOLATION " + ("externally-confirmed" if args.externally_isolated else "fixtureOnly=true"))
                    CASES[name](run)
                say(f"PASS {name}")
        finally:
            atomic(behaviour, original, mode=mode)
    finally:
        os.close(lock)


if __name__ == "__main__":
    try:
        main()
    except Failure as error:
        sys.exit(f"FAIL: {error}")
    except KeyboardInterrupt:
        sys.exit("Interrupted")
    except Exception as error:
        # Host, subprocess, HTTP and decoding errors can include secrets/paths.
        sys.exit(f"FAIL: rig I/O or protocol error ({type(error).__name__}); no raw diagnostic emitted")
