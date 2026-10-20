# FIT: film 2's music candidates against the hit table

Source: `fit.py` over `beats.json` (beats.py, BEATS_DROP_WIN=8) and screen.py's `screen.tsv`; the rules are in fit.py's header. Errors are in beats, clip minus film: `+` = the clip's event is later than the film's slot, `-` = earlier. Film 2's table is in beats (drop 64, break 60-63, hit 96) and keeps its beats at each clip's measured BPM; OPEN_AT_BEAT `o` is the clip beat the film opens on, on a bar line. `drift` = the opening's power under the groove's, dB (more negative = quieter), and `onsets` = its onset density over the groove's (lower = thinner); `build` = the build's power over the opening's.

| # | clip | BPM | 1st beat s | screen | open `o` (s) | drop: beat, +dB, err | break: beat, depth dB, err | hit / sound end, err | drop-to-hit gap | drift dB / onsets / build dB | cost | without END: `o`, drop, break, cost |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | synthwave-s1001 | 120.001 | 0.4775 | pass 0.75 | 0 (0.48) | 63, 5.74, -1 | 59 (4 beats), 11.1, -1 | 94 / 124, -2 | -1 | -13.8 / 0.94 / +13.5 | 11.4 | 0, -1, -1, 7.4 |
| 2 | trailer-s1001 | 120.001 | 0.2465 | pass 0.41 | 25 (12.75) | 90, 3.07, +1 | 26 (4 beats), 4.8, - (none) | 123 / 126, +2 | +1 | -5.3 / 0.21 / +5.2 | 12.7 | 4, +0, -, 10.1 |
| 3 | koto-s1001 | 120.013 | 0.0013 | pass 0.83 | 24 (12.0) | 92, 16.62, +4 | 88 (4 beats), 11.9, +4 | 119 / 124 fade, -1 | -5 | -1.6 / 0.58 / +3.1 | 21.2 | 24, +4, +4, 17.2 |
| 4 | koto-s1004 | 120.001 | 0.4905 | pass 0.69 | 19 (9.99) | 83, 5.05, +0 | 75 (4 beats), 6.7, -4 | 124 / 125, +9 | +9 | -0.6 / 0.79 / +0.5 | 21.3 | 19, +0, -4, 12.3 |
| 5 | koto-s1002 | 120.013 | 0.201 | pass 0.44 | 24 (12.2) | 93, 11.42, +5 | 87 (4 beats), 10.4, +3 | 123 / 126, +3 | -2 | +0.5 / 1.41 / +0.7 | 30.5 | 24, +5, +3, 27.5 |
| 6 | trailer-s1004 | 120.013 | 0.4948 | pass 0.35 | 23 (11.99) | 95, 3.36, +8 | 91 (4 beats), 7.6, +8 | 125 / 125, +6 | -2 | -6.5 / 0.72 / +5.6 | 32.2 | 0, -1, -1, 6.9 |
| 7 | trailer-s1003 | 119.989 | 0.494 | pass 0.32 | 0 (0.49) | 63, 6.95, -1 | 59 (4 beats), 7.9, -1 | 118 / 124 fade, +22 | +23 | -3.7 / 1.06 / -0.5 | 34.9 | 0, -1, -1, 10.9 |
| 8 | synthwave-s1008 | 119.989 | 0.1158 | pass 0.30 | 25 (12.62) | 96, 5.79, +7 | 91 (4 beats), 7.6, +6 | 121 / 125 fade, +0 | -7 | -0.9 / 1.78 / +1.0 | 35.1 | 0, +0, +31, 19.9 |
| 9 | synthwave-s1007 | 119.989 | 0.4908 | pass 0.48 | 24 (12.49) | 95, 7.45, +7 | 87 (8 beats), 7.7, +3 | 118 / 122 fade, -2 | -9 | -0.1 / 1.22 / +2.1 | 36.1 | 24, +7, +3, 30.1 |
| 10 | synthwave-s1005 | 120.001 | 0.236 | pass 0.51 | 3 (1.74) | 67, 4.65, +0 | 27 (4 beats), 7.6, -36 | 119 / 119, +20 | +20 | -5.2 / 1.24 / +4.5 | 36.2 | 3, +0, -36, 16.2 |
| 11 | trailer-s1005 | 120.001 | 0.241 | pass 0.47 | 0 (0.24) | 63, 9.41, -1 | 53 (4 beats), 8.3, -7 | 125 / 126, +29 | +30 | -7.8 / 1.12 / +2.4 | 44.2 | 0, -1, -7, 15.2 |
| 12 | koto-s1003 | 120.001 | 0.4938 | pass 0.33 | 0 (0.49) | 63, 4.0, -1 | 56 (4 beats), 4.6, - (none) | 125 / 125, +29 | +30 | -0.7 / 0.86 / -0.5 | 47.9 | 0, -1, -, 18.9 |
| 13 | trailer-s1002 | 120.001 | 0.4805 | pass 0.37 | 4 (2.48) | 51, 4.71, -17 | 65 (4 beats), 6.7, +1 | 110 / 120 fade, +10 | +27 | -6.2 / 0.82 / +2.8 | 50.2 | 23, +15, -1, 33.4 |
| 14 | koto-s1008 | 119.989 | 0.002 | pass 0.58 | 0 (0.0) | 56, 7.84, -8 | 48 (4 beats), 7.6, -12 | 120 / 122, +24 | +32 | -7.3 / 2.64 / +5.0 | 56.0 | 0, -8, -12, 32.0 |
| 15 | trailer-s1007 | 120.001 | 0.0123 | pass 0.42 | 0 (0.01) | 36, 3.09, -28 | 44 (4 beats), 3.9, - (none) | 96 / 125, +0 | +28 | -5.9 / 0.5 / +4.6 | 64.1 | 24, +23, -, 63.8 |
| 16 | synthwave-s1003 | 121.997 | 0.0063 | pass 0.48 | 0 (0.01) | 32, 9.94, -32 | 24 (8 beats), 3.5, - (none) | 124 / 127, +28 | +60 | -5.3 / 0.85 / +4.9 | 104.2 | 0, -32, -, 76.2 |
| 17 | koto-s1005 | 120.025 | 0.2533 | pass 0.40 | 0 (0.25) | 31, 4.8, -33 | 12 (4 beats), 3.6, - (none) | 117 / 122 fade, +21 | +54 | -7.7 / 1.97 / +7.0 | 105.0 | 0, -33, -, 82.0 |
| 18 | synthwave-s1002 | 122.021 | 0.004 | pass 0.45 | 0 (0.0) | 33, 4.8, -31 | 88 (4 beats), 3.1, - (none) | 127 / 128, +31 | +62 | -4.4 / 1.01 / +5.5 | 107.7 | 0, -31, -, 76.7 |
| 19 | synthwave-s1004 | 119.989 | 0.493 | pass 0.41 | 0 (0.49) | 15, 7.02, -49 | 75 (4 beats), 2.3, - (none) | 113 / 118 fade, +17 | +66 | -3.6 / 2.1 / +4.3 | 135.4 | 0, -49, -, 116.4 |
| 20 | trailer-s1006 | 120.001 | 0.2492 | fail 0.26 off | 6 (3.25) | 70, 7.75, +0 | 65 (4 beats), 12.5, -1 | 121 / 124, +19 | +19 | -3.9 / 1.15 / +1.8 | 28.6 | 6, +0, -1, 9.6 |
| 21 | koto-s1007 | 120.013 | 0.0043 | fail 0.36 off | 24 (12.0) | 96, 4.12, +8 | 92 (4 beats), 5.9, - (none) | 124 / 125, +4 | -4 | -1.7 / 1.14 / +1.5 | 38.7 | 0, +0, -, 15.0 |
| 22 | trailer-s1008 | 95.989 | 0.6128 | fail 0.21 | 0 (0.61) | 53, 7.44, -11 | 49 (4 beats), 6.0, - (none) | 94 / 95, -2 | +9 | -4.4 / 1.97 / +1.3 | 43.6 | 0, -11, -, 39.6 |
| 23 | koto-s1006 | 120.025 | 0.2535 | fail 0.34 off | - | 61, 2.75, - | 91 (4 beats), 3.4, - (none) | 124 / 125, - | - | - / - / - | 99 | - |
| 24 | synthwave-s1006 | 96.027 | 0.2503 | fail 0.21 | 0 (0.25) | 24, 3.35, -40 | 50 (4 beats), 1.8, - (none) | 94 / 98 fade, -2 | +38 | -3.2 / 1.09 / +2.8 | 102.7 | 0, -40, -, 96.7 |

