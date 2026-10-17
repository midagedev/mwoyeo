# engine-bench

A light speed and quality benchmark of the translation engines Mwoyeo can use. Results: `RESULTS.md`; model choices: `MODELS.md`.

Files: `data.json` (4 pairs x 12 lines), `bench.py` (HTTP engines and Ollama), `apple.swift` (Apple Translation),
`judge.py` (blind two-vendor scoring), `report.py` (tables), `results/` (raw rows from the 2026-10-17 run).

## Re-run

Keys come from the environment and are never written to files.

```sh
export GEMINI_API_KEY=... DEEPL_API_KEY=... OPENAI_API_KEY=...
mkdir -p out
python3 -I bench.py --out out/raw-http.jsonl          # every engine whose key is set; others are skipped
python3 -I bench.py --engines gpt-5.4-mini --pairs ja-ko --out out/raw-http.jsonl   # a subset
swift apple.swift out/raw-apple.jsonl                  # needs macOS 26.4+ and the language packs installed
python3 -I judge.py out/raw-http.jsonl out/raw-apple.jsonl --out out/judge.jsonl
python3 -I report.py out      # report.py reads raw-*.jsonl and judge.jsonl in the directory
```

Local models (disk: about 6 GB):

```sh
ollama serve &            # note the pid
ollama pull translategemma:4b; ollama pull qwen3.5:2b
python3 -I bench.py --engines translategemma:4b,qwen3.5:2b --out out/raw-ollama.jsonl
ollama rm translategemma:4b; ollama rm qwen3.5:2b; kill <pid>
```

## Add Claude

```sh
export MWOYEO_CLAUDE_API_KEY=...        # optional: MWOYEO_CLAUDE_WORKSPACE=<workspace id>
python3 -I bench.py --engines claude-haiku-5-5,claude-sonnet-5-5 --out out/raw-http.jsonl
```

Without the key, Claude is skipped. Models are listed in `ENGINES` in `bench.py`; add a row to test another.
Notes: Gemini's free tier has daily request limits per model (429 is recorded as an error row, not a crash).
Current Claude models reject `temperature`, so it is not sent.
