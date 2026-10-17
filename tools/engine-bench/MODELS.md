# Contestants and why (checked 2026-10-17)

Model ids were checked against the live `GET /models` of the keys used (Gemini, OpenAI). Prices are USD per 1M tokens
(input / output), standard tier.

| Provider | Model id | Why | Reasoning off | Price | Source |
|---|---|---|---|---|---|
| Gemini | `gemini-3.1-flash-lite` | speed pick; the cheapest Flash-Lite that has a stable id | `reasoning_effort` (OpenAI-compat) accepted | free tier; paid 0.25 / 1.50 | https://ai.google.dev/gemini-api/docs/pricing ("Input price ... Paid Tier: $0.25 (text / image / video / audio)") |
| Gemini | `gemini-3.8-flash` | quality pick; current Flash. Lowest level is `low`, it cannot be turned off | `thinking_level: low` (sent as `reasoning_effort: low`) | free tier; paid 0.75 / 3.75 until 2026-12-31, then 1.50 / 7.50 | same pricing page; https://ai.google.dev/gemini-api/docs/thinking ("gemini-3.8-flash: ... Supports low, medium, high") |
| OpenAI | `gpt-4o-mini` | speed pick and the model most translation scripts still use | none (not a reasoning model) | 0.15 / 0.60 | https://developers.openai.com/api/docs/pricing ("gpt-4o-mini \| $0.15 ... $0.60") |
| OpenAI | `gpt-5.4-mini` | quality pick; small current mini | `reasoning_effort: "none"` | 0.75 / 4.50 | same page ("gpt-5.4-mini \| $0.75 ... $4.50") |
| OpenAI | `gpt-5.6-luna` | newest low-price tier on the key's list | `reasoning_effort: "none"` | 0.20 / 1.20 | same page ("gpt-5.6-luna \| $0.20 ... $1.20") |
| Claude | `claude-haiku-5-5` | speed pick | none needed (no thinking unless asked) | 0.10 / 0.50 | https://platform.claude.com/docs/en/about-claude/pricing ("Claude Haiku 5.5 ... $0.10 / MTok ... $0.50 / MTok") |
| Claude | `claude-sonnet-5-5` | quality pick | none needed | 2 / 10 | same page ("Claude Sonnet 5.5 \| $2 / MTok ... $10 / MTok") |
| DeepL | `/v2/translate` (Free) | no model choice | n/a | free tier; measured character_limit 1,000,000 per month via /v2/usage (the lead, this key) | https://developers.deepl.com/docs |
| Apple | Translation, low latency | the app default; on device | n/a | free | `TranslationSession(... preferredStrategy: .lowLatency)` |
| Apple | Translation, high fidelity | the app's slower on-device option | n/a | free | `.highFidelity` |
| Local (Ollama) | `translategemma:4b` (3.3 GB) | translation-specialised, built on Gemma 3, 55 languages. Uses its own prompt, not the JSON one | n/a | free | https://ollama.com/library/translategemma ("translategemma:4b: 3.3GB") |
| Local (Ollama) | `qwen3.5:2b` (2.7 GB) | general small model that fits the disk budget next to the first one | `reasoning_effort: "none"` | free | https://ollama.com/library/qwen3.5 ("qwen3.5:2b \| 2.7–3.1 GB") |

Not tested, with the reason:
- Qwen-MT, Seed-X and Hunyuan-MT: a web search found no Ollama library entry for them (only Hugging Face GGUF community
  builds, not verified), so they are not run through Ollama here.
- `gemma4:e2b` and `gemma4:12b` (Ollama lists 4.6-7.5 GB and 7.7-8.0 GB): over the 6 GB budget for two local models.
- `translategemma:12b` (8.1 GB) and `:27b` (17 GB): over the disk budget. The 12B would likely read better than the 4B.
- `gemini-2.5-*`: listed by `/models` but returns 404 "no longer available to new users" for this key.
- Flagship models (gpt-5.5 at 5 / 30, Fable, Sonnet-class pro tiers): not what people use for short-line translation.
