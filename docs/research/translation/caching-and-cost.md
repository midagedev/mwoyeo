# research-ctx-A: prompt caching and stateful sessions for a rolling per-app transcript (2026-10-18)

## Summary
1. Caching only pays if the prefix is byte-identical and APPEND-ONLY. A sliding window (drop oldest each turn) rewrites the prefix every turn: it is a 100% miss and costs MORE than no cache (writes at 1.25x on Anthropic/luna). Compact at thresholds instead.
2. Cost (200 requests, 3 lines each, 1k prefix, 75 new + 75 out tokens/request): today's ~100-token stateless prompt = 1.1c (Haiku 5.5 / gpt-6-luna). A stateless 1k prefix with no cache = 2.9c. Rolling transcript with cache + threshold compaction: C=2k 2.0c, C=8k 2.5c, C=32k 4.1c. Rolling with no cache: 5.7c / 13.6c / 32.8c.
3. So a rolling transcript with cache is 2-4x today's cost, not "only new tokens". Quality gain must justify that. Output tokens (0.75c of 1.1c) dominate today's cost.
4. Min cacheable: Haiku 5.5 / Sonnet 5.5 512 tok; GPT-5.6+ 1,024; Gemini implicit 4,096 (a 1k prefix never caches on Gemini 3.x). Anthropic 5m TTL (1h at 2x write); OpenAI 30m default on 5.6+; Groq 2h; OpenRouter sticky 10 min.
5. OpenAI previous_response_id does NOT reduce billing; responses stored 30 days unless store=false. Keep the transcript client-side (memory only) and send it each time.
6. Local: llama.cpp reuses the slot KV when the prefix is identical (cache_prompt); a system prompt change or context shift breaks it. Ollama unloads models after 5 min and defaults to a 4096 context.
7. Apple FM: window 4096 tokens (instructions+prompts+output). The KV-reuse behavior of a long-lived session is [unverified] in docs; prewarm(promptPrefix:) is documented to process a known prefix eagerly. 4096 means a rolling transcript fits only ~25 turns of 150 tokens after instructions.
8. Design: stable-first order, volatile data last, one breakpoint at the end of the transcript, compact into a new stable block at a threshold, no keep-warm pings (except maybe one on Anthropic 1h TTL).

