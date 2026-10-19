# The judge pass and the context defaults for 1.1.4 (2026-10-19 to 10-20, round t3j-judge)

Written once, by hand, from the preserved runs and judge passes named below. Every number comes from `score.py`, `latency.py`,
`judge.py tally`, `judge-run.py known-answer-tally` and `judge-report.py`; the judge data is under `runs/_judge/2026-10-19-t3j/` and the
cloud runs under `runs/*-haiku-5-5*`. The probe and latency numbers of the two local models are those of
`RESULTS-2026-10-19-t3-product-layout.md` (the previous round, not repeated here); the cloud numbers and all judge numbers are new.
Nothing here changes a default: the last section is the recommendation for the lead.

## What was done, and where it differs from the spec

1. **The product-layout bench is landed** on today's main (4b90f1c): `git apply` of `/tmp/t3-parked/t3-bench-product.diff` applied without
   conflicts. It was applied without `--3way`, because `--3way` implies `--index` and stages the files (a `git add`, which the round bans).
   `tests/run-all.sh` rc 0 (below). Earlier runs are untouched.
2. **Judge: agy, but not `gemini-3.8-flash-high` for the bulk.** The spec's judge is `gemini-3.8-flash-high`. It could not carry the pass:
   - Its answers think for 14,400 tokens on average (112 s per successful call of 5 to 15 cases) and often do not finish within the CLI's `--print-timeout`: of
     74 calls, 28 failed (24 came back `status: SUCCESS` with an empty answer and zero tokens, the CLI's own timeout; 3 more were labelled so
     by the harness; 1 rc 1), so 46 calls gave 538 verdicts (168 of them the known-answer set). Exit 0 and `SUCCESS` were not success, as the rules say.
   - `--effort` is refused for this model (status ERROR). The same prompt on `gemini-3.8-flash-medium` took 38 s and on
     `gemini-3.8-flash-low` 4.6 s.
   - So **`gemini-3.8-flash-low` judged every differing line of every pair** (the primary verdict, 10,218 verdicts, 1,141 of 1,147 calls ok) and
     **`gemini-3.8-flash-medium` judged a seeded 100-line sample of ten pairs** as the second judge (1,647 verdicts, 289 of 291 calls ok).
     `gemini-3.8-flash-high` verdicts are kept (`runs/_judge/2026-10-19-t3j/high/`) for the known-answer check and two partial pairs only.
     agy's quota ended at about 00:25 on 10-20 ("Individual quota reached", resets in 2 h 35 min), after the last needed pair; one medium pair
     (`gemma3-4b-A-vs-B2+2-t2`, 19 decided lines) was cut by it and is not used.
   - Rule (the lead's, for audio verdicts, applied to text): two judges that agree plus a passed calibration are a verdict, one judge alone
     is a screen. The tables give the low judge over all lines, the medium judge over the sample, and their consensus.
3. **The judge harness** (new, `tools/translation-bench/`): `judge-run.py` (batches of 6 to 10 cases per call, both orders in different calls,
   a retry asks only the missing cases, every raw try kept, `status` and the answer checked, not the exit code), `judge-report.py` (tables,
   consensus, the split by lines copied back), `judge-pairs.sh` (cloud and nearby pairs added), `cloud.sh`, engine file
   `engines/anthropic-haiku-5-5.json`, and unit tests `tests/test_judge_run.py` (8 tests) and `tests/test_judge_report.py` (2 tests) in
   `run-all.sh`, each with its FAIL-first line (below).

## Tests (rc 0)

```
sh tests/run-all.sh /tmp/t3j/build      -> rc=0   (validate: 14 sequences, 445 lines, 312 probes, 0 errors; test_score, test_judge, test_judge_run
                                                  (8), test_judge_report (2), test_runs, runs.py verify "runs: 47 checked, 0 failed",
                                                  test_failures (+ --neuter must fail), test_latency, test_summary, summary.py --check
                                                  "runs/SUMMARY.md is current", swift test "Test run with 35 tests in 9 suites passed",
                                                  check_render "42 renderings compared, 0 mismatches")
```

FAIL-first lines of the new checks:

```
FAIL-first: the CLI exits 0 with status ERROR -> run rc 4, 0 verdicts counted, 12 raw tries kept
FAIL-first: a judge that always answers the first translation -> reference wins 0, orders disagree 12, calibration FAILED
FAIL-first: a judge that prefers the wrong translation -> reference wins 0, loses 12, calibration FAILED
FAIL-first: counting the first order only gives A 3, B 1; counting both orders gives A 1, B 1 (item 3 is position bias, item 5 has one order)
```

## The instrument

**Known-answer calibration** (`judge-run.py known-answer`: 80 lines, the reference translation against the line's own untranslated source text
(20) and against the reference with a probe's known wrong rendering (60); the reference must win in both orders on at least 90 % and lose on at
most 5 %; plus 4 identical-text items that must be a tie). Set before the pass; all three models passed:

| judge | reference wins | reference loses | tie | orders disagree | identical text tie | verdict |
|:---|---:|---:|---:|---:|---:|:---|
| flash-high | 75 of 80 (93.8 %) | 1 | 2 | 2 | 4 of 4 | PASSED |
| flash-medium | 75 of 80 (93.8 %) | 1 | 3 | 1 | 4 of 4 | PASSED |
| flash-low | 74 of 80 (92.5 %) | 0 | 2 | 4 | 4 of 4 | PASSED |

In every pair the 4 identical-text items also came out as ties in both orders (`4/0/0` in all low and in 9 of 10 medium pairs; the tenth was cut
by the quota). Each pair's own calibration is in `tally-low.txt` and `tally-medium.txt` (`judge.py tally`). The medium tally counts the lines it
was not asked as "missing".

**Position bias.** Items whose two orders disagree (not counted): low 13 to 23 % of the differing lines, medium 3 to 18 %.
**Low versus medium**, on the lines both judges answered consistently in both orders: the same outcome (side or tie) on 669 of 704 (95.0 %).

**Self against agy** (the spec's "doubt the instrument once"). I judged 20 random differing lines blind (seeded draw over the six decision pairs,
my verdicts written and made read-only before any agy verdict existed; `self-blind-20/`). I decided 15 (9 for translation 1, 6 for 2) and called 5 a
tie. Agreement of the same prompt, one order:

| agy model | answered | identical verdict | both decided, same side | both decided, opposite side | one tie, one side |
|:---|---:|---:|---:|---:|---:|
| flash-low | 20 | 14 (70 %) | 12 | 3 | 3 |
| flash-medium | 20 | 15 (75 %) | 12 | 3 | 2 |
| flash-high | 15 (5 timed out) | 9 (60 %) | 9 | 0 | 6 |

So a single order of a single judge agrees with a careful reader on about 70 to 75 %, and flips the side on 3 of 15 decided lines. The
disagreements are the hard lines (two wrong romanizations of a name, a speech level against a name). Both orders and the 95 % consensus of two
judges are what the tables below count, not one answer.

## The cloud check (D4)

`claude-haiku-5-5`, Anthropic API, `--layout t2` (the product's bytes), jobs 1, all 252 requests, 312 probes. Estimate before running, on the
local models' token counts and Haiku 5.5's $0.10 in / $0.50 out per million: about $0.06 for five runs. Measured: **$0.135** (A $0.0150, A
repeat $0.0153, M $0.0355, B2 $0.0344, B2+2 $0.0346; cloud replies are 91 to 190 output tokens, 2 to 4 times the local ones). The stop was $2.
Runs: `A-haiku-5-5`, `A-haiku-5-5-r2` (the A/A repeat), `M-haiku-5-5-t2`, `B2-haiku-5-5-t2`, `B2+2-haiku-5-5-t2`. The key was read from the
environment and never printed (the runner scrubs it).

| run | probes % | memory % | lines % | none % | delta vs A (pts) | p | untranslated of ~440 | tokens in / out per request |
|:---|---:|---:|---:|---:|---:|---:|---:|:---|
| A | 43.6 | 31.7 | 36.1 | 90.6 | - | - | 4 | 138 / 91 |
| A repeat (A/A) | 43.3 | 28.6 | 39.8 | 86.8 | -0.3 | 1.00 | 3 | 137 / 94 |
| **M** | **63.8** | 73.8 | 42.9 | 92.5 | **+20.2** | <0.001 | 6 | 479 / 186 |
| B2 | 44.6 | 28.6 | 39.8 | 94.3 | +1.0 | 0.79 | 15 | 417 / 189 |
| B2+2 | 43.9 | 27.0 | 41.4 | 90.6 | +0.3 | 1.00 | 14 | 419 / 191 |

Latency (`latency.py --aa A-haiku-5-5 A-haiku-5-5-r2`, paired by request; the A/A spread of the p50s is 30 ms, of the p95s 99 ms):

| run | p50 ms | p95 ms | median delta vs A/A (ms) | mean delta without stalls (ms) | p95 vs A/A | verdict |
|:---|---:|---:|---:|---:|---:|:---|
| A, A repeat | 1046, 1016 | 2381, 2282 | +10, -10 | | | |
| M | 1221 | 3982 | +136 | +473 | +71 % | resolved (4.5x the spread) |
| B2 | 1554 | 4201 | +328 | +730 | +80 % | resolved (10.9x) |
| B2+2 | 1258 | 4187 | +166 | +558 | +80 % | resolved (5.5x) |

The lead's +300 ms prediction holds for the median of a cloud engine (+136 to +328 ms) and not for the local one (+880 to +995 ms).

## Condition tables

"Judge" columns: A wins / condition wins / tie, on the lines where the two orders agree, over all differing lines (judge `flash-low`);
"disagree" is the position-bias count; "sample" is `flash-medium` on 100 lines; "consensus" is the lines where both judges were consistent and
gave the same outcome. "Share" is the condition's share of decided lines with the Wilson interval; p is the sign test. Untranslated is the
accepted output lines that are their own source text (A of 436 to 445 lines).

### gemma3:4b (local small)

| condition | probes % (delta vs A, p) | judge vs A: A / cond / tie, disagree | share (95 % CI), p | sample A / cond | consensus A / cond | untranslated | latency p50 / p95 ms (A/A: 1084-1192 / 2526-2845) |
|:---|:---|:---|:---|:---|:---|---:|:---|
| A (off) | 25.6 | - | - | - | - | 7 | 1134 mean / 2705 mean |
| M, memory only | 41.3 (+15.7, <0.001) | 146 / 131 / 22, 79 | 47.3 % (41.5-53.2), 0.40 | 51 / 50 | 36 / 41 | 62 | 2210 / 4194 (+995 ms, p95 +55 %) |
| B2, previous 2 lines | 24.4 (-1.3, 0.66) | 170 / 94 / 29, 72 | **35.6 % (30.1-41.6), <0.001** | 55 / 35 (p 0.045) | 51 / 22 (p 0.001) | 76 | 2117 / 4143 (+921 ms, p95 +53 %) |
| B2+2, plus 2 lines below | 24.0 (-1.6, 0.57) | 176 / 116 / 22, 58 | **39.7 % (34.3-45.4), <0.001** | (cut, 8 / 8 of 19) | 7 / 6 of 13 | 84 | 2146 / 4055 (+883 ms, p95 +50 %) |
| M against B2 | | B2 76 / M 138 / 16, 49 | M 64.5 % (57.9-70.6), <0.001 | 35 / 56 (p 0.035) | 29 / 46 (p 0.064) | | |
| B2+2 against B2 | | 18 / 18 / 3, 7 | 36 decided: too few | | | | |

By whether a side copied the line back (`judge-report.py --echo`, judge low), M against A: on the 330 lines both translated, M wins 131 to 103
(56 %); on the 46 lines only M copied back, A wins 43 to 0. B2: 94 to 111 on 300 lines both translated, A wins 59 to 0 on the 63 lines B2
copied back. B2+2: 116 to 112 on 304, A wins 64 to 0 on 66. **The judge's tie between M and A is two effects that cancel: the memory improves the
translated lines, and the product layout makes this model copy 14 % of the lines back.** The layout check agrees: the reference layout's M beats the
product layout's M (product share 40.0 %, 110 to 165, p 0.001; the product M loses 43 of the 49 lines it alone copied back, the other 6 split by order).

### gemma4:e4b (local, as it is: no fold, no per-model rule)

| condition | probes % (delta vs A, p) | judge vs A: A / cond / tie, disagree | share (95 % CI), p | sample A / cond | consensus A / cond | untranslated | latency |
|:---|:---|:---|:---|:---|:---|---:|:---|
| A (off, today's request) | 23.4 | - | - | - | - | 142 | not a verdict: no A/A (a `swift test` shared the machine) |
| M | 66.3 (+42.9, <0.001) | 18 / 287 / 28, 48 | **94.1 % (90.9-96.2), <0.001** | 6 / 81 | 3 / 78 | 4 | 350 in / 51.5 out tokens (A 92 / 35) |
| B2 | 45.8 (+22.4, <0.001) | 21 / 265 / 40, 52 | **92.7 % (89.0-95.1), <0.001** | 5 / 80 | 2 / 71 | 2 | 310 in / 51 out |
| M against B2 | | B2 28 / M 112 / 31, 32 | **M 80.0 % (72.6-85.8), <0.001** | 17 / 59 | 8 / 47 | | |

B2+2 was not run (233 of 252 requests are byte-identical to B2). **Most of e4b's gain over A is the product layout curing the echo of today's
request**, not the context: the lines where only A copied back (123 of 378) go to B2 112 to 0, and on the 255 lines both translated B2 still wins
153 to 21. Against the folded A (36.2 %, the previous round) B2 is +9.6 and M +30.1 on probes. The product layout also beats the reference layout on this model
(B2: product share 86.5 %, 218 to 34; M: 59.9 %, 115 to 77).

### claude-haiku-5-5 (cloud)

| condition | probes % (delta vs A, p) | judge vs A: A / cond / tie, disagree | share (95 % CI), p | sample A / cond | consensus A / cond | untranslated | latency p50 / p95 ms (A/A: 1016-1046 / 2282-2381) |
|:---|:---|:---|:---|:---|:---|---:|:---|
| A (off) | 43.6 (A/A 43.3) | - | - | - | - | 4 | 1031 mean / 2332 mean |
| M | **63.8 (+20.2, <0.001)** | 64 / 177 / 62, 91 | **73.4 % (67.5-78.6), <0.001** | 19 / 56 | 10 / 44 | 6 | 1221 / 3982 (+136 ms, p95 +71 %) |
| B2 | 44.6 (+1.0, 0.79) | 101 / 125 / 59, 87 | 55.3 % (48.8-61.6), 0.13 | 37 / 41 | 30 / 33 | 15 | 1554 / 4201 (+328 ms, p95 +80 %) |
| B2+2 | 43.9 (+0.3, 1.0) | 101 / 107 / 75, 83 | 51.4 % (44.7-58.1), 0.73 | (cut) | | 14 | 1258 / 4187 (+166 ms, p95 +80 %) |
| M against B2 | | B2 61 / M 163 / 64, 77 | **M 72.8 % (66.6-78.2), <0.001** | 23 / 54 | 13 / 48 | | |

On the lines both translated, B2 wins 121 to 89 (58 %) and B2+2 105 to 89 (54 %): a small edge that the 15 and 14 lines B2 copies back
(against 4 for A) take away, and that probes do not see (+1.0).

## Decision rule (design section 5) applied

"The cheapest condition within 2 points of the best probe accuracy that is not worse on the judge, and which beats A with p < 0.05 on >= 250 probes
and >= 150 decided judge pairs." Cost order: Off < memory-only < nearby < transcript < conversation. No decision is made from a number a second
judge contradicts; none did.

| tier (what was measured) | best by probes | within 2 points of the best | not worse than A on the judge | beats A (probes p, judge decided) | answer |
|:---|:---|:---|:---|:---|:---|
| local small (gemma3:4b) | M 41.3 | M only (B2 24.4, B2+2 24.0 are 17 points behind) | M yes (47.3 %, CI 41.5-53.2); B2, B2+2 **no** (A wins 64 % and 60 %, p < 0.001) | M: +15.7, p < 0.001, 277 decided | **memory-only** |
| local large (gemma4:e4b; 26b not measured) | M 66.3 | M only (B2 45.8) | M yes (94.1 % for M) | M: +42.9, 305 decided | **memory-only**, with the echo caveat below |
| cloud (claude-haiku-5-5) | M 63.8 | M only (B2 44.6, B2+2 43.9) | all three; B2 and B2+2 are level with A | M: +20.2 p < 0.001, 241 decided; B2: +1.0 p 0.79, 226; B2+2: +0.3 p 1.0 | **memory-only** |

Section 9 checks on the candidates (not worse on probes; zero context leaks; p95 within +20 %):
- Transcript (B2) and nearby (B2+2): **not recommended in any tier.** They never beat A on probes outside e4b (and there the gain is the layout
  curing the echo, not the lines), they lose the judge on gemma3, they tie it in the cloud, they cost +50 to +80 % at p95 and 3 to 4 times the tokens,
  and they copy more lines back (76 and 84 against 7 on gemma3; 15 and 14 against 4 on Haiku).
- Memory-only: the +55 % (gemma3) and +71 % (Haiku) p95 fail the +20 % rule on the two tiers that have a latency verdict (e4b has none). It is acceptable only because D1 sends it **only when the app's profile
  has a note or entries** (nothing is sent, so nothing is paid, for a user without one) and the gain is large where it applies (probes +15.7, +42.9,
  +20.2; the memory-only probes, which A cannot know, 15 -> 54, 18 -> 76, 32 -> 74).

## Recommended default per engine tier

| tier | Off | memory-only | nearby (N lines below) | transcript (previous N lines) | conversation N |
|:---|:---|:---|:---|:---|:---|
| local small | the default for everyone | **on when the profile has memory** (D1) | **off** | **off** | **undecided**: not run on the product layout |
| local large | the default for everyone | **on when the profile has memory** (D1), measured on e4b only; 26b **undecided** (not run: 18 GB on a 32 GB Mac that was already swapping) | **off** | **off** | **undecided** |
| cloud | the default for everyone | **on when the profile has memory** (D1) | **off** | **off** | **undecided**; DeepL and Apple Foundation Models not measured |

So: the default path stays Off, memory-only follows the profile (as decided in D1, now with a judge behind it), and the engine row's "Use context"
(previous lines, nearby) should stay an opt-in that the UI does not suggest. "Undecided" stands where the bench has not run the condition on the
product layout (conversation, L, W), not where the judge was unsure.

Two findings the lead should weigh before making memory-only more prominent:
1. **On gemma3:4b the product layout copies 14 to 19 % of the lines back untranslated** (62 for M, 76 for B2, 84 for B2+2 of 445, against 7 for
   A), and the judge sees it: M ties A only because the memory's gain on translated lines (56 %) cancels the copied lines. The reference layout
   copies 14. The previous round's diagnostic could not isolate the cause (rules length, card, items-only variants). A fix at the tier level (shorter rules for
   the local tier, which `RequestLayout` already budgets by tier) would turn the tie into a win; it would be a layout change, not a per-model rule.
2. **gemma4:e4b copies 142 of 436 lines back under today's request** and 2 to 4 under the product layout. The "Off" path of an e4b user is
   therefore the worst of the four conditions; the judge prefers B2 over A 92.7 %. This is the default path, so it is the lead's call (a
   no-regression gate would be needed), but it says the product layout's structure helps small local models even with no context in it.

## What this round does not show

- `gemma4:26b` on the product layout, conversation windows (C), learned terms (L) and the window-only condition (W) on any model, DeepL, Apple
  Foundation Models, TranslateGemma.
- The judge is a Gemini Flash model at low and medium thinking, not the spec'd high one: a screen backed by a 95 % low/medium agreement on
  self-consistent lines, a passed known-answer check, and a 70 to 75 % single-answer agreement with a human-style reader. The sample judge
  (medium) covers 100 lines per pair, not all.
- 14 sequences, 445 lines: a probe or a judge result moves with the corpus. The probe sign test needs >= 250 probes; the corpus has 312.

## Data

- Cloud runs: `runs/A-haiku-5-5`, `A-haiku-5-5-r2`, `M-haiku-5-5-t2`, `B2-haiku-5-5-t2`, `B2+2-haiku-5-5-t2` (manifests; `runs.py verify` "47 checked, 0 failed").
- Judge passes: `runs/_judge/2026-10-19-t3j/{low,medium,high}/<pair>/{key.json, verdicts.jsonl, run.json, calls/*.json}` (raw answers of every
  try, prompts left out: `sh judge-pairs.sh` regenerates the pairs and `judge-run.py` with its default seed 11 the batches), `tally-low.txt`,
  `tally-medium.txt`, `self-blind-20/` (the 20 cases, my verdicts, agy's three answers).
- Reproduce a table: `python3 -I judge-report.py runs/_judge/2026-10-19-t3j --models low,medium [--echo]`.
