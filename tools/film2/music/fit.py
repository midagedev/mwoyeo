"""Fit every measured clip to film 2's hit table and rank them -> FIT.md and fit.json.

  python3 -I tools/film2/music/fit.py RAWDIR            (after measure.sh: RAWDIR/screen.tsv, music/beats.json)

Film 2 is a fixed run of beats at 120 BPM (2 s a bar); at the clip's measured BPM the beats stay and the seconds scale.
The table (tools/film2/music/FIT.md header, the lead's spec-music.md) asks the music for:
  DRIFT   beats 0-19   sparse and uneasy: no full drums, low energy
  LOG     beats 20-31  a pulse enters
  CLAUDE  beats 32-59  a steady build, kick by beat 48
  BREAK   beats 60-63  one bar of near silence (stop-time)
  DROP    beat 64      the biggest moment, then the groove holds to beat 95
  END     beat 96      one hard final hit, a tail of at most 3 s
The clip is longer than the film (64 s against ~49 s), so the one free choice is where the film opens, OPEN_AT_BEAT `o` (an
integer clip beat). For each clip the fit tries every `o` that keeps the whole film (96 beats + the tail) inside the clip, for
each of the clip's four strongest loudness rises read as "the drop" (the largest rise is often the groove coming back after
the break, not the final drop: film 1's calib.py track shows it), and keeps the `o` with the smallest cost. The drop's beat
is read from a loudness rise, which can sit a beat off the bar line (a swell just before it), so e_drop of 0, +-1 or +-4 is
allowed and +-2 is not (film 1 forced `o` to the drop's bar line and paid a bar for a one-beat misreading). For that `o` the
break is the dip (one or two bars, >= 6 dB down) whose start is nearest beat 60 and the hit the END hit candidate nearest
beat 96 (film 1 read only the clip's deepest dip and its last loud beat):
    cost = 2 |e_drop| + min(|e_break|, 8) + |e_end| (8 = no break either; x2 on e_end < 0; + 2 for a soft ending)
           + intro_pen
with errors in beats, clip minus film (+ means the clip's event is later than the film's slot):
    e_drop  = the rise's beat - (o + 64)
    e_break = the break's first beat - (o + 60)
    e_end   = the hit beat - (o + 96)
and intro_pen the DRIFT row, which film 1 did not have, in two parts that add. Quiet: intro_db = the mean power (dB) of beats
o..o+19 minus that of the groove at o+64..o+83; quiet_pen = clamp(intro_db + 6, 0, 8), so a drift at least 6 dB under the groove
costs 0 and one as loud as the groove costs 6. Thin: intro_onsets = the mean onset density (beats.py `onset_beat`) of the same
beats over the groove's; thin_pen = clamp((intro_onsets - 0.5) * 10, 0, 8), so a drift with half the groove's onsets costs 0
and one as busy as the groove costs 5. Run 1 of film 2 needed the second part: its best fit, synthwave-s1001, is 14 dB under
its groove but as busy (0.94), and the listening heard no sparse opening there (both calls, a calibrated field).
`build_db` (beats o+32..o+59 minus the drift) is printed, not costed.
The last column repeats the search without the END terms (the hit and its soft-ending cost): a hard final hit can be made by
an edit (cut at beat 96, add an impact) in any clip, while the drift, the break and the drop are the material.
What the events are, from the loudness per beat (RMS dB, beats.py `loud_db`):
  break  a dip, one bar or two (dips_of): a bar of near silence before a build, or a two-bar hole, below its neighbours in
         mean power by 6 dB or more; a clip with no such dip has no break (its row shows the deepest, break_of, marked none).
  hit    hits_of: the last loud beat (within 8 dB of the clip's 90th percentile) of a stretch whose tail is 10 dB or more down
         two to four beats later, or the clip's last loud beat. `end` is screen.py's sound end, the last beat above -40 dB; the
         clip's own last hit with more than 3 beats between it and `end` is a fade, not a hard end (+2).
`gap` is the clip's drop-to-hit distance minus the film's (DROP b64 to END b96, 32 beats): the beats a cut of whole bars
from the loud middle would have to remove (+) or the END would have to stretch (-); the fit does not assume it.
Ranked: clips that passed screen.py first (its pulse test), then by cost. Writes FIT.md (with PICK.md appended if it
exists, and the listening table if music/listen/ holds the JSONs) and fit.json beside this script.
"""
import json, os, sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent

