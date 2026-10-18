# Translation research (2026-10-18)

These notes record what we learned while designing context and memory translation
(docs/design/context-translation.md). The experiment data is content: keep it with the notes and do not regenerate it over
the top. Each claim carries its source URL and a verbatim line ([V]), a fetched summary ([V-sum]), a search snippet ([S])
or an estimate ([U]).

| File | What it covers |
|---|---|
| caching-and-cost.md | Prompt caching per provider (minimums, TTL, multipliers, fields), the cost model for a 30-min session |
| context-quality-and-eval.md | Where context helps, propagation risks, the eval design |
| methods.md | LLM translation methods (TM few-shot, multi-step, QE routing, MBR, dedicated MT models), cost multiples |
| tools-in-practice.md | Twelve open-source tools' prompts and context code (path:line), localization platforms |
| context-management.md | Window size evidence, source vs target context, compaction and reset policies in tools, defaults |
| memory-and-window-metadata.md | Editable memory: evidence, schemas, UX precedents, OS window metadata, size budgets, privacy |
| apple-translation.md | The Apple Translation API surface (macOS 26/27), context-concatenation and input-shaping probes |
| apple-probe/ | The probe source (ctx.swift), the predictions written before the runs, and the raw outputs (ll/hf = low latency / high fidelity; d = previous-line concat, s = shaping) |

The bench that measures these choices lives in tools/translation-bench/. Its sequences, memory sheets, probes and run
outputs are kept in the repo, with a manifest per run (engine, model, date, commit).
