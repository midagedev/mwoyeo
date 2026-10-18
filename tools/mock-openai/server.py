# Mock OpenAI-compatible server for testing the chat-completions translation engine.
#
# Usage: python3 -I server.py <port> <mode> [flags] [--dump <dir>]
# Serves POST /v1/chat/completions and GET /v1/models on 127.0.0.1, plus three more engine shapes:
#   POST /v1/messages   Anthropic Messages API (modes ok, 401, garbage; others behave like ok)
#   POST /v2/translate  DeepL: form or JSON `text` array -> {"translations": [{"text": ...}]}
#   POST /translate     LibreTranslate: {"q": ..., "target": ...} -> {"translatedText": ...}
# Modes:
#   ok          reply {"translations": ["⟦<target>⟧ <line>", ...]} after ~50 ms
#   fenced      same content wrapped in ```json fences
#   short       one translation fewer than lines (when more than one line), else ok
#   slow:<ms>   like ok, after <ms> milliseconds
#   401         HTTP 401 with an OpenAI-style error body
#   429         HTTP 429 with an OpenAI-style error body and `Retry-After: 7`
#   401echo     HTTP 401 whose message echoes the bearer token, as OpenAI's "Incorrect API key provided: sk-..." does
#   hang        read the request, log it, and never answer (for cancellation tests); slow:<ms> also applies to the
#               Anthropic and DeepL routes
#   garbage     content "sure! here you go"
#   strict      HTTP 400 when the body has `temperature` (OpenAI's real gpt-5-nano error, captured 2026-10-17) or
#               `reasoning_effort` (same shape, message written by hand); else like ok. For the app's retry-without-field path.
#   echo:<text> like ok, but a line containing <text> comes back unchanged (an engine that did not translate it)
#   terms       like ok, and the reply also carries `terms: [{src, dst}]` taken from the items (the first word of each line of at
#               least 2 letters, and its form `T_<word>`, which the translated line holds), and a `usage` with cached tokens
#               (1000 prompt, 50 completion, 800 cached). For the context path: the app learns from `terms`.
# <target> is read from the system prompt's "into X" phrase, or "T".
# A request in the context layout (the user message is {"translate": [{"id", "text"}], ...}, not {"lines": [...]}) is answered
# in the same modes; `terms` replies `{"t": [{"id", "text"}], "terms": [...]}` to it.
# With `--dump <dir>` each POST body is written, byte for byte, to <dir>/<nnnn>-<route>.json (nnnn counts from 0001), route being
# chat, messages, deepl or libre. Use it to see exactly what the app sent.
# With the `native` flag, for a Korean, Japanese or Chinese target the chat route adds a word in that script after the line ("번역"), so the app's
# untranslated-line check, which looks for the target script, accepts the mock's output.
# Each request logs one line to stderr: method, path, line count, mode, auth present/absent (never the value),
# thinking_off=yes when the JSON body carried any of reasoning_effort, reasoning, thinking, enable_thinking, think,
# and with the `stamp` flag t=<unix seconds>.
import json
import os
import re
import threading
import urllib.parse
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# `--dump <dir>` may stand anywhere after the program name; the positional arguments below do not see it.
DUMP = None
if "--dump" in sys.argv:
    _i = sys.argv.index("--dump")
    DUMP = sys.argv[_i + 1]
    del sys.argv[_i:_i + 2]
    os.makedirs(DUMP, exist_ok=True)
_dump_count = 0
_dump_lock = threading.Lock()
ROUTES = {"/v1/chat/completions": "chat", "/v1/messages": "messages", "/v2/translate": "deepl", "/translate": "libre"}

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
MODE = sys.argv[2] if len(sys.argv) > 2 else "ok"
# Optional third argument, comma-separated: `native` (add a target-script word, see above), `stamp` (t= in the log).
FLAGS = set(sys.argv[3].split(",")) if len(sys.argv) > 3 else set()


NATIVE = {"Korean": "번역", "Japanese": "翻訳", "Chinese": "翻译"}


def native_word(target):
    return next((w for name, w in NATIVE.items() if name in target), "")