BREAK_DEPTH_DB, NO_BREAK_COST, SOFT_END_COST, LOUD_DB, TAIL_BEATS = 6.0, 8, 2, -40.0, 3
INTRO_SPARSE_DB, INTRO_THIN, TAIL_S = 6.0, 0.5, 3.0
DROP_BAR_OK = (0, 1, 3)       # e_drop mod 4 the fit allows: on the bar line or a beat off it (see the header)
# film 2's table, in beats from the film's first beat (every opener is a multiple of 4: the bar lines `o` shares)
DRIFT, LOG, CLAUDE, BREAK, DROP, PROOF_TAIL, END = 0, 20, 32, 60, 64, 84, 96


def film_marks(bpm):
    marks = {"break": BREAK, "drop": DROP, "end_hit": END, "length": END + int(np.ceil(round(TAIL_S * bpm / 60, 3)))}     # rounded: 3 s at 120.001 BPM is 6 beats, not 7
    assert all(v % 4 == 0 for v in (DRIFT, LOG, CLAUDE, BREAK, DROP, PROOF_TAIL, END)), marks
    return marks


def power_db(db, a, b):
    p = 10 ** (np.asarray(db[a:b]) / 10)
    return float(10 * np.log10(p.mean() + 1e-12))


def intro_of(db, onset, o):
    """(intro_db, build_db, intro_onsets): the DRIFT's mean power under the groove's, the build's over the drift's, and the
    DRIFT's onset density over the groove's."""
    drift, groove = power_db(db, o + DRIFT, o + LOG), power_db(db, o + DROP, o + PROOF_TAIL)
    thin = float(np.mean(onset[o + DRIFT:o + LOG]) / (np.mean(onset[o + DROP:o + PROOF_TAIL]) + 1e-9))
    return round(drift - groove, 1), round(power_db(db, o + CLAUDE, o + BREAK) - drift, 1), round(thin, 2)


def _dips(db):
    """(depth dB, first beat, beats) of every one-bar (4 beats) and two-bar (8 beats) dip, in power: a bar against the 4 beats
    before it and the louder of the 2 bars after it (bar 1 near silent, bar 2 a build), or two bars against the 4 beats on each
    side (the lower)."""
    p = 10 ** (np.asarray(db) / 10)
    mean = lambda a, b: 10 * np.log10(p[a:b].mean() + 1e-12)
    out = []
    for k in range(4, len(db) - 12):
        for n, side in ((4, min(mean(k - 4, k), max(mean(k + 4, k + 8), mean(k + 8, k + 12)))),
                        (8, min(mean(k - 4, k), mean(k + 8, k + 12)))):
            out.append((float(side - mean(k, k + n)), k, n))
    return out


def break_of(db):
    """(first beat, depth dB, beats) of the deepest dip (see _dips): what a row shows when the clip has no dip of BREAK_DEPTH_DB."""
    depth, k, n = max(_dips(db))
    return k, round(depth, 1), n


def dips_of(db):
    """Every dip of at least BREAK_DEPTH_DB as (first beat, depth dB, beats), deepest first; of dips whose starts lie within 8
    beats only the deepest. Film 1's fit read only the deepest dip of the clip; film 2 has one slot (beats 60-63) and the fit
    takes the dip nearest it, so a deeper breakdown elsewhere (a clip's long middle one) does not hide the stop-time bar."""
    out = []
    for depth, k, n in sorted(_dips(db), reverse=True):
        if depth < BREAK_DEPTH_DB:
            break
        if all(abs(k - k2) >= 8 for k2, _, _ in out):
            out.append((k, round(depth, 1), n))
    return out