## Provider facts (URL, verbatim)
### OpenAI  https://developers.openai.com/api/docs/guides/prompt-caching (no page date shown)
- "The minimum cacheable prompt length is 1,024 tokens." (GPT-5.6 and later; earlier models vary by tools/images/schema)
- "Cache reuse requires the entire rendered prefix to match." Tools, output format, reasoning effort, verbosity changes break it.
- Earlier models: cached tokens rounded down to multiples of 128; GPT-5.6+ reports the exact boundary.
- prompt_cache_key: "Keys influence routing; they do not pin requests to a machine or guarantee a cache hit."
- Retention (earlier models): in_memory ~5-10 min inactivity up to 1h; 24h extended on gpt-5.5, 5.4, 5.2, 5.1, 5, 4.1. GPT-5.6+: prompt_cache_options.ttl only "30m" (default), "at least 30 minutes after its latest write or reuse".
- Price: "For GPT-5.6 and later, cache writes cost 1.25× the standard, uncached input-token rate." Cached read 0.1x (0.05x for GPT-6.1 Sol); docs say "discounted up to 95%".
- Usage: usage.input_tokens_details.cached_tokens and cache_write_tokens (Responses API; Chat Completions uses prompt_tokens_details.cached_tokens per OpenRouter/Groq docs).
- Latency: the page gives only "Faster: Reduce the time spent processing input before the response starts." No number. [no documented TTFT figure]
- Conversation state https://developers.openai.com/api/docs/guides/conversation-state: "all previous input tokens for responses in the chain are billed as input tokens in the API." "Response objects are saved for 30 days by default." store=false disables.
- Prices https://developers.openai.com/api/docs/pricing (per 1M, in/cached/out): gpt-5.4-nano 0.20/0.02/1.25; gpt-5.4-mini 0.75/0.075/4.50; gpt-5-nano 0.05/0.005/0.40; gpt-6-luna 0.10/0.01/0.50 (write 0.125); gpt-5.6-luna 0.20/0.02/1.20 (write 0.25). Flex and Batch = half of Standard ("Flex and batch rates for these models are exactly half" is the fetcher's summary, not a verbatim page line). Batch is asynchronous (24h class), irrelevant to a live lens; Flex is slower with possible 429s, unsuited to interactive use [Flex latency semantic from memory, unverified].
### Anthropic  https://platform.claude.com/docs/en/build-with-claude/prompt-caching
- "You can define up to 4 cache breakpoints if you want to:"
- Min: "512 tokens for ... Claude Haiku 5.5"; "512 tokens for ... Sonnet 5.5"; "4,096 tokens for Claude Haiku 4.5"; "Shorter prompts cannot be cached, even if marked with cache_control ... no error is returned."
- "By default, the cache has a 5-minute lifetime." 1h: {"type":"ephemeral","ttl":"1h"}.
- "5-minute cache write tokens are 1.25 times the base input tokens price"; "1-hour cache write tokens are 2 times"; "Cache read tokens are 0.1 times"; "Cache hits and refreshes on Claude Opus 5.5 and Claude Sonnet 5.5 are priced at 0.05x".
- "The cache is refreshed for no additional cost each time the cached content is used." "The lifetime is measured from the start of the request that writes or reads the cache entry".
- Lookback: "The system checks at most 20 positions per breakpoint". "If a growing conversation pushes your breakpoint 20 or more blocks past the last write, the lookback window misses it."
- Automatic caching: "The cache breakpoint automatically moves to the last cacheable block in each request, so you don't need to update any cache_control markers as the conversation grows." (top-level "cache_control": {"type":"ephemeral"})
- Fields: cache_creation_input_tokens, cache_read_input_tokens, input_tokens (tokens after the last breakpoint).
- Invalidation: "Changes at any breakpoint invalidate that segment and everything after it".
- Prices https://platform.claude.com/docs/en/about-claude/pricing: Haiku 5.5 (<=100k prompt) $0.10 in / $0.125 5m write / $0.20 1h write / $0.01 hit / $0.50 out per MTok; Haiku 4.5 $1/$1.25/$2/$0.10/$5.
### Gemini  https://ai.google.dev/gemini-api/docs/caching , /pricing (updated 2026-10-16 UTC)
- Implicit min: "Gemini 3.8 Flash" : "4,096"; "Gemini 2.5 Flash" : "2,048". "We automatically pass on cost savings if your request hits caches." Hits: usage.total_cached_tokens (Interactions API wording).
- Explicit caching TTL and storage: page fetched did not state a TTL; pricing lists "$1.00 / 1,000,000 tokens per hour (storage price)". Explicit TTL value [unverified].
- Prices (per M, in / cached / out): 3.1 Flash-Lite 0.25/0.025/1.50; 2.5 Flash-Lite 0.10/0.01/0.40; 2.5 Flash 0.30/0.03/2.50; 3.5 Flash-Lite 0.30/0.03/2.50. A 1k prefix is under the 4,096 implicit minimum on 3.x.
### DeepSeek, Mistral, Groq, OpenRouter
- DeepSeek https://api-docs.deepseek.com/guides/kv_cache: "Each user request will trigger the construction of a hard disk cache."; "The cache system works on a "best-effort" basis and does not guarantee a 100% cache hit rate."; field prompt_cache_hit_tokens. Min/price not on page [unverified].
- Mistral: docs pages fetched (completion, usage) do not mention prompt caching [unverified, no claim].
- Groq https://console.groq.com/docs/prompt-caching: models openai/gpt-oss-20b, -120b, -safeguard-20b; "a 50% discount for cached input tokens"; "All cached data automatically expires after 2 hours without use."; min "ranging from 128 to 1024 tokens"; usage.prompt_tokens_details.cached_tokens.
- OpenRouter https://openrouter.ai/docs/guides/best-practices/prompt-caching: "Add a single cache_control field at the top level of your request." (Anthropic); Gemini: "OpenRouter will use only the last breakpoint for Gemini caching across normal message content."; "Subsequent requests for the same model are routed to the same provider, keeping your cache warm."; "Sticky sessions expire after 10 minutes of inactivity."; OpenAI/DeepSeek/Groq "automated".
### Local
- llama.cpp https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md: cache_prompt "Re-use KV cache from a previous request if possible."; --cache-reuse "min chunk size to attempt reusing from the cache via KV shifting ... (default: 0)"; slot similarity "how much the prompt of a request must match the prompt of a slot in order to use that slot (default: 0.10 ...)"; context shift "(default: disabled)"; --cache-ram "(default: 8192 ...)". Implication: an append-only prefix hits the same slot and prefills only the tail; changing the system prompt or dropping old turns changes the prefix start, so a full re-prefill (cache-reuse can shift chunks only if enabled).
- Ollama https://docs.ollama.com/faq: "By default models are kept in memory for 5 minutes before being unloaded."; "By default, Ollama uses a context window size of 4096 tokens." Prefix reuse inside a loaded model is from memory/not fetched [unverified]. A transcript beyond 4096 is silently truncated by default, which drops the prefix start [from memory, unverified].
- LM Studio, MLX: not researched [unverified].
### Apple Foundation Models
- https://developer.apple.com/tutorials/data/documentation/foundationmodels/languagemodelsession/prewarm(promptprefix:).md : "Loads the resources required for this session into memory ahead of a request."; "If you know a prefix for the future prompt, passing it to prewarm(promptPrefix:) allows the system to process the prompt eagerly and reduce latency for the future request."; "You should only use prewarm when you have a window of at least 1 second".
- Window: via search summary of Apple docs/forums (WebSearch, page text not fetched): 4,096 tokens, counted across instructions, prompts and outputs of a session; error exceededContextWindowSize; InfoQ reports iOS 26.4 added SystemLanguageModel.contextSize and tokenCount(for:) https://infoq.com/news/2026/03/apple-foundation-models-context [secondary].
- Does a long-lived session keep KV state so only new tokens are processed: [unverified]. The session does keep a transcript that is resent as context (that is why the window fills). TN3193 body could not be fetched; Transcript-based rebuilding is from memory [unverified].

