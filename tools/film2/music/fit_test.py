"""fit.py's film-2 rules on synthetic loudness profiles (no audio): python3 -I tools/film2/music/fit_test.py

A clip is built beat by beat in the film's own slots (drift 0-19, pulse 20-31, build 32-59, one silent bar 60-63, groove
64-95, the hit on 96, a short tail), placed at clip beat `o` inside a 128-beat clip. The checks:
  1. a perfect clip fits at its own `o` with every error 0 and cost 0;
  2. the same clip shifted late by 4 beats inside the clip still finds its `o` (the film's open moves, not the errors);
  3. a clip whose drift is as loud as the groove costs 6 more (to 0.2) than the sparse one (the DRIFT row; film 1's fit had none);
  4. a clip with no break (the bar is filled) costs the 8 of "no break";
  5. a drop 4 beats before the film's slot (the hit stays on 96) shows gap +4: the drop-to-hit distance is 36, not 32;
  6. a hit that is a mid-clip stop (the groove returns after it) on beat 96 is found as the END hit, e_end 0 (film 1's fit took
     the clip's last loud beat, 30 beats away);
  7. a clip with a deeper breakdown elsewhere (8 silent beats before the film) still gets its break from the dip nearest beat 60;
 10. the film is 96 beats + the 3 s tail = 102 beats at 120.001 BPM (an unrounded ceil gave 103: 6.00005 beats);
  9. a drift that is quiet (-16 dB under the groove) but as busy as the groove costs 5 more (the thin part of the DRIFT row);
  8. a drop read one beat early (a swell) on a film that opens at clip beat 0 fits at o=0 with e_drop -1, cost 2: film 1 forced
     `o` onto the drop's bar line (o = 3, e_drop -4, cost 8 and more).
FAIL-first: FIT_TEST_NEUTER=intro switches the intro penalty off (INTRO_SPARSE_DB far below any drift) and check 3 must FAIL;
FIT_TEST_NEUTER=thin switches the onset-density term off (INTRO_THIN far above any ratio) and check 9 must FAIL;
FIT_TEST_NEUTER=film1 gives fit.py film 1's reading (the drop on its bar line only, the clip's deepest dip as the break, its
last loud beat as the hit) and checks 6, 7 and 8 must FAIL.
"""
import os, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fit as F   # noqa: E402

NEUTER = os.environ.get("FIT_TEST_NEUTER", "").split(",")
if "intro" in NEUTER:
    F.INTRO_SPARSE_DB = -1e6
if "thin" in NEUTER:
    F.INTRO_THIN = 1e6
if "film1" in NEUTER:
    F.DROP_BAR_OK = (0,)
    F.dips_of = lambda db: [x for x in [F.break_of(db)] if x[1] >= F.BREAK_DEPTH_DB]
    F.hits_of = lambda db: [F.end_of(db)[0]]

NB, PERIOD = 128, 0.5


def clip(o, drift=-30.0, groove=-14.0, brk=True, drop_at=64, silent=-80.0, after=None, deep=None, rise_at=None, drift_on=16.0):
    db = [-45.0] * NB                                   # silence before and after the film
    for b in range(0, 20): db[o + b] = drift
    for b in range(20, 32): db[o + b] = drift + 4
    for b in range(32, 60): db[o + b] = (drift + groove) / 2
    for b in range(60, 64): db[o + b] = silent if brk else groove
    for b in range(64, 96): db[o + b] = groove
    db[o + 64] = groove + 2
    db[o + 96] = groove + 3                             # the hit
    for i, v in enumerate((-25.0, -35.0, -48.0, -60.0, -80.0, -80.0)): db[o + 97 + i] = v
    if drop_at != 64:                                   # the groove starts early instead
        for b in range(drop_at, 64): db[o + b] = groove
    if after is not None:                               # the groove returns this many beats after the hit
        for b in range(o + 97 + after, NB): db[b] = groove
    if deep is not None:                                # a deeper, longer breakdown at this clip beat (8 beats of silence)
        for b in range(deep, deep + 8): db[b] = -140.0
    d = o + (drop_at if rise_at is None else rise_at)
    on = [80.0] * NB                                    # onset density per beat: the groove's 80, the drift's thin 16
    for b in range(o, o + 20): on[b] = drift_on
    return {"onset_beat": on, "bpm": 120.0, "period_s": PERIOD, "first_beat_s": 0.0, "beats": NB, "loud_db": db,
            "rises": [[d, 12.0]], "drop_beat": d, "drop_jump_db": 12.0}


def row(m):
    return F.fit_clip(m)


fails = []


def check(name, ok, got):
    print(f"{'PASS' if ok else 'FAIL'}  {name}: {got}")
    if not ok:
        fails.append(name)


a = row(clip(8))
check("1 perfect clip: o=8, errors 0, cost 0", (a["open_beat"], a["e_drop"], a["e_break"], a["e_end"], a["cost"]) == (8, 0, 0, 0, 0.0),
      {k: a[k] for k in ("open_beat", "e_drop", "e_break", "e_end", "cost", "intro_db", "build_db")})
b = row(clip(12))
check("2 shifted clip: o=12, errors 0", (b["open_beat"], b["e_drop"], b["e_break"], b["e_end"]) == (12, 0, 0, 0), b["open_beat"])
c = row(clip(8, drift=-14.0))
check("3 loud drift costs 6 more", abs(c["cost"] - a["cost"] - 6.0) <= 0.2, f"cost {c['cost']} vs {a['cost']}, intro_db {c['intro_db']}")
d = row(clip(8, brk=False))
check("4 no break costs 8", abs(d["cost"] - a["cost"] - F.NO_BREAK_COST) < 1e-6, f"cost {d['cost']}")
e = row(clip(8, drop_at=60))
check("5 early drop: gap +4", e["gap"] == 4, e["gap"])
f = row(clip(8, after=8))       # the film's hit on 96, the groove back at 8 beats after: its last loud beat is at the clip's end
check("6 mid-clip stop on 96 is the END hit", f["e_end"] == 0 and f["open_beat"] == 8, (f["open_beat"], f["hit_beat"], f["e_end"]))
g = row(clip(24, deep=8))
check("7 break is the dip nearest 60, not the deepest", g["e_break"] == 0 and g["break_beat"] == 84, (g["break_beat"], g["e_break"], g["break_depth_db"]))
h = row(clip(0, rise_at=63))
check("8 drop read a beat early: o=0, e_drop -1, cost 2", h["open_beat"] == 0 and h["e_drop"] == -1 and h["cost"] == 2.0, (h["open_beat"], h["e_drop"], h["cost"]))
i = row(clip(8, drift_on=80.0))
check("9 quiet but busy drift costs 5 more", abs(i["cost"] - a["cost"] - 5.0) <= 0.2, f"cost {i['cost']} vs {a['cost']}, onsets {i['intro_onsets']}, intro_db {i['intro_db']}")
check("10 film length at 120.001 BPM is 102 beats", F.film_marks(120.001)["length"] == 102 and F.film_marks(128.0)["length"] == 96 + 7,
      (F.film_marks(120.001)["length"], F.film_marks(128.0)["length"]))
sys.exit(1 if fails else 0)
