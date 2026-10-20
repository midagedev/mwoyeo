"""The listening verdict on film 2's music candidates, by gemini-3.8-flash-high through agy (~/.claude/CLAUDE.md §1).

  python3 -I tools/film2/musicgen/listen.py --calibrate CALDIR     (cal-pos/-neg/-glitch.mp3 from music/calib.py)
  python3 -I tools/film2/musicgen/listen.py CLIP.mp3 ...           (needs music/listen/calibration.json)

rig-log release-034's listen.py, reworked for film 1's six questions and extended for film 2's seventh: whether the opening is sparse. What each call is asked, in the listener's own
terms (no file's origin, no model, no other candidate and no label are named): voice, glitches, energy 1-5, a "sparse
opening" (the first ten seconds: few quiet instruments, no full drum beat), a stop-time "break" (drums and bass out for
about two seconds or more, then the groove back) and its second, a "drop" (the music suddenly much
bigger after a build-up) and its second, and whether the last sound is one hard hit or a clean cut.
  - One call per item and per order: a clip gets two independent calls, one listing the fields in one order and one in
    the reverse order, so an answer cannot lean on the field before it. A field counts only where the two calls agree
    (booleans, glitches and energy equal; a second only when both calls say yes and name seconds within 1.0 s).
  - The calibration is three tracks with known answers (music/calib.py), built in film 2's own shape at 120 BPM: cal-pos has
    a sparse opening, a one-bar break at 30.0 s, a drop at 32.0 s, a hard end and no voice; cal-neg has none of the four and a
    voice; cal-glitch has artefacts. A field is TRUSTED for
    the clips only if both calls were right on every calibration track that has an answer for it (a second must be within
    1.5 s of the truth; a yes/no and its second are separate fields, as the first calibration showed: the ear got every
    yes/no right and named seconds that moved 15 s between the two calls). A trusted field's agreement is a verdict; an untrusted field's agreement is a screen, marked `*`
    in FIT.md and `screen_only` in the JSON. Energy has no known answer: it is always a screen.
Results are written to tools/film2/music/listen/ (calibration.json, <clip>.listen.json).
"""
import json, re, subprocess, sys
from pathlib import Path

LISTEN = Path(__file__).resolve().parent.parent / "music" / "listen"
TRUTH = Path(__file__).resolve().parent.parent / "music" / "calib.json"
FIELDS = [
    ("heard", "one sentence on what you hear"),
    ("voice", "true or false: any singing, speech or vocal sound"),
    ("glitches", '"none", "minor" or "major": clicks, dropouts, stutters or distortion that are not part of the music'),
    ("energy", "1 (very calm) to 5 (very intense)"),
    ("sparse_open", "true or false: the first ten seconds are sparse and uneasy, with only a few quiet instruments and "
                    "no full drum beat"),
    ("break", "true or false: a stretch of about two seconds or more where the drums and bass drop out, or nearly, "
              "then the full groove or a much bigger version of it comes back"),
    ("break_s", 'when that stretch starts, as "m:ss" counted from the start of the file (the first sound is 0:00), or null'),
    ("drop", "true or false: a moment after a build-up where the music suddenly becomes much bigger and fuller"),
    ("drop_s", 'when that moment comes, as "m:ss" counted from the start of the file, or null'),
    ("ending", '"hit" (the last sound is one hard hit or a clean cut) or "fade" (the music gets quieter over a few seconds '
               'or more)'),
]
BOOLS = ("voice", "sparse_open", "break", "drop")
TRUST_SECONDS, AGREE_SECONDS = 1.5, 1.0
PROMPT = """Open the audio file {path} with your audio/file reading tool and listen to all of it. Do not use shell
commands. Then answer with one JSON object and nothing else. Its fields, in this order:
{fields}"""


def prompt(path, reverse):
    fs = FIELDS[::-1] if reverse else FIELDS
    return PROMPT.format(path=path, fields="\n".join(f'- "{k}": {d}' for k, d in fs))


def ask(path, reverse):
    cmd = ["agy", "-p", prompt(path, reverse), "--model", "gemini-3.8-flash-high", "--dangerously-skip-permissions",
           "--print-timeout", "4m", "--output-format", "json"]
    last = ""
    for _ in range(2):      # one retry: agy exits 0 on a failed turn, so the result event's status is read
        try:
            r = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=300)
            ev = json.loads(r.stdout.strip().splitlines()[-1])
            if str(ev.get("status")).upper() != "SUCCESS":
                last = f"status {ev.get('status')!r}"
                continue
            m = re.search(r"\{.*\}", ev.get("response") or "", re.S)
            if not m:
                last = f"no JSON in {(ev.get('response') or '')[:200]!r}"
                continue
            a = json.loads(m.group(0))
            if not (all(isinstance(a.get(k), bool) for k in BOOLS) and a.get("glitches") in ("none", "minor", "major")
                    and a.get("energy") in (1, 2, 3, 4, 5) and a.get("ending") in ("hit", "fade")):
                last = f"an answer outside its fields: {a}"
                continue
            return a
        except (subprocess.TimeoutExpired, IndexError, json.JSONDecodeError) as e:
            last = repr(e)
    return {"error": f"{path.name}: {last}"}


