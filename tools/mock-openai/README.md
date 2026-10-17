# mock-openai

A stdlib-only Python server that imitates an OpenAI-compatible chat-completions API,
for testing Mwoyeo's chat translation engine without a real model.

    python3 -I tools/mock-openai/server.py <port> <mode> [native,stamp]

`native` adds a word in the target script to each line (the app rejects a "translation" with no target-script
letters as untranslated, so app gates against the mock need it); `stamp` adds `t=<unix seconds>` to each log line.

Modes: `ok`, `fenced` (JSON in ```json fences), `short` (one translation too few),
`slow:<ms>`, `echo:<text>` (a line containing the text comes back unchanged), `401`, `401echo`, `429` (with `Retry-After: 7`), `garbage`, `strict`, `hang` (never answers).
Also answers the Anthropic (`/v1/messages`), DeepL (`/v2/translate`) and LibreTranslate (`/translate`) shapes; see the header of `server.py`. It serves `POST /v1/chat/completions` and `GET /v1/models`.
Each request logs one line to stderr; the Authorization header is reported as present or absent, never printed.

    curl -s localhost:8765/v1/chat/completions -d '{"messages":[{"role":"system","content":"Translate each line of the user'"'"'s JSON into Korean."},{"role":"user","content":"{\"lines\":[\"hi\"]}"}]}'
