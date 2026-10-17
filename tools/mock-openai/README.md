# mock-openai

A stdlib-only Python server that imitates an OpenAI-compatible chat-completions API,
for testing Mwoyeo's chat translation engine without a real model.

    python3 -I tools/mock-openai/server.py <port> <mode>

Modes: `ok`, `fenced` (JSON in ```json fences), `short` (one translation too few),
`slow:<ms>`, `401`, `429`, `garbage`. It serves `POST /v1/chat/completions` and `GET /v1/models`.
Each request logs one line to stderr; the Authorization header is reported as present or absent, never printed.

    curl -s localhost:8765/v1/chat/completions -d '{"messages":[{"role":"system","content":"Translate each line of the user'"'"'s JSON into Korean."},{"role":"user","content":"{\"lines\":[\"hi\"]}"}]}'