## Cost model (script: /private/tmp/claude-501/-Users-hckim-repo-mwoyeo/ff63668f-512b-4dfe-84da-f8969db15ac2/scratchpad/cost.py)
Assumptions: 200 requests, 75 new input tokens and 75 output tokens each, a turn adds 150 transcript tokens, 1k prefix. Cents per session; list prices above. Gemini* = 3.1 Flash-Lite, implicit cache needs 4,096 so rows assume the cache works (optimistic; with a 1k prefix and C=2k it would not).
| scenario | gpt-5.4-nano | gpt-6-luna | Haiku 5.5 | Gem 3.1 FL* |
| today (100-tok sys, no history) | 2.58 | 1.10 | 1.10 | 3.13 |
| stateless 1k prefix, no cache | 6.18 | 2.90 | 2.90 | 7.63 |
| C=2k no cache | 11.8 | 5.72 | 5.72 | 14.7 |
| C=2k sliding window + cache (prefix changes each turn) | 13.4 | 7.91 | 7.91 | 16.7 |
| C=2k compact-at-threshold + cache | 4.13 | 2.02 | 2.02 | 5.07 |
| C=8k no cache | 27.6 | 13.6 | 13.6 | 34.4 |
| C=8k sliding + cache | 29.0 | 17.6 | 17.6 | 36.2 |
| C=8k compact + cache | 5.27 | 2.53 | 2.53 | 6.50 |
| C=32k no cache | 65.9 | 32.8 | 32.8 | 82.3 |
| C=32k compact + cache (never fills in 200 turns) | 8.56 | 4.10 | 4.10 | 10.6 |
| C=32k + 2 idle gaps >5 min (full re-write each) | 9.14 | 4.47 | 4.47 | 11.3 |
Compaction here = reset transcript to C/2 when it exceeds C (one miss per reset); the summarization call itself is NOT costed. Idle gaps: two misses, +0.03-0.6c, small. With OpenAI 30m / Groq 2h TTL even fewer. Output cost is fixed at 0.75c (luna/Haiku) per session in all rows. No documented TTFT numbers found for any provider (OpenAI page says only "Faster"); Apple prewarm doc promises latency reduction without a number.

## Design rules
- Order: instructions + app context + glossary (stable, never edited mid-session) -> transcript (append only) -> new batch. Volatile data (time, other screen lines) goes in the last user turn, after the final breakpoint.
- Anthropic: one top-level automatic cache_control (moves to the last block) or a breakpoint on the last transcript block plus one on the stable prefix (2 of 4). Mind the 20-block lookback: with 2 messages per request that is fine; if blocks per request grow, re-mark.
- OpenAI: no markup; keep the prefix identical; set prompt_cache_key per app bundle id if using pre-5.6 models; read cached_tokens.
- Compaction: at a threshold (e.g. transcript reaches C), replace the oldest half by a summary/glossary block written once, so the prefix changes once per C/2 tokens, not every turn.
- Keep-warm: not worth it; a miss costs a 1.25x write of a few k tokens (fractions of a cent). Optionally 1h TTL on Anthropic (2x write).
- Privacy: keep the transcript in memory client-side; avoid previous_response_id/Conversations (30-day server storage); prompt cache entries are server-side by nature (OpenAI default 24h retention for non-ZDR orgs on earlier models), so note this in the privacy copy.
- Local servers: keep the system prompt constant, send the whole transcript each time, keep Ollama keep_alive long enough and num_ctx >= prefix+C.
DONE-research-ctx-A
