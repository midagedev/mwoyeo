# Does writing a row's target into the source (`apply: both`) keep names better than a hint alone? (2026-10-21, round both-bench)

Written once, by hand, from the preserved runs named below (all under `runs/`, `M-*-named-*`). The tables are `both_bench.py`
(`table`, `noise`, `judge`), `particles.py`, `score.py` and `judge.py`/`judge-run.py`; `runs/SUMMARY.md` has the same probe figures.
Measurement only: no product code changed. Feeds `docs/design/names-and-context.md` section 5.2 case (d) (line 203: with the Apple
switch on, the 1.1.4 converter writes `apply: both` on every user row, so engines other than Apple Translation also get those names
written into the source) and section 10 (lines 370-392: hint = sent as a row; replace = written into the SOURCE; both = the two; "Both is
better for names ... and likely on LLMs (final form plus gender; R7 measures it)").

## What was run

**Bench changes** (`runner/Sources/BenchKit/Apply.swift`, `Conditions.swift`, `Run.swift`, `bench-run/main.swift`; README documents them).
`bench-run run --apply hint|both|both-names` and `--memory-dir <dir>`; absent = today's request, byte for byte.
- `hint`: every user row `.hint`. `both`: every user row, entities and terms, `.both`. `both-names`: entities `.both`, terms `.hint`.
- For a `.both` row the item line the engine sees is rewritten as the product will: `ContextMemory.replaceRows`, then
  `ApplePreinsertion.insert` on the line (Core's functions, nothing re-implemented). Only the lines being translated are rewritten; the
  context and history lines stay original (the product inserts into the translated line only, `App/Pipeline/TranslationService.swift:1103`).
  The rows still go as hints and are selected on the ORIGINAL lines (`RequestLayout.selectRows` matches a row's source against the items;
  a written target no longer holds it). Each request records `replaced` (`[{id, text, spans: [[matched, target]]}]`); the translations stay
  keyed by the original lines, so scoring and judging read `sequences/` unchanged.
- `memory-named/<id>.json` = `memory/<id>.json` with `dst` authored for every entity that had none (list below). Many entity rows had no
  `dst`, and `ApplePreinsertion` skips a pair equal to its target, so `both-names` would have equalled `hint` on most sequences. `memory/`
  and every earlier run are untouched. The set is not part of the manifests' corpus hash.

**Runs** (condition `M`, `--layout t2`, `--jobs 1`, `--memory-dir memory-named`, the 15 sequences: the 14 of `M-<model>-t2` plus
`film-ja-ko-1`; each preserved with `cloud.sh` / `matrix.sh` + `runs.py add`; names never reused):

| engine | noise floor (memory/, old set) | hint | both-names | both |
|:---|:---|:---|:---|:---|
| `claude-haiku-5-5` (Anthropic kind) | `M-haiku-5-5-t2-r2` | `M-haiku-5-5-t2-named-hint`, `-hint-r2` | `-named-both-names`, `-both-names-r2` | `-named-both`, `-both-r2` |
| `gemma4:e4b` (Ollama, temperature 0) | `M-gemma4-e4b-t2-r2` | `M-gemma4-e4b-t2-named-hint` | `-named-both-names` | `-named-both` |

Haiku is not deterministic at temperature 0, so each Haiku arm ran twice (r2 is a repeat of the same command). Lines: 481 in 15
sequences. Classes (never pooled): **N** 110 lines rewritten under `both-names` (an entity's target written in), **T** 60 lines
rewritten under `both` only (a term written in, no entity), **U** 311 lines no arm rewrote. `both` and `both-names` differ only on
T (terms always have a target). Cost (`score.py` cost estimate line): $0.0175 per Haiku run, 7 Haiku runs of this round about $0.12
(plus one stopped partial run, about $0.01); gemma4 local, $0.

**Request identity (listed and excluded from the evidence).** `cmp` of the request bodies of the oracle plan (`--dump-bodies`, the
engine replays the references, so the bodies depend only on the arm): hint vs both-names, 12 of 15 sequences differ, identical:
`docs-en-ko-1`, `docs-ja-en-1`, `docs-ko-en-1`; hint vs both, 15 of 15 differ, none identical. The real runs agree (no request of those
three sequences has a rewrite; their layout counts are equal). Those three sequences are left out of the both-names vs hint rows below.
Rewritten lines: 110 under both-names, 170 under both (the oracle plan; every real run recorded the same `replaced` lines).

## Gates

- (a) `cd tools/translation-bench/runner && swift test`: `Test run with 43 tests in 11 suites passed`, rc=0 (`/tmp/bothbench/runner-test2.log`).
  New cases (`ApplyTests.swift`): `both` rewrites a ja item line holding an entity into its `dst`, `hint` does not, a history line is never
  rewritten, a request nothing is written into is byte-identical to `hint` on every engine kind. FAIL-first, on the unchanged text before the
  rewrite existed: `✘ Test bothWritesAnEntitysTargetIntoTheItemLineAndHintDoesNot() recorded an issue at ApplyTests.swift:60:9: Expectation
  failed: bothTexts[1] == "宿は카이が取ってくれるんだよね?"` with `bothTexts[1] → "宿は海が取ってくれるんだよね?"`.
- (b) Default path, `engines/oracle.json`, conditions M and B2, `--layout t2`: flags absent and `--apply hint` against the build of main
  (`requests` and `translations` only): `M-absent`/`M-hint` 14 files, 0 differing strict; `B2` 14 files, 0 differing. Against the old preserved
  `oracle-M-t2` the strict compare shows 7 files differing and all of it is float digits in the token estimates (`memory_tok 39.69` against
  `39.690000000000026`; main's own binary gives the same digits), 0 differing when floats are rounded to 6 decimals; `oracle-B2-t2` 0 differing
  strict. FAIL-first side: `--apply both` on the oracle differs on 15 of 15 sequences, `both-names` on 12 of 15.
- (c) `particles.py` (batchim table: 은/는, 이/가, 을/를, 과/와, 으로/로, 아/야, 이랑/랑, applied to the character after each written target
  in the output; also a kana left right after a target, and a one-character Han row replaced inside a longer word). `tests/test_particles.py`:
  `Ran 9 tests ... OK`; with `--neuter` (particle table off) `FAILED (failures=6)`. `tests/test_both_bench.py`: `Ran 5 tests ... OK`; with `--neuter`
  (classes pooled, no identical sequence) `FAILED (failures=5)`.
- `tests/run-all.sh` (corpus validation, scorer, judge, runs, FAIL-first neuters, `runs.py verify` 71 checked 0 failed, `summary.py --check`
  current, `render parity: 45 renderings compared, 0 mismatches`): rc=0.

## Noise floor

A new `hint` run on `memory/` (old set) per engine, on the 14 sequences of the baselines.

| engine | old run | new run | requests identical | output identical | probes passed old / new | only old / only new passes (sign test) | judge, old vs new |
|:---|:---|:---|:---|:---|:---|:---|:---|
| Haiku | `M-haiku-5-5-t2` | `-r2` | 245 of 252 (9 of 14 sequences; the 7 others differ in their context and history lines, which carry the model's earlier output) | 104/445 lines | 199/312 (63.8%) / 218/312 (69.9%) | 8 / 27, p=0.002 | 127 : 127, 35 ties, 49 orders disagree (not counted); calibration 8/8 |
| gemma4:e4b | `M-gemma4-e4b-t2` | `-r2` | 252 of 252 (14 of 14) | 435/445 lines | 207/312 (66.3%) / 205/312 (65.7%) | 2 / 0, p=0.5 | 3 : 6, 1 tie, only 9 decided; calibration 8/8 |

Haiku alone moves 6 points of probes between the old baseline and its repeat (the named-set pair `named-hint` / `named-hint-r2`, run an
hour apart, differs by 0.3 points, 258/353 against 257/353, flips 12 / 11, p=1.0; so the spread between two runs is 0 to 6 points). The judge noise is symmetric (127 : 127). So
a single Haiku run cannot decide a 2-4 point delta; every Haiku arm was repeated and the two replicates are shown beside each other.
gemma4 is deterministic (97.8% of lines identical): its deltas are the arms'.
Class-wise Haiku noise (hint vs hint-r2, the same lines; first only / second only): N 5/3 (p=0.73), T 1/0, U 6/8 (p=0.79); both-names vs
both-names-r2: N 4/2, U 5/4; both vs both-r2: N 7/4, U 6/11.

## Scores by line class

Names kept = key lines whose output holds the memory's form (`film_consistency.py` rendering). On N and T it is inflated by construction
(the source already holds the target; copying passes): it is shown, and not used to decide. Probes = `score.py` `check_probe` pass rates.
"Left untranslated" = output equal to its own source, or kana left in a ko output (distinct lines).

**Haiku, replicate 1** (`M-haiku-5-5-t2-named-*`)

| arm | class | lines | entity key-lines kept | term key-lines kept | probes passed | echoed | kana | left untranslated |
|---|---|---|---|---|---|---|---|---|
| hint | N | 110 | 114/115 (99.1%) | 16/17 (94.1%) | 101/114 (88.6%) | 0 | 0 | 0 |
| hint | T | 60 | - | 62/66 (93.9%) | 53/63 (84.1%) | 0 | 0 | 0 |
| hint | U | 311 | - | - | 104/176 (59.1%) | 6 | 9 | 9 |
| both-names | N | 110 | 114/115 (99.1%) | 16/17 (94.1%) | 96/114 (84.2%) | 0 | 3 | 3 |
| both-names | T | 60 | - | 63/66 (95.5%) | 53/63 (84.1%) | 0 | 0 | 0 |
| both-names | U | 311 | - | - | 103/176 (58.5%) | 4 | 6 | 6 |
| both | N | 110 | 113/115 (98.3%) | 17/17 (100%) | 97/114 (85.1%) | 1 | 2 | 2 |
| both | T | 60 | - | 66/66 (100%) | 57/63 (90.5%) | 0 | 0 | 0 |
| both | U | 311 | - | - | 99/176 (56.2%) | 7 | 6 | 8 |

**Haiku, replicate 2** (`-hint-r2`, `-both-names-r2`, `-both-r2`)

| arm | class | lines | entity key-lines kept | term key-lines kept | probes passed | echoed | kana | left untranslated |
|---|---|---|---|---|---|---|---|---|
| hint | N | 110 | 113/115 (98.3%) | 16/17 (94.1%) | 99/114 (86.8%) | 0 | 0 | 0 |
| hint | T | 60 | - | 62/66 (93.9%) | 52/63 (82.5%) | 0 | 0 | 0 |
| hint | U | 311 | - | - | 106/176 (60.2%) | 4 | 6 | 6 |
| both-names | N | 110 | 114/115 (99.1%) | 16/17 (94.1%) | 94/114 (82.5%) | 1 | 1 | 1 |
| both-names | T | 60 | - | 63/66 (95.5%) | 53/63 (84.1%) | 0 | 0 | 0 |
| both-names | U | 311 | - | - | 104/176 (59.1%) | 6 | 8 | 8 |
| both | N | 110 | 113/115 (98.3%) | 17/17 (100%) | 94/114 (82.5%) | 0 | 3 | 3 |
| both | T | 60 | - | 66/66 (100%) | 56/63 (88.9%) | 0 | 0 | 0 |
| both | U | 311 | - | - | 104/176 (59.1%) | 4 | 3 | 5 |

**gemma4:e4b** (`M-gemma4-e4b-t2-named-*`, deterministic)

| arm | class | lines | entity key-lines kept | term key-lines kept | probes passed | echoed | kana | left untranslated |
|---|---|---|---|---|---|---|---|---|
| hint | N | 110 | 114/115 (99.1%) | 16/17 (94.1%) | 98/114 (86.0%) | 0 | 0 | 0 |
| hint | T | 60 | - | 65/66 (98.5%) | 55/63 (87.3%) | 0 | 0 | 0 |
| hint | U | 311 | - | - | 95/176 (54.0%) | 1 | 5 | 5 |
| both-names | N | 110 | 114/115 (99.1%) | 17/17 (100%) | 98/114 (86.0%) | 0 | 0 | 0 |
| both-names | T | 60 | - | 65/66 (98.5%) | 55/63 (87.3%) | 0 | 0 | 0 |
| both-names | U | 311 | - | - | 95/176 (54.0%) | 1 | 5 | 5 |
| both | N | 110 | 114/115 (99.1%) | 17/17 (100%) | 98/114 (86.0%) | 0 | 0 | 0 |
| both | T | 60 | - | 65/66 (98.5%) | 55/63 (87.3%) | 0 | 0 | 0 |
| both | U | 311 | - | - | 95/176 (54.0%) | 1 | 5 | 5 |

**Did the hint lose power on the untouched lines (U)?** No beyond the noise. Every key line (a line holding an entity's or a term's
source) is a rewritten line by construction, so U has no names-kept figure (0/0); the hint's power on U is read on the probes. Haiku U
probes (of 176), r1 / r2: hint 104 / 106, both-names 103 / 104, both 99 / 104. By sequence kind, r1 / r2 (chat of 71, docs of 43, game of 29,
subtitles of 33): hint 42 25 23 14 / 42 24 23 17; both-names 42 23 23 15 / 42 25 23 14; both 37 24 22 16 / 40 27 23 14. By type (name of 48,
pronoun of 42, term of 55): hint 19 21 44 / 19 19 46; both-names 20 16 46 / 20 19 45; both 15 19 45 / 21 17 46. The largest gap between two
arms (`both` name 15 against 21 in its repeat) is a repeat of the same arm. gemma4 U probes 95/176 in all three arms with identical kind
and type splits; 294-301 of 311 U lines are byte-identical to hint (the ones that differ are neighbours of rewritten lines in a batch).

**Against hint, the same lines** (identical output; probes only hint passes / only the arm passes; two-sided sign test; the three
both-names-identical sequences left out of both-names T and U):

| engine | arm | class | lines | identical output | probes | hint only | arm only | p |
|---|---|---|---|---|---|---|---|---|
| Haiku r1 | both-names | N | 110 | 26 | 114 | 6 | 1 | 0.125 |
| Haiku r2 | both-names | N | 110 | 35 | 114 | 7 | 2 | 0.180 |
| Haiku r1 | both | N | 110 | 27 | 114 | 6 | 2 | 0.289 |
| Haiku r2 | both | N | 110 | 31 | 114 | 9 | 4 | 0.267 |
| Haiku r1 | both | T | 60 | 17 | 63 | 1 | 5 | 0.219 |
| Haiku r2 | both | T | 60 | 24 | 63 | 0 | 4 | 0.125 |
| Haiku r1 / r2 | both-names | U | 239 | 61 / 71 | 133 | 8 / 6 | 9 / 3 | 1.0 / 0.51 |
| Haiku r1 / r2 | both | U | 311 | 86 / 81 | 176 | 12 / 11 | 7 / 9 | 0.36 / 0.82 |
| gemma4 | both-names | N | 110 | 77 | 114 | 2 | 2 | 1.0 |
| gemma4 | both | N | 110 | 75 | 114 | 2 | 2 | 1.0 |
| gemma4 | both | T | 60 | 37 | 63 | 0 | 0 | 1.0 |
| gemma4 | both-names / both | U | 239 / 311 | 229 / 294 | 133 / 176 | 0 | 0 | 1.0 |

Pooled over the two Haiku replicates (the same lines asked twice, so the replicates are not independent samples of new lines):
on N, both-names loses 13 probes to hint and wins 3 (p=0.021), both loses 15 and wins 6 (p=0.078). Split by probe type on N, both-names:
name+term probes 7 / 3 (p=0.34); pronoun+register+speech_level probes (not inflated by a copied name) 6 / 0 (p=0.031); both: 6 / 4
and 9 / 2 (p=0.065). On T (a term written into the line) `both` wins 9 term probes to 1 (p=0.021), but that is the copy inflation,
not evidence. gemma4 has no flip beyond 2 / 2.

**Left untranslated (N lines, two Haiku replicates):** hint 0 of 220, both-names 4 of 220, both 5 of 220; gemma4 0 / 0 / 0 of 110.
`subs-ja-ko-1` line 28 (`小鳥遊さん、よろしくお願いしますね。`) is left untranslated in all four Haiku rewrite runs (twice the source echoed whole,
twice `타카나시さん、よろしくお願いしますね。`) and translated (`타카나시 씨, 잘 부탁드립니다.`) in both hint runs and in every gemma4 arm. Other lines:
`film-ja-ko-1` 18 (twice), `game-ja-ko-1` 25 and 21, `subs-ja-ko-1` 7. A rewritten line is a mixed-script sentence, and Haiku sometimes
treats it as done. One more mechanism, on `chat-ja-ko-1` line 16 (`あと湊にも連絡しといて`, 湊 is in no memory row): hint gives `minato... 미나토한테도`, both-names
gives `카이에게도`, the Korean name written into the neighbouring lines of the batch bleeding onto an unknown name.

## Judge

`judge.py prompts --a <hint> --b <arm>` then `judge-run.py run` (agy `gemini-3.8-flash-high`, both orders, `--calibration 8`; only the items
where both orders agree are counted; the judge sees the memory with its `dst` forms and the ORIGINAL source line). A = hint, B = the arm.
Win = B wins of the decided (a tie is not decided); Wilson 95% interval; p = two-sided sign test; calibration (identical text, both orders
tie) 8/8 in every pass.

Cells are `A:B (ties)`, then B's share of the decided pairs with its Wilson interval and the sign-test p. Replicates are pooled by adding
counts of the same arm asked twice (replicates share lines, so p is optimistic); classes and engines are never pooled.

| pass (A = hint) | all | N rewritten by both-names | T term-only lines | U untouched |
|:---|:---|:---|:---|:---|
| Haiku both-names r1 | 136:113 (54) 45% (39-52) p=0.16 | 38:24 (7) 39% (28-51) p=0.098 | 10:17 (9) 63% (44-78) p=0.25 | 88:72 (38) 45% (37-53) p=0.24 |
| Haiku both-names r2 | 113:111 (38) 50% (43-56) p=0.95 | 38:17 (4) 31% (20-44) p=0.006 | 10:9 (5) 47% (27-68) | 65:85 (29) 57% (49-64) p=0.12 |
| **Haiku both-names, r1+r2** | 249:224 (92) 47% (43-52) p=0.27 | **76:41 (11) 35% (27-44) p=0.002** | 20:26 (14) 57% (42-70) p=0.46 | 153:157 (67) 51% (45-56) p=0.87 |
| Haiku both r1 | 135:108 (38) 44% (38-51) p=0.095 | 39:21 (4) 35% (24-48) p=0.027 | 11:17 (5) 61% (42-76) p=0.35 | 85:70 (29) 45% (38-53) p=0.26 |
| Haiku both r2 (partial, see below) | 73:69 (23) 49% (41-57) | 22:14 (4) 39% (25-55) p=0.24 | 9:7 (2) 44% (23-67) | 42:48 (17) 53% (43-63) |
| **Haiku both, r1+r2 (r2 partial)** | 208:177 (61) 46% (41-51) p=0.13 | **61:35 (8) 37% (28-46) p=0.010** | 20:24 (7) 55% (40-68) p=0.65 | 127:118 (46) 48% (42-54) p=0.61 |
| gemma4 both-names | 19:15 (6) 44% (29-61) p=0.61 | 15:12 (3) 44% (28-63) p=0.70 | 0:1 | 4:2 (3) |
| gemma4 both | 34:20 (10) 37% (25-50) p=0.076 | 16:11 (2) 41% (25-59) p=0.44 | 13:4 (4) **24% (10-47) p=0.049** | 5:5 (4) |

Noise of the judge on the same classes: Haiku `M-haiku-5-5-t2` vs `-r2` (memory/ set, all lines) 127:127 (35 ties), calibration 8/8; Haiku
`named-hint` vs `named-hint-r2`, per class (a screen: one calibration verdict is missing, the quota ran out): all 109:116 (40) 52%, **N 22:23
(6) 51%**, T 9:14 (6) 61%, U 78:79 (28) 50%. So two runs of one arm split an N class evenly and the rewrite arms do not: hint wins the
rewritten name lines about 2 to 1 on Haiku (76:41, 61:35) and by 15:12, 16:11 on gemma4 (the same sign, too few pairs to stand alone).
On U the judge is even (153:157, 127:118) and on T it has no consistent sign (Haiku both-names 20:26 and both 20:24 for the arm, gemma4 both
13:4 for hint).

Calibration (identical text, both orders must say tie): 8/8 in every complete pass. Particle breaks beside the wins: every pass reports 0
particle breaks of the arm's rewritten lines, and 0 of the arm's N-class wins carry a break or a kana left after the target; the judge's
hint preference on names is therefore not a particle effect, and the arm's name wins are not particle-broken ones.

**Two passes are not complete** (agy: `Individual quota reached. Please upgrade your subscription ... Resets in 2h30m`, seen about 03:00
UTC): Haiku `named-hint-r2` vs `named-both-r2` has 166 of 706 prompts without a verdict (143 items counted missing; its row above is
partial), and `named-hint` vs `named-hint-r2` has 28 of 688 missing. Resume (done calls are skipped): `python3 -I judge-run.py run --pair
/tmp/bothbench/judge/haiku-both-r2-vs-hintr2 --out /tmp/bothbench/judge/haiku-both-r2-vs-hintr2/run`, then `both_bench.py judge` again. The data
so far is preserved in `runs/_judge/2026-10-21-both-bench/` (`pairs.txt` lists every pair).

**Why the judge prefers hint on the rewritten name lines** (read from the probes and the lines, not a measured cause): the six speech-level,
register and pronoun probes that hint passes and both-names fails on N lines (3 in each replicate, 0 the other way) are `film-ja-ko-1` 2 and
6 and 16 (speech level: `シュザンヌ speaks_to 九十九: 반말`, `九十九 speaks_to エルヴェ: 해요체`, `シュザンヌ speaks_to エルヴェ: 해요체`),
`game-ja-en-1` 10 (pronoun: `アキラ` is female) and `game-ja-en-1` 13 (register: `アキラさん` after `アキラでいい` must come out `Akira`, not
`Akira-san`). Five are rules the memory keys by the original-script name. After the rewrite the line holds the target form
(`츠쿠모, ... 사당이에요`, `Akira folded their umbrella`), the row still keys the rule by the source form, and Haiku sometimes does not
connect them; the sixth shows the same seam in a line-derived rule (`アキラさん` rewritten to `Akira` + `さん`). The same lines carry the
untranslated-line failures above. Untested: keying a written row's addressing and gender by its target form.

## Particle breaks and one-character rows (`particles.py`, ko targets)

Of the written targets that stand directly before a particle in the output (Haiku: 12-13 under both-names, 28-29 under both; gemma4 13 / 32):
**0 particle breaks** in any arm, any replicate, any engine. The checker is not blind (hand-broken lines in `tests/test_particles.py`);
the engines, asked to translate a source holding `카이が`, reproduce the right particle. Failure modes the checker does find:
- kana left right after a written target (the engine kept the source's own particle or word): Haiku both-names r1 1 line
  (`subs-ja-ko-1/28`: `타카나시さん`), both r1 2 lines (`game-ja-ko-1/21`: `텟사이が、사쿠の肩を`), both r2 1 line (`subs-ja-ko-1/28`); gemma4 0.
- one-character Han row replaced inside a longer word, 1 in every arm that rewrites: `game-ja-en-1/2`, `薫 -> Kaoru` inside `薫先輩、`
  (the target is written into a longer word; the engine still read it).

## Authored names (`memory-named/`, for the lead to check; 19 entities, only `dst` added)

`chat-ja-ko-1`: ミナ -> 미나, 海 -> 카이, ユウ -> 유우. `chat-ja-ko-2`: 十河 (そごう) -> 소고, 日向 (ひゅうが) -> 휴가. `chat-ko-en-1`: 서윤 -> Seoyoon.
`game-ja-en-1`: ヒカル -> Hikaru, 薫 (かおる) -> Kaoru, アキラ -> Akira, ユキ -> Yuki. `game-ja-ko-1`: 朔 (さく) -> 사쿠, リーシア -> 리시아.
`game-zh-en-1`: 单云舟 (Shàn Yúnzhōu) -> Shan Yunzhou, 曾若水 -> Zeng Ruoshui, 覃长老 (Qín) -> Elder Qin, 乐川 (Yuè Chuān) -> Yue Chuan, 解玄 (Xiè Xuán) -> Xie Xuan.
`subs-en-ko-1`: Dex -> 덱스, Pell -> 펠. No entity of the other seven sequences lacked a `dst`. Hangul by the corpus's own transliteration, Hepburn
and pinyin without tone marks for the targets in English.

## Recommendation (for design 5.2(d) and 10; the lead decides)

1. **Chat and Anthropic kinds: keep `hint`; do not mark Both "recommended for names" in the pop-up.** Names kept is 98-99% in every arm (inflated by
   copying on the rewritten lines), hint's power on the untouched lines is unchanged (noise-sized), and the judge prefers hint on the rewritten name lines
   (Haiku both-names 76:41, p=0.002; both 61:35, p=0.010; gemma4 15:12 and 16:11; the same lines split 22:23 between two runs of one arm),
   with 0 particle breaks, 4 (both-names) and 5 (both) of 220 Haiku lines left untranslated (0 under hint) and 6 addressing/gender probes lost, 0 won.
2. **"Both for names only" is not better than "both for all rows", and neither beats hint.** `both` and `both-names` lose the same name lines (the arm wins 35%
   and 37% of the decided pairs, Haiku); the term-only lines have no consistent sign (Haiku 20:26 and 20:24 for the arm, gemma4 13:4 for hint,
   p=0.049); the term probes that rise under `both` (9 to 1) are the copied terms, not evidence.
3. **Design 5.2(d): do not hand `apply: both` to LLM engines when the Apple switch is on**: write the replacement only on the Apple Translation path (a row's apply by
   engine kind) and send LLM engines hints. `both` was not measured on Apple Translation (no Neural Engine here), which is the engine it exists for; if a rewrite
   is wanted for LLMs, the next round is to key a written row's addressing and gender by its target form and re-run this bench (6 Haiku runs, about $0.1, plus the judge passes).

## Limits

Two engines, 15 sequences of our own text, Haiku with two replicates (not three). The judge is one model; calibration passed in
every complete pass, and two passes are incomplete (agy quota). Apple Translation, the engine `both` exists for, is not measured here (no Neural Engine in this round). The per-class
judge counts are small on gemma4 (44 and 75 items asked: 437 and 406 translations were identical and not asked).

## Reproduce

`bench-run run --engine engines/<engine>.json --condition M --layout t2 --jobs 1 --memory-dir memory-named --apply hint|both|both-names
--out <dir> --root .` (`cloud.sh` / `matrix.sh` do it and preserve the run; each run's `MANIFEST.json` has the exact command and the note).
`python3 -I both_bench.py table --engine <label> --hint <run> --both-names <run> --both <run>`; `python3 -I both_bench.py noise --old <run> --new <run>`;
`python3 -I judge.py prompts --a <hint run> --b <arm run> --out <dir> --root <root with memory -> memory-named> --calibration 8`, `python3 -I judge-run.py run
--pair <dir> --out <dir>/run`, `python3 -I both_bench.py judge --pair <dir> --verdicts <dir>/run/verdicts.jsonl --b-run <arm run> --hint ... --both-names ... --both ...`.
The judge verdicts, keys and call logs are preserved in `runs/_judge/2026-10-21-both-bench/` (`pairs.txt` lists A and B of every pair and the two incomplete ones).

## Decision (the user, 2026-10-21)
1.1.4's `appleUsesPinnedTerms` migrates per engine in effect: rows of a profile Apple Translation translates become `both`; rows of a
profile on an added engine keep `hint` (the judge preferred hint on LLM name lines, 76:41, p=0.002). "Recommended for names" is shown
only where Apple Translation is in effect. Apple Translation itself was not measured in this bench.