def dump_body(path, raw):
    global _dump_count
    if DUMP is None:
        return
    with _dump_lock:
        _dump_count += 1
        n = _dump_count
    with open(os.path.join(DUMP, f"{n:04d}-{ROUTES.get(path, 'other')}.json"), "wb") as f:
        f.write(raw)


def request_lines(user):
    """The lines to translate from the user message: today's {"lines": [...]} or the context layout's {"translate": [{id, text}]}."""
    obj = json.loads(user)
    if "translate" in obj:
        return [t["text"] for t in obj["translate"]], True
    return obj.get("lines", []), False


def term_hints(lines):
    """One hint per line: the first word of at least 2 letters, and the form the translated line holds for it."""
    out = []
    for line in lines:
        word = next((w for w in re.findall(r"[A-Za-z]{2,}", line)), None)
        if word and all(h["src"] != word for h in out):
            out.append({"src": word, "dst": f"T_{word}"})
    return out


def with_terms(line):
    """`terms` mode: the line with the word of its hint replaced by the hint's form (so the reply holds every `dst`)."""
    hint = next(iter(term_hints([line])), None)
    return line.replace(hint["src"], hint["dst"], 1) if hint else line


def reply_content(out, lines, ctx):
    """The text the model says: today's shape, or `terms` mode's {"t": [...], "terms": [...]} (which also fits {"lines"} requests)."""
    if MODE != "terms":
        return json.dumps({"translations": out}, ensure_ascii=False)
    body = {"terms": term_hints(lines)}
    if ctx:
        body["t"] = [{"id": i, "text": t} for i, t in enumerate(out)]
    else:
        body["translations"] = out
    return json.dumps(body, ensure_ascii=False)


