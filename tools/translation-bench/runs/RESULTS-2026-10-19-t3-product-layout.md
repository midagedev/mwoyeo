# T4 minimum: the context conditions on the product's layout (2026-10-19, round t3-bench-product)

Written once, by hand, from the preserved runs named below (all under `runs/`); the numbers come from `score.py`, `latency.py`
and `summary.py`, so `runs/SUMMARY.md` has the same figures. The runs are `--layout t2`: the bytes `RequestLayout.body` gives (README,
"The seam for T2"), not the bench's own prompt. Nothing here changes a default: the table is the report, and the decision rule
(design section 5) is **undecided** until the judge pairs (last section) are judged.

## What was run

312 planted probes, 252 requests per run, jobs 1, batches of at most 3, Ollama on an M1 Pro with 32 GB shared with other
sessions (18 users logged in, load average 5 to 30, swap 16 to 20 GB of 21.5 GB used the whole time). `matrix.sh` recorded the machine state in each
manifest.

| model | A | M, product | B2, product | B2+2, product | A/A repeats |
|:---|:---|:---|:---|:---|:---|
| gemma3:4b | `A-gemma3-4b` (T1, 10-18) | `M-gemma3-4b-t2` | `B2-gemma3-4b-t2` | `B2+2-gemma3-4b-t2` | `AA1`, `AA2`, `AA3-gemma3-4b`: condition A on 7 of the 14 sequences (122 requests), interleaved with the runs above (`smoke` kind: a subset's probe accuracy is not a result) |
| gemma4:e4b, as it is (no fold) | `A-gemma4-e4b` (T1) | `M-gemma4-e4b-t2` | `B2-gemma4-e4b-t2` | not run: 233 of 252 requests are byte-identical to B2 (below) | none: its latency is not a verdict |
| gemma4:26b | `A-gemma4-26b` (T1) | **not run**: 18 GB, and the Mac had 1.3 to 1.7 GB of swap left; loading it would have swapped out the other sessions | | | |

Sizing: 6 gemma3:4b runs (3 full, 3 of 122 requests), 2 gemma4:e4b runs, 8 in all, 72 minutes of wall (13:50 to 15:02 KST).
Reference-layout runs of the same models (`M-gemma3-4b`, `M-gemma4-e4b`, `B2-gemma4-e4b`) are T1's; there is no reference B2 for gemma3:4b.
`oracle-B2-t2`, `oracle-B2+2-t2`, `oracle-M-t2` are the size accounting of the product layout with no model (all 312 probes pass).

Two facts about the corpus that shape the table:
- **B2+2 is B2 on 233 of 252 requests.** The screens add their new lines at the bottom, so a batch has lines below it only in 19
  requests. The two runs' outputs are identical on all 233 identical-body requests and differ on all 19 (checked line by line): this
  is also the run-to-run determinism check of the quality numbers (temperature 0, same request sequence: no difference).
- **The product has no speaker channel.** The app sends OCR lines, so a line does not say who said it; the reference layout sends
  `speakers` and labels its context lines. The memory's `speaks_to` reaches the model only through a row whose name appears in the lines.

## Predictions written before the first run (`/tmp/t3b/predictions.md`) and what came out

Decomposition: wall = prefill + decode on the one GPU, serial. Measured before the runs on gemma3:4b through `/api/chat`: prefill
2.0 to 2.2 ms per prompt token (three requests that shared a 240-token prefix each re-evaluated all 278 tokens: no prefix reuse, the
model has sliding-window attention), decode 22 ms per output token (33 tokens in 755 ms). The lead's +300 ms counted only the
reference layout's +225 prompt tokens; the product's rules are ~240 tokens and its reply `{"t":[{"id","text"}]}` costs more output tokens.

| term (gemma3:4b, per request, full corpus) | predicted | measured |
|:---|:---|:---|
| prompt tokens, B2 | 305 +- 40 | 315 (A 97.5) |
| prompt tokens, M | 395 +- 50 | 355 |
| prompt tokens, B2+2 | 340 +- 40 (written without the 19/252 factor; corrected before that run: B2 + 3) | 317 |
| output tokens | 46 +- 5 | 53.4 to 53.9 (A 39.9): the miss is +8 |
| median latency delta over the A/A mean, M | +900 +- 250 ms | **+995** |
| ... B2 | +710 +- 200 | **+921** (11 ms above the band) |
| ... B2+2 | +775 +- 200 (corrected: = B2) | +883 |
| lead's prediction | +300 +- 330 | missed by 600 to 700 ms; the A/A noise is 108 ms (spread of the p50s) |
| M accuracy vs the reference layout, gemma3:4b | -5 +- 6 (lead: +-3) | **-0.7** (41.3 vs 42.0, p = 0.90) |
| B2 accuracy, gemma3:4b | 27.5 +- 4 | 24.4 |
| M accuracy, gemma4:e4b | 55 +- 8 | **66.3** (reference 59.3: +7.1, p = 0.001) |

Check of the decomposition on the measured counts (gemma3:4b, M): +257 prompt tokens x 2.1 ms = 540 ms, +14 output tokens x 22 to 33
ms = 310 to 460 ms, sum 850 to 1000 ms; measured +995.

## Accuracy

Probe accuracy, 312 probes; "delta" is against condition A of the same model (sign test), "vs ref" against the same condition on the
bench's own layout.

| model | run | probes % | memory % | lines % | none % | delta vs A (pts) | p | vs ref (pts) | p |
|:---|:---|---:|---:|---:|---:|---:|---:|---:|---:|
| gemma3:4b | A | 25.6 | 15.1 | 19.5 | 66.0 | - | - | - | - |
| | M, reference (T1) | 42.0 | 55.6 | 18.0 | 69.8 | +16.3 | <0.001 | - | - |
| | **M, product** | 41.3 | 54.0 | 20.3 | 64.2 | **+15.7** | <0.001 | -0.6 | 0.90 |
| | **B2, product** | 24.4 | 13.5 | 21.1 | 58.5 | -1.3 | 0.66 | | |
| | **B2+2, product** | 24.0 | 14.3 | 22.6 | 50.9 | -1.6 | 0.57 | | |
| gemma4:e4b | A | 23.4 | 18.3 | 15.0 | 56.6 | - | - | - | - |
| | B2, reference (T1) | 27.6 | 21.4 | 19.5 | 62.3 | +4.2 | 0.019 | - | - |
| | M, reference (T1) | 59.3 | 71.4 | 36.8 | 86.8 | +35.9 | <0.001 | - | - |
| | **B2, product** | 45.8 | 31.0 | 42.1 | 90.6 | **+22.4** | <0.001 | +18.3 | <0.001 |
| | **M, product** | 66.3 | 76.2 | 45.9 | 94.3 | **+42.9** | <0.001 | **+7.1** | 0.001 |

M over B2 on the product layout: gemma3:4b +17.0 pts (p < 0.001), gemma4:e4b +20.5 pts (p < 0.001). Against the folded A of
gemma4:e4b (`A-gemma4-e4b-fold`, 36.2) the product's B2 is +9.6 and M +30.1: most of e4b's +22 for B2 is the product layout curing
the echo of today's request (below), not the transcript.

Failures, leaks and **untranslated lines** (the number that does not show in probe accuracy):

| model | run | failed attempts | fallback + empty lines | context leaks | echoed lines (own source text) of accepted |
|:---|:---|---:|---:|---:|---:|
| gemma3:4b | A | 22 | 0 + 25 | 0 | 7 of 420 |
| | M, reference | 25 | 38 + 8 | 0 | 14 of 437 |
| | M, product | 7 | 17 + 0 | 0 | **62** of 445 |
| | B2, product | 9 (1 timeout of 304 s) | 23 + 0 | 1 | **76** of 445 |
| | B2+2, product | 7 | 17 + 0 | 1 | **84** of 445 |
| gemma4:e4b | A | 6 | 0 + 9 | 0 | 142 of 436 |
| | B2 / M, reference | 9 / 7 | 19 + 0 / 13 + 0 | 1 / 0 | 124 / 26 |
| | B2, product | 0 | 0 + 0 | 0 | 2 of 445 |
| | M, product | 0 | 0 + 0 | 0 | 4 of 445 |

- On gemma3:4b the product layout trades the empty lines of today's request (25 lines whose JSON reply failed to parse) for lines the model
  copies back untranslated: 62 to 84 of 445 lines, 14 to 19 %, against 7 for A and 14 for the reference M. Probe accuracy does
  not see it (the probes are planted on a fraction of the lines); a judge will. Whole requests echo at once (chat-ja-ko-1 requests 4, 5
  and 7 of M). A diagnostic on 18 lines (the bodies of requests 4 to 10, each with one part removed) could not isolate a cause:
  as sent 3, without context_before 6, without memory 3, without the card 4, with short rules 2, items only 1, items only with short
  rules and no card 0 echoed; the same request gave different output on a different cache state, so those counts are a hint, not evidence.
- The lines below (B2+2) made 8 more lines echo on the 19 requests they touch.
- gemma4:e4b is the reverse: today's request echoes 142 of 436 lines; the product layout echoes 2 to 4 and has no failed attempt.
- One B2 request on gemma3:4b (chat-zh-ko-1 request 1) ran to the 300 s timeout and then fell back: a stall the A/A runs do not have.
  The app has its own deadline; here it is the engine file's `timeoutSeconds`.

## Latency, with the A/A self-check (gemma3:4b)

`python3 -I latency.py --aa runs/AA1-gemma3-4b runs/AA2-gemma3-4b runs/AA3-gemma3-4b -- runs/M-gemma3-4b-t2 runs/B2-gemma3-4b-t2 "runs/B2+2-gemma3-4b-t2"`
(7 sequences, 122 requests each, paired by request):

| run | role | mean ms | p50 ms | p95 ms | tokens in | tokens out | stalls | median delta (ms) | p95 vs A/A mean | verdict |
|:---|:---|---:|---:|---:|---:|---:|---:|---:|---:|:---|
| AA1 | A/A | 1486 | 1192 | 2845 | 103 | 44 | 0 | +68 | | |
| AA2 | A/A | 1440 | 1125 | 2745 | 103 | 44 | 0 | -12 | | |
| AA3 | A/A | 1373 | 1084 | 2526 | 103 | 44 | 0 | -57 | | |
| M, product | tested | 2596 | 2210 | 4194 | 357 | 57 | 0 | **+995** | +55 % | resolved (9.2x the A/A spread of the p50s) |
| B2, product | tested | 4955 (one 304 s stall) | 2117 | 4143 | 317 | 56 | 1 | **+921** | +53 % | resolved (8.5x) |
| B2+2, product | tested | 2417 | 2146 | 4055 | 320 | 56 | 0 | **+883** | +50 % | resolved (8.1x) |

- A/A spread: 108 ms in the p50 (1084 to 1192), 113 ms in the mean, 320 ms in the p95. The three repeats were taken before, between and
  after the product runs, 44 minutes apart, under a load average of 5 to 30.
- The product layout costs **+880 to +995 ms per request (+78 to +88 % of the A/A median 1134 ms)** and **+50 to +55 % at p95**. Design
  section 9's rule is p95 within +20 %: the transcript (B2) and neighbours (B2+2) **fail it** on gemma3:4b, and so does M, which is not
  a default candidate anyway. The lead's +300 ms +- 330 is outside this by a factor of 2 to 3.
- The earlier `A-gemma3-4b` and `A-gemma3-4b-r2` of T1 (hours and a day away) are +431 and +239 ms slower than today's A/A mean on the
  same requests: a latency compared across days on this Mac is not a measurement.
- gemma4:e4b has no A/A: its runs overlapped a `swift test` of Core and the load went 34 to 7.5 (M) and 7.5 to 7.6 (B2); its p50
  (2262 and 2195 ms against 1532 for T1's A) and its M p95 of 8647 ms are the load shown, not a verdict. Tokens are exact:
  310 in / 51 out (B2), 350 in / 51.5 out (M) against 92 in / 35 out for A.

## Resource timeline, per request (gemma3:4b, the median M request: 2.2 s)

| resource | busy (ms) | note |
|:---|---:|:---|
| host CPU | < 1 | `RequestLayout.body` and the JSON parse; not separately timed here (the layout tests run 35 cases in 1 s) |
| GPU, prefill | ~750 (355 tokens x 2.1; A: ~200) | serial before decode; no prefix reuse on this model |
| GPU, decode | ~1200 to 1800 (54 tokens x 22 to 33; A: 0.9 to 1.3 s) | bandwidth-bound: 3.4 GB of weights per token |
| PCIe | 0 | unified memory |
| host DRAM | decode reads the weights once per token (~150 GB/s of the 200 GB/s peak) | under the GPU's shadow |
| NVMe | 0 after the one 2.8 s model load of the warm-up | |

The wall is prefill + decode on one resource, not a max over several; the host and the DRAM are under the GPU's shadow, so a lever on
them predicts 0. Levers, in the order of their size (all in Core's layout, none applied here): a prefix cache that survives on
gemma3/gemma4 (sliding-window attention defeats Ollama's: the 240-token rules would be paid once per sequence, about -500 ms per
request); a reply without ids (the same text as `{"translations": [...]}`, about -10 output tokens, -250 to -330 ms); shorter rules for the
local tier (each 100 tokens are 210 ms); larger batches (1.76 lines per request on this corpus, so the fixed rules cost 0.28 s per line).

## Decision rule (design section 5) and the section 9 checks

- Pick the cheapest condition within 2 points of the best that is not worse on the judge, and which beats A with p < 0.05 on >= 250
  probes. By probe accuracy alone: gemma3:4b, best M (41.3); only M is within 2 points and only M beats A; B2 and B2+2 do not beat
  A (-1.3, -1.6). gemma4:e4b, best M (66.3), B2 is 20.5 points behind; M. **Judge: none yet, so the rule's answer is undecided.**
- Section 9, transcript and neighbours on by default: not worse on probes (B2: -1.3, p = 0.66; B2+2: -1.6, p = 0.57, both within noise but
  not better), zero context lines leaked (B2: 1 and B2+2: 1 leaked context line; A: 0), p95 within +20 % (**+53 % and +50 %**).
  Two criteria fail, and the untranslated-line count is 9 to 12 times A's. They stay opt-in, as the code has them.
- What this round does not show: any cloud, DeepL or Apple Foundation Models result, gemma4:26b, B2/M on translategemma, or a judge.

## Judge pairs, ready for the lead

`sh judge-pairs.sh <out dir>` regenerates them from the preserved runs (deterministic); a copy made at the end of this round is in
`/tmp/t3b/judge/<pair>/{prompts,key.json}`. Items are lines whose two translations differ, plus 4 calibration items; prompt files are two
per item (both orders). In the order the decision needs them (>= 150 decided pairs per comparison):

| pair | items | prompt files |
|:---|---:|---:|
| gemma3-4b-A-vs-M-t2 | 382 | 764 |
| gemma3-4b-A-vs-B2-t2 | 369 | 738 |
| gemma3-4b-B2-t2-vs-M-t2 | 283 | 566 |
| gemma3-4b-M-ref-vs-M-t2 (layout check) | 393 | 786 |
| gemma3-4b-B2-t2-vs-B2+2-t2 | 50 | 100 (too few to decide by the rule) |
| gemma4-e4b-A-vs-M-t2 | 385 | 770 |
| gemma4-e4b-A-vs-B2-t2 | 382 | 764 |
| gemma4-e4b-B2-t2-vs-M-t2 | 207 | 414 |
| gemma4-e4b-M-ref-vs-M-t2 (layout check) | 320 | 640 |
| gemma4-e4b-B2-ref-vs-B2-t2 (layout check) | 355 | 710 |

The gemma3:4b pairs that matter most are A-vs-M-t2 and M-ref-vs-M-t2: the probes see M product equal to M reference, the echo count says
otherwise (62 vs 14), and only a judge can say which weighs more.