def secs(x):
    """A second from a number or an "m:ss" string; None if it is neither."""
    if isinstance(x, (int, float)) and not isinstance(x, bool):
        return float(x)
    m = re.fullmatch(r"\s*(\d+):(\d{1,2}(?:\.\d+)?)\s*", x) if isinstance(x, str) else None
    return int(m.group(1)) * 60 + float(m.group(2)) if m else None


def agree(a, b):
    """The fields on which two calls agree (see the header)."""
    if "error" in a or "error" in b:
        return {}
    out = {k: a[k] for k in BOOLS + ("glitches", "energy") if a[k] == b[k]}
    if a["ending"] == b["ending"]:
        out["hard_end"] = a["ending"] == "hit"
    for flag, sec in (("break", "break_s"), ("drop", "drop_s")):
        x, y = secs(a.get(sec)), secs(b.get(sec))
        if a[flag] and b[flag] and x is not None and y is not None and abs(x - y) <= AGREE_SECONDS:
            out[sec] = round((x + y) / 2, 2)
    return out


def judge(path):
    path = Path(path).resolve()
    a, b = ask(path, False), ask(path, True)
    return {"file": str(path), "calls": [a, b], "orders": ["fields in order", "fields reversed"], "agreed": agree(a, b)}


def check(j, truth):
    """Per field: was the agreed answer right on this track? None where the track has no truth for it."""
    ag, out = j["agreed"], {}
    for k in BOOLS + ("hard_end",):
        out[k] = ag.get(k) == truth[k] if k in truth else None
    for flag, sec in (("break", "break_s"), ("drop", "drop_s")):
        if truth.get(sec) is not None:
            out[sec] = sec in ag and abs(ag[sec] - truth[sec]) <= TRUST_SECONDS
    if "glitches" in truth:
        out["glitches"] = ag.get("glitches") in truth["glitches"]
    return out


def calibrate(caldir):
    truth = json.loads(TRUTH.read_text())
    LISTEN.mkdir(parents=True, exist_ok=True)
    judged, ok = {}, {}
    for name, t in truth.items():
        j = judge(Path(caldir) / name)
        r = check(j, t)
        judged[name] = j | {"right": r}
        for k, v in r.items():
            if v is not None:
                ok[k] = ok.get(k, True) and v
        (LISTEN / f"{Path(name).stem}.listen.json").write_text(json.dumps(judged[name], indent=1) + "\n")
        print(f"{name}: agreed {j['agreed']}  right {r}", flush=True)
    trusted = {k: ok.get(k, False) for k in ("voice", "glitches", "sparse_open", "break", "break_s", "drop", "drop_s", "hard_end")}
    trusted["energy"] = False
    failed = [k for k, v in trusted.items() if k != "energy" and not v]
    summary = "FAILED on " + ", ".join(failed) if failed else "passed on every field but energy (no known answer)"
    (LISTEN / "calibration.json").write_text(json.dumps({"trusted": trusted, "per_field": ok, "summary": summary}, indent=1) + "\n")
    print("calibration:", summary, trusted, flush=True)


def main():
    a = sys.argv[1:]
    if a[:1] == ["--calibrate"] and len(a) == 2:
        return calibrate(a[1])
    if not a or a[0].startswith("-"):
        sys.exit(__doc__)
    cal = LISTEN / "calibration.json"
    if not cal.exists():
        sys.exit("listen.py: no calibration.json; run --calibrate first (a clip's fields are a verdict only where it passed)")
    trusted = json.loads(cal.read_text())["trusted"]
    for p in a:
        j = judge(p)
        j["trusted"] = trusted
        j["screen_only"] = sorted(k for k in j["agreed"] if not trusted.get(k, False))
        (LISTEN / f"{Path(p).stem}.listen.json").write_text(json.dumps(j, indent=1) + "\n")
        print(f"{Path(p).name}: {j['agreed']}  screen-only: {j['screen_only']}", flush=True)


if __name__ == "__main__":
    main()
