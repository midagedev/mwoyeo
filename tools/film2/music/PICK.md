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
