# translation-bench

A bench that measures what context does to LLM translation of screen text: quality (planted probes, scored by script),
cost (tokens, prefix vs volatile) and latency. It blocks one failure mode: **a context default chosen without
measurement** (design/context-translation.md section 5; `docs/design/context-translation.md` in the main tree).

The corpus is written for the bench (no third-party text). The runner replays each sequence the way the lens does
(screen by screen, batches of up to three new lines in reading order), one condition and one engine at a time.

## Layout

| Path | What |
|---|---|
| `sequences/<id>.json` | one sequence: lines, screens, probes |
| `memory/<id>.json` | the user memory for that sequence, hand-written as a user would fill it in |
| `memory-named/<id>.json` | `memory/` with a target form (`dst`) authored for every entity that had none, for `--apply` runs (`--memory-dir memory-named`) |
| `validate.py` | format and corpus gates (`python3 -I validate.py`) |
| `runner/` | SwiftPM executable `bench-run`, depends on `../../../Core` (path dependency) |
| `engines/*.json` | engine configs (kind, base URL, model; keys come from env only) |
| `score.py` | scorer and shared library (`python3 -I score.py <run dir>...`) |
| `judge.py` | blind pairwise judge prompts and the tally |
| `judge-pairs.sh` | the judge prompt directories of the product-layout pairs, regenerated from the preserved runs (`sh judge-pairs.sh <out dir>`) |
| `judge-report.py` | tallies of preserved judge passes: per pair and judge model, plus the consensus of the models and the split by lines copied back untranslated (`python3 -I judge-report.py runs/judge-<date> [--echo]`) |
| `judge-run.py` | runs a `judge.py` pair through the agy CLI (`gemini-3.8-flash-high`) in batched calls, both orders; the known-answer check of the judge (`python3 -I judge-run.py run\|known-answer\|known-answer-tally`) |
| `runs.py` | preserves a run into `runs/` with a manifest; `verify` and `list` (`python3 -I runs.py ...`) |
| `matrix.sh` | one condition on one Ollama model, then `runs.py add` with the machine state (load, pageouts, swap, `ollama ps`) in the note |
| `cloud.sh` | one condition on one cloud engine, then `runs.py add` (the key comes from the engine file's `keyEnv` variable in the environment) |
| `summary.py` | regenerates `runs/SUMMARY.md` from the preserved runs (`--check` fails when it is stale) |
| `particles.py` | the Korean particle check of a source-rewriting run (`--apply both` or `both-names`) and the one-character-row check (`python3 -I particles.py <run dir>...`) |
| `both_bench.py` | the both-bench analysis: a run's lines split into rewritten / untouched, names kept, probes, echoes, particle breaks per arm, and the judge tally by line class (`python3 -I both_bench.py table ...`, `judge ...`) |
| `latency.py` | the latency verdict with an A/A self-check: a condition's per-request delta against repeats of condition A, and the repeats' own spread (`python3 -I latency.py --aa <A run>... -- <run>...`) |
| `runs/<run-name>/` | the preserved experiment data: every run worth a number, with its `MANIFEST.json` |
| `runs/SUMMARY.md` | the tables of every model run; generated, never hand-edited |
| `prices.json` | price table, with the source of each price |
| `tests/` | scorer and judge unit checks, golden mini-sequence |

## Sequences, memories and probes

### Sequence (`sequences/<id>.json`)

```json
{
 "id": "chat-ja-ko-1", "kind": "chat", "source": "ja", "target": "ko",
 "title": "one English line for the reader",
 "speaker_visible": true,
 "lines": [
  {"id": 1, "speaker": "ミナ", "to": "海", "text": "みんな、今週末の合宿どうする?", "ref": "다들, 이번 주말 엠티 어떻게 할래?", "noise": "cut"}
 ],
 "screens": [[1,2,3,4,5,6],[4,5,6,7,8,9]],
 "probes": [ ... ]
}
```

- `kind`: `chat`, `subtitles`, `game` or `docs`. `source` and `target`: `ja`, `zh`, `en` or `ko` (the runner maps `zh` to
  `zh-Hans`, as the app does).
- `lines`: 15-40, ids `1..n` in order. `text` is what the lens would read (OCR output); `ref` is a skilled human's
  translation, the oracle the probes are validated against. `speaker` is the name as shown on screen (an entity of the
  memory). `to` names the addressee; leave it out when the speaker uses one speech level to everybody (or the chat has two
  speakers). `noise` marks an OCR-like line (`cut`: a word cut at the edge, `symbol`: a stray mark, `typo`: a misread
  character); the `ref` is the clean translation.
- `screens`: lists of line ids visible together, in reading order. Consecutive screens overlap as a scroll does. Lines are
  translated when they first appear, so the lines a screen adds must continue the ids already shown. A chat screen holds 5-7
  lines and advances by 2-4; subtitles show 1-2 lines; a game text box 1-3; a docs page 6-10 and scrolls by 3-5.
  The runner forms batches of at most 3 new lines per screen in reading order, as `RegionPipeline.nextBatch` does.
  Above and below neighbours on screen are derived from these lists.
- `speaker_visible` (default true): false for subtitles, where the lens cannot tell who speaks. The runner then sends no
  speaker labels, and no speech-level probe may be decided by the memory (the memory cannot say who speaks).

### Memory (`memory/<id>.json`)

```json
{
 "entities": [{"name": "海", "reading": "かい", "dst": "카이", "gender": "male", "role": "club senior",
               "speaks_to": {"ミナ": "반말"}}],
 "document": {"title": "", "domain": "", "summary": ""},
 "window": {"title": "テニス部 合宿どうする?", "app": "LINE", "category": "Social Networking"},
 "terms": [{"src": "合宿", "dst": "엠티"}]
}
```

- `entities`: people or characters. `name` as it appears in the source text, `reading` (kana, pinyin, or the romanization
  the user wants), optional `dst` (the user's chosen target rendering), `gender` (`male`, `female`, `nonbinary`), `role`
  (a few English words), `speaks_to`: `{addressee name: speech level}` with levels `해요체`, `합쇼체`, `반말` (Korean targets).
- `document`: `title`, `domain`, `summary` (one line). `window`: `title`, `app`, `category` as the OS would give them
  (the app's name and its App Store category, such as `Social Networking`, `Productivity`, `Developer Tools`, `Games`,
  `Entertainment`, `Reference`, `Education`, `Business`).
- `terms`: `src -> dst` pairs the user pinned.
- Rendered by `score.render_memory` (the runner renders the same text) it must stay **under 150 tokens** (script-aware
  estimate). Leave a section out when the user would not fill it in; chats usually have `entities`, `window`, `terms`;
  subtitles and games add `document`; docs have `document`, `window`, `terms` and no `entities`.

### Probe

```json
{"id": "p14", "type": "name", "line": 16, "by": "lines", "need": [13], "evidence": ["湊(そう)"], "key": "ent:湊",
 "check": {"any": ["소우"], "none": ["미나토"]}, "bad_sub": ["소우", "미나토"]}
```

- `type`: `name` (a name introduced, then reused), `pronoun` (a dropped subject or a gendered form that only an earlier line
  or the memory decides: she/he, the honorific `-시-`, 오빠/형, 언니/누나), `speech_level` (Korean target: the line must
  keep the speaker's level for that addressee), `term` (a term that must keep one rendering), `register` (a domain
  sense or register that only the document or window decides, e.g. "cell" in a spreadsheet).
- `by`: where the fact that decides the probe lives. `memory`: only in the memory, in no line (then B2, B4, C16 and A
  cannot know it). `lines`: only in earlier lines (`need` lists their ids), not in the memory. `none`: a control any
  engine should get right without context; it shows context does not break easy cases.
- `evidence`: the fact itself as a string. For `memory` it must occur in the memory's text and in no line; for `lines` it
  must occur in one of the `need` lines and not in the memory. `validate.py` enforces both. (`mem` lists the memory paths:
  `entities.<name>.<field>`, `terms.<src>`, `document.<field>`, `window.<field>`.)
- `key`: the entity or term the probe tests (`ent:<name>`, `term:<src>`, `reg:<word>`); required for `name`, `term`,
  `register`. Probes with one key are the repeats the carry-over count looks at.
- `check`: the machine check on the **target text of that one line**. All given keys must hold: `any` (some string occurs),
  `none` (no string occurs; list the likely wrong renderings, the scorer uses them for carry-over), `any_w` / `none_w`
  (the same as whole words, case-insensitive, for English targets), `regex`, `nregex`, `level` (`hapsyo`, `haeyo`,
  `banmal`: the Korean speech level by sentence endings, `score.line_level`). Matching is Unicode NFC and case-folded.
- `bad` (a full wrong rendering of the line) or `bad_sub` (`[from, to]` applied to the line's `ref`): the check must fail
  on it. `validate.py` also requires the check to pass on `ref` and to fail on the untranslated source, so every probe
  tests itself and the oracle scores 100 %.
- Lookback distance is derived: the lines between the probe and its nearest `need` line. It buckets the lines-evidence
  accuracy (1-2, 3-4, 5-8, 9-16, 17+), which is what sets the window size.

Speech level truth is the memory's `speaks_to`; `validate.py` requires every `ref` of a Korean target to end at the
speaker's level for that addressee.

Write natural language a native would find plausible; keep lines short and varied; keep a few OCR noise lines.

## Conditions

One condition and one engine per run. Names are parsed by `ConditionSpec.parse` (`bench-run conditions` prints them).

| Name | Request |
|---|---|
| `A` | off: today's request, built by MwoyeoCore, byte for byte |
| `B2`, `B4` | + the previous 2 or 4 source lines (with speaker labels where the lens can see them) as context |
| `B2+2` | + 2 lines below the batch on the same screen (design "Nearby") |
| `M` | B2 + the user memory (window, document, entities with `speaks_to`, terms) in the system prompt |
| `W` | B2 + the window metadata only (title, app, category) |
| `L` | B2 + a learned memory: `terms` the model returned in earlier replies, admitted by the gpt-subtrans guard (the source is in this batch, the target is in this reply), first seen kept, a term contradicted twice dropped; never the user's facts |
| `C16` | a conversation of up to 16 source lines, append-only, the older half dropped when full (`C8`, `C32` likewise) |

`M4`, `W4`, `L4` use 4 previous lines instead of 2. Design section 5's D and E (translations in the context) and F (term
memory on any window) are not in the 2026-10-18 addition; `Turn.trusted` and `ThreadState` carry what they need.

### The seam for T2 (`runner/Sources/BenchKit/Conditions.swift`, the one file)

Condition A never touches it. Every other condition goes through a `ContextLayout`:

- `ReferenceLayout` (default, `--layout reference`) is the bench's own prompt layout over today's chat request: rules and
  the notes in the system prompt, the context lines first in the user JSON (`{"context": [...], "lines": [...],
  "speakers": [...]}`, so a window that only grows keeps a common prefix), the items last. It exists so the bench runs end to
  end now and the probes can be checked on real models (the memory-only probes must stay near chance under A, B2, B4, C16
  and rise under M). It is not the product's layout.
- `TranslateGemmaLayout` (`--layout tg`) is a bench variant for TranslateGemma, whose prompt format is not the app's JSON
  request: one user message (Ollama's template turns a system message into a second user turn), the model card's
  instruction ("You are a professional X (x) to Y (y) translator ... Produce only the Y translation ..."), the user's
  notes, the context lines and the speakers between the instruction and the lines, and a reply that is one translation per
  line. A count that does not match falls back to today's JSON request like any failed attempt. Condition A is left alone,
  so `A` is the same run under either layout; `L` is refused. The `tg` runs measure whether TranslateGemma uses memory when
  it is asked in its own format; they are not the product's layout.
- `T2Layout` (`--layout t2`, 2026-10-19) **is the product's layout**: it does not write a prompt. A `Step` becomes the
  `ContextRequest` that `ContextBook.request` hands `EngineClient` and the `ContextOptions` of the engine's "Use context"
  switch (`ContextOptions.from(engine: EngineContext(enabled: true, previousLines: n))`), and `RequestLayout.body` for the engine's
  kind (`EngineFile.layoutKind`) returns the bytes, which go out as `Prompt.bodyOverride`. The rules, the card, the note, the rows
  and the `{"t": [{"id", "text"}]}` reply are Core's. Its inputs are what the lens can see, which is why its numbers differ from
  `reference` for reasons other than the prompt text:
  - the **card** (app, category word, normalised window title) is built from `memory.window` and goes out on every context
    request, `B` included: the product always sends it. `W` is therefore refused (`B` already is `W`).
  - `M` adds the **note** (`memory.document` as `title; domain; summary`) and the **rows** (each entity a person row with
    gender, role as the row note, reading and, where `speaker_visible`, who it speaks to and in which register; each term a
    term row). A row goes out only when its name occurs in the items or in the lines around them (`RequestLayout.selectRows`).
  - there is **no speaker channel**: the app sends OCR lines, so no line carries who said it (the reference layout sends
    `speakers` and labels its context lines). Speech-level and pronoun gains that need the speaker are lost here by design.
  - `B2+2` adds up to 2 lines below the batch on the screen. The corpus screens add their new lines at the bottom, so only 19
    of the 252 requests have any line below; the other 233 are byte-identical to `B2`.
  - `L` and `C<n>` are refused (learning and the long conversation are not run on the product layout in this round).
  `Prompt.contextIDs`, `historyText` and `memoryText` are read back from the finished body, so the leak counter and the size
  accounting see what the model saw. `tests/` (BenchKitTests, `ProductLayoutTests`) pin the bytes against a hand-written
  `ContextRequest` and against the app's own `EngineClient` posting to the mock server.

## Run

```sh
cd tools/translation-bench/runner && swift build -c release          # about 2 minutes cold, the Core package builds first
BIN=runner/.build/release/bench-run                                  # (or --scratch-path <dir> to keep .build out of the tree)
$BIN plan                                                            # batches of every sequence, no engine: 252 requests
$BIN run --engine engines/ollama-gemma3-4b.json --condition A --out out/A-gemma3-4b
$BIN run --engine engines/ollama-gemma3-4b.json --condition M --out out/M-gemma3-4b
python3 -I score.py out/A-gemma3-4b out/M-gemma3-4b                  # summaries, then the sign tests of the others against the first
python3 -I judge.py prompts --a out/A-gemma3-4b --b out/M-gemma3-4b --out judge/A-M
```

- **Engines** (`engines/*.json`): Mwoyeo's flat engine shape (`kind` `openAICompatible` / `anthropic` / `deepL`, `baseURL`,
  `model`, `thinking`) plus `keyEnv` (the environment variable that holds the key; a file never holds a key and a key is never
  printed), `price` (a key of `prices.json`; default: the model id), `cache` (`anthropic-auto`: top-level `cache_control`;
  `openai-key`: `prompt_cache_key` = sequence id) and `timeoutSeconds`. Extra kinds: `oracle` (replays each line's `ref`: the
  scorer's 100 % and the size accounting of any condition without a model) and `appleFoundationModels` (a CLI can use the
  on-device model when Apple Intelligence is on; one session per line as in the app; token usage is the bench's estimate).
  Cloud engines run only when their key variable is set (exit 3 otherwise). Ollama: `ollama serve`, then any model it lists
  (`ollama list`); llama-server: `llama-server -m <gguf>` and point `baseURL` at `http://127.0.0.1:8080/v1`.
- `timeoutSeconds` (default 300) is the longest a request may wait for its reply. A timeout is **not retried** (429, 5xx and other
  transport errors are, up to three times): a model that has not answered in that time at temperature 0 is looping and loops again.
  Two translategemma requests of the bench corpus do this (batch 7 of chat-ko-en-1 and batch 10 of game-ja-ko-1, both under B2),
  and without the limit the run stalled for 18 minutes on the first; the app's chat request sets no output cap. The failure report counts these as `timeout`. The translategemma and gemma4:26b engine
  files set 90.
- `foldSystem: true` in an engine file sends the system prompt and the user message as one user message (a probe of a model
  that ignores the system role; `A` under it is not today's request, so its run name says so).
- **Output** (`--out <dir>` = one condition on one engine): `meta.json` and one `<sequence id>.json` with the translation of
  every line and one record per request: the items, the context ids, every attempt (latency, retries, error), the raw reply,
  the usage (tokens in/out/cached/cache-write as the engine reports them) and the size split (below). A failed attempt
  (HTTP, parse, count; its raw reply is kept in `attempts[].reply` from 2026-10-19 on) is retried once as today's stateless request (design: break the chain on trouble); lines no attempt
  translated stay empty and count as wrong.
- `--jobs N` replays N sequences at once (sequences are independent threads). It shortens a quality run on an engine that
  serves requests in parallel; latency is not comparable across runs with different `jobs` (the scorer says so).
- `--seq id,id` runs a subset; `--batch n` changes the batch size (the app's is 3).
- `--memory-dir <dir>` reads the memories from `<root>/<dir>` instead of `memory/` (`memory-named`: every entity has its target form). It is
  recorded in `meta.json` (`memory_dir`), only when given.
- `--apply hint|both|both-names` (layout `t2` and a condition with the memory, `M`; absent is `hint`) sets how the memory's rows are applied
  (design names-and-context section 10): `hint` every row is a hint, today's request byte for byte; `both` every row (entities and terms) is
  `.both`; `both-names` entities `.both`, terms hints. A `.both` row goes out as a hint row as before, selected on the lines as the screen
  showed them (`RequestLayout.selectRows` matches a row's source against the items), and its target is also written into the item lines
  being translated: `ContextMemory.replaceRows`, then `ApplePreinsertion.insert` on each item (`BenchKit/Apply.swift`). The context lines
  (before and after) stay original, as the product leaves them. A request that failed and fell back to the stateless request carries no rewrite.
  Each request of such a run records `replaced` (`[{id, text, spans: [[matched, target]]}]`: the lines the engine saw rewritten); `meta.json`
  has `apply` and `replaced_lines`. The translations are keyed by the ORIGINAL lines, so `score.py` and `judge.py` read the sequences
  unchanged. A default run has none of these fields: its files stay what they were.
- `--dump-bodies <dir>` writes `<dir>/<sequence id>.jsonl`, the finished request body of every request (no key is in a body); `cmp` of two
  arms' dumps lists the sequences whose requests differ, which is how arms with identical requests are found and left out of the evidence.

## Runs (`runs/`): the experiment data is content

A run is the output of one `bench-run run`: the raw replies, latencies and usage of every request. It is what the bench
produces, so it is kept in the repository, not in a scratch directory. Layout:

```
runs/<run-name>/
  MANIFEST.json            what produced the run (below)
  meta.json                the runner's own record: condition, engine, model, layout, jobs, batch size, started, seconds
  <sequence id>.json       one per sequence: every request (items, raw reply, parsed translations, attempts, usage, size split)
runs/_corpus/<hash>/       the sequences, memories and prices.json a run was scored against, stored once per distinct corpus
```

**A run is never overwritten; a rerun gets a new name.** `runs.py add` refuses an existing name (exit 3) and leaves the stored
run untouched. Names: `<condition>-<model>` for a model run (`A-gemma3-4b`, `M-gemma3-4b`), `oracle-<condition>` for an
oracle run, a `-r2`, `-r3` suffix for a rerun of the same thing (a rerun is evidence of run-to-run noise, not a replacement).
A model name or a condition that changes the meaning of the run belongs in the name. Never edit a stored file; a mistake in a
manifest note is fixed in the note only and said so in the next commit message.

Preserve a run right after it ends, from the bench directory:

```sh
python3 -I runs.py add /tmp/out/M-gemma3-4b --engine engines/ollama-gemma3-4b.json --binary "$BIN" --env MWOYEO_MEMORY_SECRETS=1 \
   --command "MWOYEO_MEMORY_SECRETS=1 $BIN run --engine engines/ollama-gemma3-4b.json --condition M --out /tmp/out/M-gemma3-4b --root ." \
   --note "what it is, the machine load at start and end, any caveat"          # --kind oracle|smoke for a non-model run
python3 -I runs.py verify          # every run has a manifest, its files hash as recorded, score.py reproduces its summary
python3 -I runs.py list            # one line per run
python3 -I score.py runs/A-gemma3-4b runs/M-gemma3-4b     # the scorer reads a preserved run like any run directory
```

`[NOTE=...] [KIND=smoke] matrix.sh <bin> <scratch> <engine file> <run name> <condition> [bench-run options]` does the run and the `add` in one go for
an Ollama model: a warm-up request first (the load time is not in the first latency), `--jobs 1`, and a note tag
`[machine load1m start=.. end=.. pageouts +n swapouts +n swap_used_mb start=.. end=.. free_pct start=.. end=.. ollama_ps='..']`
that `summary.py` reads as the load caveat. `NOTE='...' matrix.sh ...` adds prose in front of the tag. Run names for models:
`<condition>-<model>` (`M-gemma4-e4b`), with `-tg` after the model for the `tg` layout (`M-translategemma-4b-tg`).

`runs/SUMMARY.md` is written by `python3 -I summary.py` (never by hand): per model and run, the probe accuracy overall, by
evidence and by type, the sign test against condition A of the same model (between runs on the same corpus snapshot only), speech-level
consistency, failed attempts by reason, fallbacks, empty lines, leaks, echoes, tokens per request, latency and the load it was
measured under. It has no timestamps, so the same runs give the same bytes; `tests/test_summary.py` and `run-all.sh` fail on a stale file.

`MANIFEST.json` holds (`manifest_version` 1):

| Field | Content |
|---|---|
| `run`, `kind`, `note` | the name; `model`, `oracle` or `smoke`; what the run is and what a reader must know (machine load, caveats) |
| `date`, `seconds`, `preserved` | the runner's start time (UTC), wall seconds, the time of preservation |
| `condition`, `layout`, `jobs`, `batch_size`, `sequences` | from `meta.json` |
| `command`, `command_cwd`, `env` | the exact command line as it was run, its working directory, the environment variables set (never a key) |
| `engine` | the engine config file, its content **without keys** (`keyEnv` names a variable; no value is ever stored), the engine name |
| `model` | name, full digest, `ollama list` id, size, parameter count, quantization, from the Ollama server at preservation time (a local model's digest is content-addressed, so it names the weights that ran) |
| `machine` | chip, memory, macOS, Ollama version at preservation time |
| `source` | `git_head` (`git rev-parse HEAD` of the checkout), `tree` (`uncommitted tools/translation-bench tree` or as committed), `runner_sha256` and the per-file hashes of `runner/Package.swift` and `runner/Sources/**/*.swift`, `runner_files_modified_after_run_start`, the `bench-run` binary's path, hash and build time when given |
| `corpus` | sha256 over `sequences/`, `memory/` and `prices.json`, the per-file hashes, the probe count, `snapshot` (the `runs/_corpus/<hash>/` copy the run is scored against), `files_modified_after_run_start` |
| `score_summary`, `score` | what `score.py` prints for this run alone (the lines) and its numbers (`--json`) |
| `files` | sha256 of every file of the run |

`oracle` runs are **not model output**: the oracle engine replays each line's reference translation, so every probe must pass.
They are a scorer self-check and the size accounting of a condition without a model (`verify` fails an oracle run below
100 %). A `smoke` run exercises an engine path and is not a result.

`verify` fails when a file changed, a file is not in the manifest, the manifest lacks a field, the corpus snapshot changed, or
`score.py` no longer prints the recorded summary from the copied files (the scorer changed). A run is scored against its own
corpus snapshot, so editing a sequence, a probe or a check later does not break an old run; `verify` prints a note that the
live corpus moved on, and new runs get a new snapshot. Probe accuracy of runs on different snapshots is not comparable:
`score.py` scores against the live corpus unless given `--root runs/_corpus/<hash>`, so rerun the condition under the new
corpus (a new run name) to compare.

## Model findings (closed)

- **Gemma 4 (2026-10-19), runs `*-gemma4-*`:** not usable as a Mwoyeo engine with today's request.
  - gemma4:e4b returns ja/zh→ko lines as their own source text (142 of 436 echoed, 23.4 % probe accuracy, A-gemma4-e4b).
  - Folding the system prompt into the user message lowers the echo (the `-fold` runs). The product carries no
    per-model request rules, so this stays a bench note and is not shipped.
  - gemma4:26b does not echo, but at 18 GB it swaps a 32 GB Mac.
  - The judge pass for M vs A was stopped unfinished; its 249 raw verdicts are not counted.
- **TranslateGemma 4b:** it accepts the JSON request but fails 13.5 % of A requests. Some batches repeat a sentence
  until the deadline. Not recommended either.

## Metrics (`score.py`)

- **Probe accuracy** per run: overall, by evidence (`memory`, `lines`, `none`), by type, by pair and kind, and for
  lines-evidence probes by lookback distance (1-2, 3-4, 5-8, 9-16, 17+), which is what picks the window size.
- **Sign test** (exact, two-sided, on the probes where two runs disagree) of every run against the first (or `--baseline`),
  overall and by evidence. A comparison needs at least 250 probes; the corpus has 353.
- **Speech level**: the share of judged lines whose sentence endings (`hapsyo` -니다, `haeyo` -요, `banmal` the rest) match
  the speaker's level for that addressee; mixed lines and speaker-level groups that show more than one level are counted.
  Scored by script, not by a judge (LoCar: judges confuse haeyo and hapsyo).
- **Carry-over**: a wrong rendering (a string from the probe's `none` list) that repeats on a later probe of the same key
  (`repeat_same`), and consecutive failures of one key whatever the wrong form (`fail streaks`).
- **Latency** p50/p95 per request, retries included. **Tokens** in/out/cached from the engine's usage, with the cost from
  `prices.json` (every price cites its source line; DeepL bills characters and has no entry).
- **Failures and leaks** (`score.py` prints them after each summary; `summarize` and the manifests do not carry them, so
  the recorded summaries keep reproducing). Failed attempts by reason: `parse` (not the JSON asked for), `count` (a different
  number of lines; the report says how many had more lines than items), `leak` (the stored raw reply repeats a context line;
  needs the raw reply, so runs before 2026-10-19 show none), `timeout`, `http`, `other`. Accepted output lines that **repeat a
  context line** (their source text, or that line's translation as this run produced it) are context leaks: a condition that
  wins accuracy but leaks fails design section 9's no-regression rule. Lines that repeat another item of their own batch are
  batch leaks (condition A has them too: the model's floor). **Echoed** lines are their own source text, untranslated.
  Thresholds (`SRC_MIN`, `TR_MIN` in `score.py`) keep short shared phrases from counting. `tests/test_failures.py` plants
  leaks into a mini run and into a preserved run and counts them; with `--neuter` it must fail.
- **Judge** (`judge.py`): blind pairwise prompts, one file per order, per line whose two translations differ, plus
  calibration items (the same text twice: the judge must say tie in both orders). The condition names are in `key.json` only.
  `judge.py tally` counts only items on which both orders agree and prints the counts, the win rate with a Wilson interval
  and the calibration result. It never calls a judge. `judge-run.py` does, through the agy CLI: the prompt files of a pair are shuffled
  (fixed seed) into calls of 15 cases, so the two orders of an item land in different calls; a CLI exit of 0 is not success (the result
  event's `status` and an answer that covers every case are), a retry asks only the cases still without a verdict, and every raw try is kept
  (`calls/call-NNNN.tryK.json`). Its `known-answer` pair is the instrument check: the reference translation against the line's own source
  text and against the reference with a probe's known wrong rendering (`bad_sub`); the reference must win in both orders on at least
  90 % of the items and lose on at most 5 %, and identical text must be a tie, or the pass is a screen and not a verdict.

## Size accounting

Every request record splits the prompt into `stable` (the system prompt: rules, the notes, learned terms), `history` (the
context lines) and `volatile` (the items), in estimated tokens scaled so the three parts add up to the engine's reported
prompt tokens (`calibration`), plus `lcp`: the prefix shared with the previous request of the sequence, which is what a
provider's prefix cache (Anthropic breakpoint, OpenAI automatic, llama.cpp slot) can reuse, and `memory`: the user memory as
rendered. The scorer prints their means per condition, so the size budget (window, memory) is set from data. A condition
that slides its window (B) has a small `lcp` after the system prompt; one that only grows (C) keeps `history` in it until the
older half drops. A prefix under the provider's minimum (512 tokens Anthropic 5.x, 1,024 OpenAI) is not cached at all.

## Decision rule (design section 5)

Pick the cheapest condition within 2 points of the best probe accuracy that is not worse in judge preference; ties go to
fewer tokens. A condition earns its place only against A with p < 0.05 on at least 250 probes and at least 150 decided judge
pairs; the memory-only probes show what the memory adds (A, B, C cannot know it), the lines-evidence distances show how
many lines back a window must reach, the `none` controls show context does not break easy cases.

## What this blocks

**A context default chosen without measurement.** The defaults of the design (window length, source-only vs translations,
a user memory vs a long transcript) are provisional until this bench has run them on the engines the app ships with.

## Checks

`tests/run-all.sh`: the corpus validation, `tests/test_score.py` (the scorer on a golden mini-sequence with hand-written
translations: 100 %; one name swapped drops accuracy and raises carry-over), `tests/test_judge_report.py` (planted verdicts: position bias and one-order items are not counted, the consensus splits), `tests/test_judge_run.py` (`judge-run.py` on a fake agy: exit 0 with a failed status is no verdict, short answers are asked again, a rerun asks nobody, a judge with position bias or a wrong preference fails the known-answer check), `tests/test_judge.py` (the A-vs-A sample prompt
pair, the tally on a fake verdict set), `tests/test_failures.py` (failed attempts by reason, leaks and echoes counted on a mini run and on a doctored real run; run again with
`--neuter` it must fail), `tests/test_summary.py` (SUMMARY.md renders identically twice and equals the committed file), `tests/test_runs.py` (preservation: no overwrite, a manifest that verifies, and
`verify` failing on a missing manifest, a changed file, a changed summary and a short oracle run), `runs.py verify` (every
preserved run), the runner's Swift tests, `tests/test_particles.py` (a hand-broken Korean particle after a written name is caught, a correct one
passes, a Han character replaced inside a longer word is flagged) and `tests/test_both_bench.py` (a planted wrong name shows in the rewritten class only, the judge tally
splits by class, a sequence none of whose requests was rewritten counts as identical to hint); each of the two is run again with `--neuter` and must fail; and `tests/check_render.py` (the runner's and the scorer's renderings of every
memory are identical).

## Assumptions and limits

- Conditions that send context also send the speaker of each line where `speaker_visible` is true (a chat or a game text
  box), because the memory's `speaks_to` is unusable otherwise. A is today's request and carries no speaker. If the app
  cannot attribute speakers, the speech-level gain of the memory is an upper bound.
- The sequences are short (15-40 lines) and the probes are planted: they measure what context decides, not general quality.
  The oracle (`ref`) is one skilled translation, not the only correct one; checks accept the renderings listed in `any`.
- `reference` layout numbers are the bench's own prompt, not the product's. The product-layout runs (`--layout t2`, run names
  ending `-t2`) are the ones to read before setting a default; `runs/RESULTS-2026-10-19-t3-product-layout.md` has them.
- Local models are small; a 1-2 B model cannot use context well, so use the largest model the engine row will really run.
