#!/usr/bin/env python3
"""The player's local server for a live recording: serves tools/ (the stage pages and the sequence) to the Chrome window, keeps what
the player reports, and paces the lines by what the lens does. Run it isolated:
  python3 -I serve.py --root <repo>/tools --port <n> --events <file.jsonl> --go <flag file> [--lens-feed <fifo> --transcripts <dir>]

  GET /go             204 until the <flag file> exists, then 200: the player waits for it before the lead-in, so the recording is
                      already running when the first line shows (record.sh creates the file once ffmpeg writes frames).
  GET /ev?k=<kind>&…  one JSON line in <file.jsonl>: {"t": <epoch s at receipt>, <the query's fields>}. Kinds the player sends: `rect`
                      (where its stage sits on screen, in points), `line` (line <id> is now on screen; `ms` = the page's epoch ms of the
                      swap), `end` (the take is over: record.sh stops ffmpeg, then this server).
  GET /next?id=<id>   200 once line <id> may go: the app's log (--transcripts) read it and the lens's inside has not changed for
                      --hold s since and --after s have passed since the log read it, or --most s since the swap; else 204 (Pace). The first 200 of a line is written
                      as a `ready` event (why: settled or most; logged, translated (the log's time), settled: s after the swap).
  anything else       a file under --root, never cached.
--lens-feed is a FIFO that record.sh's ffmpeg writes the lens's inside to (grey, 30 fps as settle.py reads it; its size in <fifo>.size as "w h"), read from
the start so the recording never waits on it. Without the feed and the log, /next answers by --most alone.
FAILURE MODES IT BLOCKS: a recording whose line times are guessed from a schedule (count-live.py and settle.py read the times the page
reported); a line that goes before the lens translated it, or while it is still rewriting it (an engine slowed by the machine's load
only makes the take longer)."""
import argparse
import functools
import glob
import http.server
import json
import os
import sys
import threading
import time
import urllib.parse

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import logmatch  # noqa: E402


class Pace:
    """Whether the line on screen may go: the app's log read it (logmatch: its entries cover --cover of the line's text) and the lens's
    inside has not changed for --hold s since, or --most s passed. The log is the word on what the lens translated (the lens keeps its
    last picture over a changed box until it reads again, so a change on screen is not yet a translation of the line on screen).
    With --memory, the first line waits for the memory: it stays until the settings file holds a profile for --bundle (Claude's
    set_memory; the app applies it within a second), then --redraw s more for the lens to translate it again with the memory; from then
    on only what the log wrote after the memory landed counts."""

    def __init__(self, opts, clock=time.time):
        self.opts, self.lock, self.ready, self.clock = opts, threading.Lock(), set(), clock
        self.texts, self.speakers = logmatch.load(opts.sequence)
        self.entries = []                       # (arrival, original, log time)
        self.line, self.swap, self.prev, self.changed, self.covered, self.step = None, 0.0, None, 0.0, None, 0
        self.waits = bool(getattr(opts, "memory", None))
        self.landed = None                      # when the memory was seen in the settings file

    def swapped(self, lid):
        with self.lock:
            self.line, self.swap, self.changed, self.covered = lid, self.clock(), self.clock(), None
            self.step += 1
            self._cover()

    def frame(self, f):
        with self.lock:
            if self.prev is not None and float(np.abs(f - self.prev).mean()) > self.opts.still:
                self.changed = self.clock()
            self.prev = f

    def logged(self, original, at):
        with self.lock:
            self.entries.append((self.clock(), original, at))
            self._cover()

    def memory(self):
        with self.lock:
            if self.landed is None:
                self.landed = self.clock()
                self.covered = None
                self._cover()
                return True
            return False

    def _cover(self):
        text = self.texts.get(self.line)
        if self.waits and self.landed is None:
            return
        seen = [e for e in self.entries if not self.waits or e[0] >= self.landed]
        if self.covered is None and text and logmatch.coverage([e[1] for e in seen], text, self.speakers) >= self.opts.cover:
            self.covered = (self.clock(), max((e[2] for e in seen if e[2] and logmatch.read_of(e[1], text)), default=None))

    def may_go(self, lid):
        """None while line <lid> should stay; else the `ready` event (once a showing) or {} (asked again)."""
        now = self.clock()
        with self.lock:
            if lid != self.line:
                return None
            if self.waits and self.step == 1:   # the line before the memory: it goes once the lens had time to redo it
                if self.landed is None or now - self.landed < self.opts.redraw or now - self.changed < self.opts.hold:
                    return None
                settled = True
            else:
                # The lens can still change as the log writes (frames reach the feed a few tenths late): --after s past the log's word.
                settled = self.covered is not None and now - self.changed >= self.opts.hold and now - self.covered[0] >= self.opts.after
                if not settled and now - self.swap < self.opts.most:
                    return None
            if self.step in self.ready:
                return {}
            self.ready.add(self.step)
            at = lambda t: None if t is None else round(t - self.swap, 2)
            return {"k": "ready", "id": lid, "why": "settled" if settled else "most", "logged": at(self.covered and self.covered[0]),
                    "translated": at(self.covered and self.covered[1]), "settled": at(self.changed), "memory": at(self.landed)}