def end_of(db):
    """(last loud beat, sound end beat): see the header."""
    db = np.asarray(db)
    ref = np.percentile(db, 90)
    hit = int(np.where(db >= ref - 8)[0][-1])
    loud = np.where(db > LOUD_DB)[0]
    return hit, int(loud[-1]) if len(loud) else 0


def hits_of(db):
    """Every beat that can be the END hit: the last loud beat of a stretch (within 8 dB of the clip's 90th percentile, the next
    beat below it) whose tail is 10 dB or more down two to four beats later; the film is cut ~3 s after its hit, so what the clip
    does after that tail does not matter. The clip's last loud beat is always one (its tail is the clip's end)."""
    db = np.asarray(db)
    ref = np.percentile(db, 90)
    out = [h for h in range(len(db) - 5) if db[h] >= ref - 8 and db[h + 1] < ref - 8 and db[h + 2:h + 5].max() <= db[h] - 10]
    last = end_of(db)[0]
    return out if last in out else out + [last]


def fit_clip(m):
    db, nb = m["loud_db"], m["beats"]
    marks = film_marks(m["bpm"])
    deepest = break_of(db)
    dips, hits = dips_of(db), hits_of(db)
    last, end = end_of(db)
    best, noend = None, None
    for d, jump in m["rises"][:4]:
        if jump < 3.0:
            continue
        for o in range(0, nb - marks["length"] + 1):
            e_drop = d - (o + marks["drop"])
            if e_drop % 4 not in DROP_BAR_OK:        # the rise may sit a beat off the bar line (a swell before it), not two
                continue
            brk = min(dips, key=lambda x: (abs(x[0] - (o + marks["break"])), -x[1]), default=None)
            e_break = None if brk is None else brk[0] - (o + marks["break"])
            hit = min(hits, key=lambda h: abs(h - (o + marks["end_hit"])) * (2 if h < o + marks["end_hit"] else 1))
            e_end = hit - (o + marks["end_hit"])
            soft = hit == last and end - hit > TAIL_BEATS
            intro_db, build_db, thin = intro_of(db, m["onset_beat"], o)
            intro_pen = (round(min(8.0, max(0.0, intro_db + INTRO_SPARSE_DB)), 1)
                         + round(min(8.0, max(0.0, (thin - INTRO_THIN) * 10)), 1))
            cost = (2 * abs(e_drop) + (NO_BREAK_COST if brk is None else min(abs(e_break), NO_BREAK_COST))
                    + abs(e_end) * (2 if e_end < 0 else 1) + (SOFT_END_COST if soft else 0) + intro_pen)
            cost = round(cost, 1)
            # the same without the END terms: a hard final hit is an edit away (cut at beat 96, add an impact), the drift,
            # the break and the drop are the material
            c0 = round(2 * abs(e_drop) + (NO_BREAK_COST if brk is None else min(abs(e_break), NO_BREAK_COST)) + intro_pen, 1)
            if noend is None or c0 < noend["cost_noend"]:
                noend = {"cost_noend": c0, "open_noend": o, "e_drop_noend": e_drop, "e_break_noend": e_break}
            if best is None or cost < best["cost"]:
                k, depth, blen = brk or deepest
                best = {"cost": cost, "open_beat": o, "open_s": round(m["first_beat_s"] + o * m["period_s"], 2),
                        "drop_beat": d, "drop_jump_db": jump, "e_drop": e_drop, "break_beat": k, "break_depth_db": depth,
                        "break_beats": blen, "e_break": e_break, "hit_beat": hit, "end_beat": end, "e_end": e_end,
                        "soft_end": soft, "gap": (hit - d) - (marks["end_hit"] - marks["drop"]),
                        "intro_db": intro_db, "build_db": build_db, "intro_onsets": thin}
    if best is None:     # no usable rise, or the film does not fit the clip
        best = {"cost": 99, "open_beat": None, "open_s": None, "drop_beat": m["drop_beat"], "drop_jump_db": m["drop_jump_db"],
                "e_drop": None, "break_beat": deepest[0], "break_depth_db": deepest[1], "break_beats": deepest[2], "e_break": None,
                "hit_beat": last, "end_beat": end, "e_end": None, "soft_end": end - last > TAIL_BEATS, "gap": None,
                "intro_db": None, "build_db": None, "intro_onsets": None}
    return best | (noend or {"cost_noend": None, "open_noend": None, "e_drop_noend": None, "e_break_noend": None}) | {"bpm": m["bpm"], "first_beat_s": m["first_beat_s"], "period_s": m["period_s"], "beats": nb,
                   "film_beats": marks["length"], "film_s": round(marks["length"] * m["period_s"], 2)}


