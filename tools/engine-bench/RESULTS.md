# Engine benchmark: speed and quality

Date 2026-10-17. Machine: Apple M1 Pro, 32 GB, macOS 27.0. Network: home connection, one request at a time. The machine was not
quiet: an app build and other test runs shared it, so the on-device rows (Apple, Ollama) may read slower than they are.

Method:
- 4 pairs (ja-ko, en-ko, en-ja, zh-Hans-ko) x 12 original lines (UI strings, chat with slang/emoji, game dialogue, headlines), sent as 4 batches of 3 lines (the app's batch). Data: `data.json`.
- Speed: per engine and pair, 1 cold call, then each batch 3 times. Median and p90 are over all warm calls. "Cold" is the first call of the run (ja-ko), which for Apple and Ollama includes session or model load.
- Chat engines get the app's system prompt and JSON reply format (`bench.py`). DeepL uses `/v2/translate`. TranslateGemma uses its own prompt (one line in, one line out).
- Quality: first warm output of each engine, blind. Two judges from different vendors (`gpt-5.4` low reasoning, `gemini-3.7-flash`) score each line 1-5 for accuracy and naturalness, candidates shuffled under neutral labels. An engine is never scored by its own vendor's judge (OpenAI by Gemini only, Gemini by OpenAI only). Judge agreement (scores within 1): 0.95 (509/537).
- Failures: wrong line count, non-JSON reply, or a line left in the source language, over all warm calls. Apple zh-Hans-ko was not run: language pack not installed.

| engine | model | where it runs | warm median s / 3 lines | p90 s | cold s | quality (1-5) | failures / lines | cost |
|---|---|---|---|---|---|---|---|---|
| Apple low latency | Translation framework | this Mac | 0.15 | 0.41 | 4.30 | 3.4 (3 pairs) | 0/108 | free |
| Apple high fidelity | Translation framework | this Mac | 3.61 | 4.27 | 6.90 | 3.4 (3 pairs) | 0/108 | free |
| Gemini | gemini-3.1-flash-lite | cloud | 1.27 | 2.27 | 1.11 | 4.6 | 0/144 | free tier; paid $0.25 / $1.50 per 1M tokens |
| Gemini | gemini-3.5-flash-lite | cloud | 0.91 | 3.31 | 1.25 | 4.3 | 3/144 | free tier; paid $0.30 / $2.50 |
| OpenAI | gpt-4o-mini | cloud | 1.00 | 1.23 | 1.34 | 4.1 | 0/144 | $0.15 / $0.60 |
| OpenAI | gpt-5.4-mini (no reasoning) | cloud | 1.09 | 1.34 | 0.79 | 4.7 | 0/144 | $0.75 / $4.50 |
| OpenAI | gpt-5.6-luna (no reasoning) | cloud | 1.35 | 1.59 | 1.15 | 4.8 | 0/144 | $0.20 / $1.20 |
| Anthropic | claude-haiku-5-5 | cloud | 1.12 | 1.79 | 1.19 | 4.6 | 0/144 | $0.10 / $0.50 |
| Anthropic | claude-sonnet-5-5 | cloud | 1.43 | 1.56 | 1.29 | 4.7 | 0/144 | $2 / $10 |
| DeepL | Free API | cloud | 0.88 | 0.93 | 0.94 | 4.6 | 0/144 | free tier; the lead measured character_limit 1,000,000 per month via /v2/usage on this key |
| Ollama | translategemma:4b (3.3 GB) | this Mac | 1.00 | 1.52 | 6.06 | 3.6 | 0/144 | free |
| Ollama | qwen3.5:2b (2.7 GB) | this Mac | 0.83 | 1.07 | 31.89 | 2.0 | 81/144 | free |

Quality per pair (mean score, 1-5):

| engine | en-ja | en-ko | ja-ko | zh-Hans-ko |
|---|---|---|---|---|
| Apple low latency | 3.3 | 3.5 | 3.5 | not run |
| Apple high fidelity | 3.7 | 3.2 | 3.2 | not run |
| gemini-3.1-flash-lite | 4.8 | 4.2 | 4.8 | 4.5 |
| gemini-3.5-flash-lite | 4.4 | 4.0 | 4.4 | 4.2 |
| gpt-4o-mini | 4.1 | 4.1 | 4.0 | 4.4 |
| gpt-5.4-mini | 5.0 | 4.4 | 4.8 | 4.6 |
| gpt-5.6-luna | 4.9 | 4.4 | 4.9 | 4.8 |
| claude-haiku-5-5 | 4.6 | 4.7 | 4.6 | 4.5 |
| claude-sonnet-5-5 | 4.9 | 4.7 | 4.9 | 4.5 |
| deepl | 4.6 | 4.5 | 4.8 | 4.6 |
| translategemma:4b | 4.2 | 3.2 | 3.7 | 3.4 |
| qwen3.5:2b | 3.2 | 2.8 | 2.1 | 1.0 |

Reading it:
- Apple on-device is by far the fastest (0.15 s warm) and free, but scores about 1.2 points below the cloud engines. The high-fidelity strategy is 24x slower and no better here.
- Every cloud engine is 0.9-1.4 s per batch, mostly network. Speed does not separate them; quality and price do.
- The 4B TranslateGemma runs at cloud speed on this Mac (1 s) but reads clearly worse than the cloud models, especially en-ko and zh-ko. The 2B Qwen fails (non-JSON replies, untranslated lines) and takes 32 s to load.
- Gemini 3.5 Flash-Lite left one line untranslated in all 3 runs (`哈哈哈笑死我了😂` returned as is: 3/144 failures). Some of its calls hit a rate limit (429) and were retried; they form the p90 tail.
- Scores come from LLM judges on 12 lines per pair. Differences under about 0.3 are noise.

Notable examples (first warm run):
- ja-ko chat, `……まだ終わってないぞ、勇者め。` (a villain's line): Apple low latency `......아직 끝나지 않았어, 용사야.` (loses the sneer); DeepL `……아직 끝나지 않았어, 이 용사 녀석아.`; Claude Sonnet `……아직 끝나지 않았다, 용사 녀석.`
- en-ja, `Hey kid, you lost or something?`: Apple low latency `ねえ、子ども、負けたの？` (reads "lost" as "lost a game"); GPT-5.6 luna `おい、坊や、道に迷ったのか？` (got it).
- en-ko, `lol that meeting could've been an email 😭`: Apple low latency `ᄏᄏ 그 회의는 이메일일 수도 있었어 😭` (decomposed jamo, odd); GPT-5.6 luna `ㅋㅋ 그 회의는 이메일로 해도 됐을 텐데 😭`; TranslateGemma `아, 그 회의는 이메일로 충분했을 😭` (sentence cut off).
- ja-ko, `それな！マジで眠すぎる〜`: Qwen 2B `그냥 괜찮아! 정말로 너무 졸려요~` (wrong, "それな" means "so true"); the others give "맞아!", "내 말이!" or "그러게!".

Not measured:
- `gemini-3.8-flash`: the free tier allows 20 requests/day per model; 12 calls ran and then every call returned 429 (rows in `results/partial-gemini-3.8-flash.jsonl`). Re-run with a paid key: `python3 -I bench.py --engines gemini-3.8-flash`.
- Apple zh-Hans-ko: language pack not installed.
- Qwen-MT, Seed-X, Hunyuan-MT, larger TranslateGemma (12B, 27B), Gemma 4: see `MODELS.md`.
- Raw data and per-line judge scores: `results/`. Tables regenerate with `python3 -I report.py results`.