## Listening (agy gemini-3.8-flash-high, two calls a clip, a field counts where both calls agree)

Calibration (three known-truth tracks, calib.py; listen/calibration.json): FAILED on hard_end. Trusted: voice, glitches, sparse_open, break, break_s, drop, drop_s.

| clip | voice | glitches | energy | sparse open | break (heard s / measured s) | drop (heard s / measured s) | hard end |
|---|---|---|---|---|---|---|---|
| koto-s1001 | False | none | 3* | False | False (- / 44.0) | False (- / 46.0) | True* |
| koto-s1002 | False | none | 3* | ? | False (- / 43.7) | ? (- / 46.7) | False* |
| koto-s1004 | False | none | ?* | ? | False (- / 38.0) | False (- / 42.0) | True* |
| synthwave-s1001 | False | none | ?* | False | True (- / 30.0) | True (- / 32.0) | True* |
| synthwave-s1008 | False | none | 4* | False | ? (- / 45.6) | True (- / 48.1) | True* |
| trailer-s1001 | False | none | 4* | ? | ? (- / 13.2) | True (- / 45.2) | True* |
| trailer-s1004 | False | none | 3* | ? | ? (- / 46.0) | ? (- / 48.0) | True* |

`?` = the two calls disagreed. `*` = the calibration did not pass for that field, so the cell is a screen, not a verdict.