def fdb(v):
    return "-" if v is None else f"{v:+.1f}"


def noend_cell(r):
    if r["open_noend"] is None:
        return "-"
    return f"{r['open_noend']}, {sgn(r['e_drop_noend'])}, {sgn(r['e_break_noend'])}, {r['cost_noend']}"


def sgn(e):
    return "-" if e is None else f"{e:+d}"


def read_screen(raw):
    out = {}
    for line in (raw / "screen.tsv").read_text().splitlines()[1:]:
        c = line.split("\t")
        out[c[0]] = {"pulse": c[3], "pass": c[9] == "pass", "sound_end_s": c[7]}
    return out


def listen_table(rows):
    """The listening table from music/listen/*.listen.json (listen.py writes them)."""
    d = HERE / "listen"
    files = sorted(d.glob("*.listen.json")) if d.exists() else []
    cal = {}
    if (d / "calibration.json").exists():
        cal = json.loads((d / "calibration.json").read_text())
    if not [f for f in files if not f.name.startswith("cal-")]:
        return []
    out = ["", "## Listening (agy gemini-3.8-flash-high, two calls a clip, a field counts where both calls agree)", ""]
    if cal:
        out.append(f"Calibration (three known-truth tracks, calib.py; listen/calibration.json): {cal.get('summary', '?')}. "
                   "Trusted: " + ", ".join(k for k, v in cal.get("trusted", {}).items() if v) + ".")
        out.append("")
    out += ["| clip | voice | glitches | energy | sparse open | break (heard s / measured s) | drop (heard s / measured s) | hard end |",
            "|---|---|---|---|---|---|---|---|"]
    by = {r["clip"]: r for r in rows}
    for f in files:
        if f.name.startswith("cal-"):
            continue
        j = json.loads(f.read_text())
        a, clip = j["agreed"], Path(j["file"]).stem
        tag = {k: ("" if j["trusted"].get(k) else "*") for k in ("voice", "glitches", "energy", "sparse_open", "break", "break_s", "drop", "drop_s", "hard_end")}
        r = by.get(clip)
        mb = f"{r['first_beat_s'] + r['break_beat'] * r['period_s']:.1f}" if r else "?"
        md = f"{r['first_beat_s'] + r['drop_beat'] * r['period_s']:.1f}" if r else "?"
        out.append(f"| {clip} | {a.get('voice', '?')}{tag['voice']} | {a.get('glitches', '?')}{tag['glitches']} | "
                   f"{a.get('energy', '?')}{tag['energy']} | {a.get('sparse_open', '?')}{tag['sparse_open']} | {a.get('break', '?')}{tag['break']} "
                   f"({a.get('break_s', '-')}{tag['break_s']} / {mb}) | {a.get('drop', '?')}{tag['drop']} ({a.get('drop_s', '-')}{tag['drop_s']} / {md}) | "
                   f"{a.get('hard_end', '?')}{tag['hard_end']} |")
    out += ["", "`?` = the two calls disagreed. `*` = the calibration did not pass for that field, so the cell is a screen, "
            "not a verdict.", ""]
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    raw = Path(sys.argv[1])
    beats = json.loads(Path(os.environ.get("FIT_BEATS", HERE / "beats.json")).read_text())
    out = Path(os.environ.get("FIT_OUT", HERE))          # a test run points both at a scratch dir
    screen = read_screen(raw)
    rows = []
    for clip, m in beats.items():
        if clip not in screen:
            continue
        rows.append({"clip": clip, "screen": screen[clip]["pass"], "pulse": screen[clip]["pulse"]} | fit_clip(m))
    rows.sort(key=lambda r: (not r["screen"], r["cost"], r["clip"]))
    (out / "fit.json").write_text(json.dumps(rows, indent=1) + "\n")
    md = ["# FIT: film 2's music candidates against the hit table", "",
          "Source: `fit.py` over `beats.json` (beats.py, BEATS_DROP_WIN=8) and screen.py's `screen.tsv`; the rules are in "
          "fit.py's header. Errors are in beats, clip minus film: `+` = the clip's event is later than the film's slot, "
          "`-` = earlier. Film 2's table is in beats (drop 64, break 60-63, hit 96) and keeps its beats at each clip's measured BPM; OPEN_AT_BEAT `o` is the "
          "clip beat the film opens on, on a bar line. `drift` = the opening's power under the groove's, dB (more negative = quieter), and `onsets` = its onset density over the groove's (lower = thinner); "
          "`build` = the build's power over the opening's.", "",
          "| # | clip | BPM | 1st beat s | screen | open `o` (s) | drop: beat, +dB, err | break: beat, depth dB, err | "
          "hit / sound end, err | drop-to-hit gap | drift dB / onsets / build dB | cost | without END: `o`, drop, break, cost |", "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for i, r in enumerate(rows, 1):
        o = "-" if r["open_beat"] is None else f"{r['open_beat']} ({r['open_s']})"
        brk = f"{r['break_beat']} ({r['break_beats']} beats), {r['break_depth_db']}, {sgn(r['e_break'])}" + ("" if r["e_break"] is not None else " (none)")
        md.append(f"| {i} | {r['clip']} | {r['bpm']} | {r['first_beat_s']} | {'pass' if r['screen'] else 'fail'} {r['pulse']} | "
                  f"{o} | {r['drop_beat']}, {r['drop_jump_db']}, {sgn(r['e_drop'])} | {brk} | "
                  f"{r['hit_beat']} / {r['end_beat']}{' fade' if r['soft_end'] else ''}, {sgn(r['e_end'])} | {sgn(r['gap'])} | {fdb(r['intro_db'])} / {r['intro_onsets'] if r['intro_onsets'] is not None else '-'} / {fdb(r['build_db'])} | {r['cost']} | {noend_cell(r)} |")
    md += listen_table(rows)
    if (HERE / "PICK.md").exists():
        md += ["", (HERE / "PICK.md").read_text().rstrip(), ""]
    (out / "FIT.md").write_text("\n".join(md) + "\n")
    for r in rows[:6]:
        print(f"{r['clip']:>12} {r['bpm']:7.2f} {'pass' if r['screen'] else 'FAIL'} o={r['open_beat']} drop {r['drop_beat']} "
              f"({sgn(r['e_drop'])}) break {r['break_beat']}/{r['break_depth_db']} dB ({sgn(r['e_break'])}) "
              f"end {r['hit_beat']}/{r['end_beat']} ({sgn(r['e_end'])}) drift {fdb(r['intro_db'])} dB, onsets x{r['intro_onsets']} cost {r['cost']}")


if __name__ == "__main__":
    main()