def watch_memory(path, bundle, pace, note):
    """The settings file until it holds a profile for <bundle> with a memory (note or entries)."""
    while True:
        try:
            s = json.load(open(path, encoding="utf-8"))
            for p in s.get("appProfiles") or []:
                mem = p.get("memory") or {}
                if p.get("bundleID") == bundle and (mem.get("note") or mem.get("entries") or p.get("note") or p.get("entries")):
                    if pace.memory():
                        note({"k": "memory", "bundle": bundle, "entries": len(mem.get("entries") or p.get("entries") or [])})
                    return
        except (OSError, ValueError):
            pass
        time.sleep(0.25)


def feed(path, pace):
    with open(path, "rb") as fifo:              # blocks until ffmpeg opens it for writing
        w, h = (int(v) for v in open(path + ".size").read().split())
        n = w * h
        while True:
            buf = fifo.read(n)
            if len(buf) < n:
                return
            pace.frame(np.frombuffer(buf, dtype=np.uint8).astype(np.int16))


def tail(folder, pace):
    """The app's jsonl logs in <folder> as they grow (the app makes the folder and file once the lens first writes)."""
    pos, rest = {}, {}
    while True:
        for name in sorted(glob.glob(os.path.join(folder, "*.jsonl"))):
            with open(name, "rb") as f:
                f.seek(pos.get(name, 0))
                data = rest.get(name, b"") + f.read()
                pos[name] = f.tell()
            *lines, rest[name] = data.split(b"\n")
            for line in lines:
                if line.strip():
                    e = json.loads(line)
                    pace.logged(e.get("original", ""), logmatch.epoch(e["time"]) if e.get("time") else None)
        time.sleep(0.25)


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, opts=None, pace=None, **kw):
        self.opts, self.pace = opts, pace
        super().__init__(*a, directory=opts.root, **kw)

    def log_message(self, *a):
        pass

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def note(self, fields):
        with open(self.opts.events, "a", encoding="utf-8") as f:
            f.write(json.dumps({"t": round(time.time(), 3), **fields}, ensure_ascii=False) + "\n")

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        q = {k: v[-1] for k, v in urllib.parse.parse_qs(url.query).items()}
        if url.path == "/go":
            self.send_response(200 if os.path.exists(self.opts.go) else 204)
            self.end_headers()
            return
        if url.path == "/ev":
            self.note(q)
            if q.get("k") == "line":
                self.pace.swapped(int(q.get("id", 0)))
            self.send_response(204)
            self.end_headers()
            return
        if url.path == "/next":
            ready = self.pace.may_go(int(q.get("id", 0)))
            if ready:
                self.note(ready)
            self.send_response(204 if ready is None else 200)
            self.end_headers()
            return
        super().do_GET()