## Pick (round film2-music, run `mwoyeo-film2-1`, 2026-10-20)

Fit first, then listening. Files: `/tmp/film2/music/pick/<clip>.{flac,mp3}` with `sha256.txt` (`pick.sh`). The mp3 is what
`beats.json` and `screen.tsv` measured (192 kbit/s); its grid differs from the flac's by ~3 ms. Beat `k` of a clip is at
`first_beat_s + k * period_s` (both in `beats.json`). Listening calibration (film-2-shaped tracks, `calib.py`): passed on
voice, glitches, sparse opening, break, break second, drop, drop second; FAILED on the hard end, so every `hard end` cell is a
screen, and energy has no truth (always a screen).

**Pick: `synthwave-s1001`** (prompt `synthwave`, asked 120 BPM, measured 120.001, first beat 0.4775 s, cost 11.4, rank 1;
screen pass, pulse 0.75 on the beat, kick on grid 28/40).
- Film at 120 BPM is 96 beats + a 3 s tail = 102 beats (51 s). It opens at clip beat 0 (0.48 s) and ends at clip beat 102
  (51.5 s); the clip's groove comes back at beat 103 (51.98 s), so the film must end before it.
- Drift: clip beats 0-30 sit 13.8 dB under the groove (-28 against -14 dB), the groove enters at beat 31 (16.0 s).
- Break: one bar of -25 dB at clip beats 59-62 (29.98-31.98 s), 11.1 dB under its neighbours, one beat before the film's
  60-63 (e_break -1). Independent check (ffmpeg `volumedetect` on the flac, 2 s windows): 28-30 s mean -14.4 dB, 30-32 s
  -24.7 dB, 32-34 s -14.2 dB.
- Drop: clip beat 63 (31.98 s), e_drop -1: the groove returns at the same level it left (-14 dB), +5.7 dB over the break bar.
  It is the groove coming back, not a bigger section: the clip has no build between beat 31 and 59, only the full groove.
- End: the last groove beat is 94 (47.48 s), e_end -2; then a -23 dB beat, then a ~-30 dB pad to beat 102 (4 s) and the groove
  again from beat 103. A stop followed by a pad, which a film cut at beat 102 hears as a hard end with a tail.