def envelope(content):
    usage = {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
    if MODE == "terms":
        usage = {"prompt_tokens": 1000, "completion_tokens": 50, "total_tokens": 1050, "prompt_tokens_details": {"cached_tokens": 800}}
    return {
        "id": "chatcmpl-mock", "object": "chat.completion", "created": int(time.time()), "model": "mock",
        "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
        "usage": usage,
    }


def error_body(message, kind, code):
    return {"error": {"message": message, "type": kind, "param": None, "code": code}}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def pause(self, default=0.05):
        if MODE == "hang":
            time.sleep(3600)
        time.sleep(int(MODE.split(":", 1)[1]) / 1000 if MODE.startswith("slow:") else default)

    def send_json(self, status, obj, headers=None):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log(self, count, thinking_off=False):
        auth = "present" if (self.headers.get("Authorization") or self.headers.get("x-api-key")) else "absent"
        off = "yes" if thinking_off else "no"
        print(f"{self.command} {self.path} lines={count} mode={MODE} auth={auth} thinking_off={off}" + (f" t={time.time():.3f}" if "stamp" in FLAGS else ""), file=sys.stderr, flush=True)

    def do_GET(self):
        self.log("-")
        if self.path.rstrip("/") == "/v1/models":
            self.send_json(200, {"object": "list", "data": [{"id": "mock-small", "object": "model"}, {"id": "mock-large", "object": "model"}]})
        else:
            self.send_json(404, error_body("not found", "invalid_request_error", None))

    def other_engine(self, path, raw, req, thinking_off):
        if path == "/v1/messages":
            user = next((m["content"] for m in reversed(req.get("messages", [])) if m.get("role") == "user"), "{}")
            try:
                lines, ctx = request_lines(user)
            except (ValueError, AttributeError, TypeError, KeyError):
                lines, ctx = [], False
            self.log(len(lines), thinking_off)
            if MODE == "401":
                return self.send_json(401, {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}})
            if MODE == "garbage":
                text = "sure! here you go"
            else:
                self.pause()
                out = [f"⟦anthropic⟧ {with_terms(l) if MODE == 'terms' else l}" for l in lines]
                text = reply_content(out, lines, ctx)
            usage = {"input_tokens": 0, "output_tokens": 0}
            if MODE == "terms":
                usage = {"input_tokens": 200, "output_tokens": 50, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 800}
            return self.send_json(200, {"id": "msg_mock", "type": "message", "role": "assistant", "model": "mock",
                                        "content": [{"type": "text", "text": text}], "stop_reason": "end_turn",
                                        "usage": usage})
        if path == "/v2/translate":
            texts, target = [], "T"
            if isinstance(req, dict) and req:
                texts, target = req.get("text", []), req.get("target_lang", "T")
            else:
                form = urllib.parse.parse_qs(raw.decode("utf-8", "replace"))
                texts, target = form.get("text", []), (form.get("target_lang") or ["T"])[0]
            if isinstance(texts, str):
                texts = [texts]
            self.log(len(texts), thinking_off)
            if MODE == "401":
                return self.send_json(403, {"message": "Authorization failure, check auth_key"})
            self.pause(0)
            return self.send_json(200, {"translations": [{"detected_source_language": "EN", "text": f"⟦{target}⟧ {t}"} for t in texts]})
        self.log(1, thinking_off)
        if MODE == "401":
            return self.send_json(400, {"error": "Invalid API key"})
        self.pause(0)
        return self.send_json(200, {"translatedText": f"⟦{req.get('target', 'T')}⟧ {req.get('q', '')}"})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        lines, target, ctx = [], "T", False
        path = self.path.rstrip("/")
        dump_body(path, raw)
        thinking_off = False
        try:
            req = json.loads(raw)
            thinking_off = any(k in req for k in ("reasoning_effort", "reasoning", "thinking", "enable_thinking", "think"))
        except (ValueError, AttributeError, TypeError):
            req = {}
        if path in ("/v1/messages", "/v2/translate", "/translate"):
            return self.other_engine(path, raw, req, thinking_off)
        try:
            msgs = req.get("messages", [])
            system = next((m["content"] for m in msgs if m.get("role") == "system"), "")
            user = next((m["content"] for m in reversed(msgs) if m.get("role") == "user"), "{}")
            lines, ctx = request_lines(user)
            m = re.search(r"into (.+?)(?: from |\.)", system)
            if m:
                target = m.group(1)
        except (ValueError, AttributeError, TypeError, KeyError):
            pass
        self.log(len(lines), thinking_off)
        if path != "/v1/chat/completions":
            return self.send_json(404, error_body("not found", "invalid_request_error", None))
        if MODE == "401":
            return self.send_json(401, error_body("Incorrect API key provided.", "invalid_request_error", "invalid_api_key"))
        if MODE == "401echo":
            token = (self.headers.get("Authorization") or "").removeprefix("Bearer ")
            return self.send_json(401, error_body(f"Incorrect API key provided: {token}.", "invalid_request_error", "invalid_api_key"))
        if MODE == "strict":
            if "temperature" in req:
                msg = "Unsupported value: 'temperature' does not support 0 with this model. Only the default (1) value is supported."
                return self.send_json(400, {"error": {"message": msg, "type": "invalid_request_error", "param": "temperature", "code": "unsupported_value"}})
            if "reasoning_effort" in req:
                return self.send_json(400, {"error": {"message": "Unsupported parameter: 'reasoning_effort' is not supported with this model.", "type": "invalid_request_error", "param": "reasoning_effort", "code": "unsupported_parameter"}})
        if MODE == "429":
            return self.send_json(429, error_body("Rate limit reached.", "requests", "rate_limit_exceeded"), {"Retry-After": "7"})
        self.pause()
        if MODE == "garbage":
            return self.send_json(200, envelope("sure! here you go"))
        word = native_word(target) if "native" in FLAGS else ""
        echo = MODE.split(":", 1)[1] if MODE.startswith("echo:") else None
        out = [line if echo and echo in line else f"⟦{target}⟧ {with_terms(line) if MODE == 'terms' else line} {word}".rstrip() for line in lines]
        if MODE == "short" and len(out) > 1:
            out = out[:-1]
        content = reply_content(out, lines, ctx)
        if MODE == "fenced":
            content = "```json\n" + content + "\n```"
        self.send_json(200, envelope(content))


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