def self_test(opts):
    """The pacing on made-up frames, log entries and clock (no screen, no app, no waiting). Lines 1, 4, 3 and 2 of the sequence:
    drawn at 6 s, logged at 9 s -> goes at 10 s (after); the lens clears a stale picture at 3.5 s, draws at 8.5 s, logged at 9 s ->
    10.5 s (hold); never logged -> 30 s (most); logged in two halves (5 s, 12 s), drawn again at 11 s -> 13 s. Prints the cases; exit 1
    when one is off. FAIL-first: `--self-test --cover 0` (a line counts as read with nothing logged), `--hold 0`, `--after 0` fail."""
    now = [0.0]
    pace = Pace(opts, clock=lambda: now[0])
    t = pace.texts
    half = len(t[4]) // 2
    a, b = (np.full(64, v, dtype=np.int16) for v in (10, 200))
    def run(lid, changes, logs):
        pace.swapped(lid)
        shown = a
        for k in range(int(opts.most * 10) + 20):
            now[0] += 0.1
            at = round(k / 10.0, 1)
            if at in changes:
                shown = b if shown is a else a
            pace.frame(shown)
            for when, original in logs:
                if at == when:
                    pace.logged(original, now[0] - 3)
            r = pace.may_go(lid)
            if r:
                return at, r["why"]
        return None
    got = [run(1, {0.6, 6.0}, [(9.0, t[1])]),
           run(3, {0.6, 3.5, 8.5}, [(9.0, t[3])]),
           run(2, {0.6}, []),
           run(4, {0.6, 2.0, 11.0}, [(5.0, t[4][:half]), (12.0, t[4][half:])])]
    want = [(10.0, "settled"), (10.5, "settled"), (30.0, "most"), (13.0, "settled")]      # the defaults: --hold 2, --after 1, --most 30
    # With the memory: L2 waits for it (landed at 20 s, redrawn at 25 s -> goes at 32 s); L7 was logged before the memory (that does
    # not count) and again at 8 s -> goes at 9 s.
    import copy
    mo = copy.copy(opts)
    mo.memory = "settings.json"
    pace = Pace(mo, clock=lambda: now[0])
    pace.logged(t[7], None)
    def landing(lid, changes, logs, land):
        pace.swapped(lid)
        shown = a
        for k in range(int(60 * 10)):
            now[0] += 0.1
            at = round(k / 10.0, 1)
            if at in changes:
                shown = b if shown is a else a
            pace.frame(shown)
            if at == land:
                pace.memory()
            for when, original in logs:
                if at == when:
                    pace.logged(original, now[0] - 3)
            r = pace.may_go(lid)
            if r:
                return at, r["why"]
        return None
    got += [landing(2, {0.6, 25.0}, [], 20.0), landing(7, {0.6}, [(8.0, t[7])], None)]
    want += [(32.0, "settled"), (9.0, "settled")]                                          # --redraw 12
    ok = all(g is not None and g[1] == w[1] and abs(g[0] - w[0]) <= 0.2 for g, w in zip(got, want))
    print("pace self-test (hold %.1f s): %s; want %s: %s" % (opts.hold, got, want, "PASS" if ok else "FAIL"))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--events", required=True)
    ap.add_argument("--go", required=True)
    ap.add_argument("--lens-feed", help="FIFO of the lens's inside, grey frames (size in <fifo>.size)")
    ap.add_argument("--transcripts", help="the folder of the app's jsonl translation logs of this run")
    ap.add_argument("--sequence", default=logmatch.SEQUENCE, help="the sequence the stage shows (line texts)")
    ap.add_argument("--cover", type=float, default=logmatch.COVER, help="share of a line's text the log must have read")
    ap.add_argument("--hold", type=float, default=2.0, help="seconds the lens must stay unchanged once the log read the line")
    ap.add_argument("--most", type=float, default=30.0, help="seconds a line stays at most")
    ap.add_argument("--after", type=float, default=1.0, help="seconds past the log's reading of the line before it may go")
    ap.add_argument("--memory", help="the live app's settings file: the first line waits for a memory in it (Claude's set_memory)")
    ap.add_argument("--bundle", default="com.google.Chrome", help="the app whose profile carries the memory")
    ap.add_argument("--redraw", type=float, default=12.0, help="seconds the first line stays after the memory landed")
    ap.add_argument("--still", type=float, default=0.8, help="mean grey-level change of a frame that counts as a change")
    ap.add_argument("--self-test", action="store_true", help="check the pacing on made-up frames and exit")
    if "--self-test" in sys.argv:
        opts = ap.parse_known_args(["--root", ".", "--port", "0", "--events", "-", "--go", "-"] + sys.argv[1:])[0]
        return self_test(opts)
    opts = ap.parse_args()
    opts.root = os.path.abspath(opts.root)
    pace = Pace(opts)
    if opts.lens_feed:
        threading.Thread(target=feed, args=(opts.lens_feed, pace), daemon=True).start()
    if opts.transcripts:
        threading.Thread(target=tail, args=(opts.transcripts, pace), daemon=True).start()
    if opts.memory:
        def note(fields):
            with open(opts.events, "a", encoding="utf-8") as f:
                f.write(json.dumps({"t": round(time.time(), 3), **fields}, ensure_ascii=False) + "\n")
        threading.Thread(target=watch_memory, args=(opts.memory, opts.bundle, pace, note), daemon=True).start()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", opts.port), functools.partial(Handler, opts=opts, pace=pace))
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