- Opening the film at clip time 0 s instead of beat 0 (beat -1 is at -0.02 s, so o = -1 needs no padding) makes the errors
  drop 0, break 0, hit -1.
- Listening, both calls agree on these (calibrated fields): no voice, no glitches, a break (yes), a drop (yes). The two calls
  disagree on energy (3 and 4) and on the seconds (break 0:33 and 0:14, drop 0:41 and 0:16 against the measured 30.0 and
  32.0), so the seconds carry no weight; the measured ones stand. Hard end: both heard a hit (screen only).
- **The weakness: the ear heard no sparse opening (both calls, a calibrated field).** The first 16 s are quiet but as busy as
  the groove: onset density 0.94 of the groove's and kick-band 0.85 (`intro_onsets` in FIT.md; a thin opening is 0.2-0.5).
  The brief's DRIFT (a detuned pluck, ticking, no full drums) is not there; the DRIFT row costs this clip 4.4 of its 11.4.
  The LOG pulse and the CLAUDE build are not there either: the groove is on from beat 31.

**Spare: `trailer-s1001`** (prompt `trailer`, asked 120 BPM, measured 120.001, first beat 0.2465 s, cost 12.7, rank 2; screen
pass, pulse 0.41).
- Best `o` is 25 (12.75 s): the film then runs to clip beat 127, the clip's end (63.75 s). Without the END terms the best `o`
  is 4 (cost 10.1).
- Drift: the opening is thin, onset density 0.21 of the groove's (kick-band 0.51), 5.3 dB under it, and the clip builds
  after it (build +5.2 dB; mean onset strength 12 in 0-8 s, 21 in 16-30 s, 81 in 32-46 s of the clip).
- Drop: clip beat 90 (e_drop +1), the groove at its full level (+3.1 dB over the 8 beats before). Break: none; the deepest dip
  is 4.8 dB at beat 26, under the 6 dB the fit needs. Hit: beat 123 (+2), sound end 126, a final hit then a short tail.
- Listening: no voice, no glitches, a drop (yes), all agreed and calibrated. The calls disagree on sparse opening (one heard
  "a suspenseful atmospheric intro", one did not) and on the break (0:11 against none); energy 4 in both and a hard end in
  both are screens.
- Why it is the spare: fit rank 2, a real drop and the only sparse opening of the 24, but no stop-time bar, which the build
  would have to make.

**Not picked, worth a look: `trailer-s1004`** (rank 6, cost 32.2, but 6.9 without the END terms, the best of the 24 there).
At `o` 0 it has the table's middle: a quiet opening (-10.3 dB under the groove, but onset density 0.89, busy like the pick's),
a build, a dip of 8.8 dB at beats 59-62 (-22, -26, -29, -28 dB; e_break -1), and then the loudest section of the clip from beat
63 (31.99 s): -9 dB against -17 dB before, a +9.5 dB rise (e_drop -1), so a real "biggest moment", which the pick lacks.
It then plays on to 63 s with no hit near beat 96 (48.5 s), which is why the full fit ranks it 6. One of its two listening
calls heard exactly this (a sparse opening, a break at 0:30, a drop at 0:33); the other heard a steady groove, so nothing is
agreed. If the build round makes the ending by an edit (cut at beat 96, add an impact), this is the clip with the stronger
break and drop; the pick has the cleaner natural ending and the agreed break and drop.

**What the 24 clips did not deliver.** No clip has all of: a thin opening, a build, a deep one-bar break at beats 60-63, the
drop on 64 and a hard hit on 96. The clips fill their 64 s (the sound ends at 60.0-63.8 s in all 24), so a hit near beat 96 exists only
where the groove stops by itself mid-clip (`synthwave-s1001`, and `trailer-s1007`, `trailer-s1008`, `synthwave-s1006`, which fail
elsewhere). The prompts' structure words were obeyed for tempo (22 of 24 within 3 %
of 120 BPM; `synthwave-s1006` and `trailer-s1008` came out at 96) and partly for the opening, but not for the timing of
sections. `FIT.md` says how far each clip is from the table.

