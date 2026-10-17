# Mock OpenAI-compatible server for testing the chat-completions translation engine.
#
# Usage: python3 -I server.py <port> <mode>
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
#   429         HTTP 429 with an OpenAI-style error body
#   garbage     content "sure! here you go"
# <target> is read from the system prompt's "into X" phrase, or "T".
# Each request logs one line to stderr: method, path, line count, mode, auth present/absent (never the value), and
# thinking_off=yes when the JSON body carried any of reasoning_effort, reasoning, thinking, enable_thinking, think.
import json
import re
import urllib.parse
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
MODE = sys.argv[2] if len(sys.argv) > 2 else "ok"


def envelope(content):
    return {
        "id": "chatcmpl-mock", "object": "chat.completion", "created": int(time.time()), "model": "mock",
        "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


def error_body(message, kind, code):
    return {"error": {"message": message, "type": kind, "param": None, "code": code}}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, status, obj):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log(self, count, thinking_off=False):
        auth = "present" if (self.headers.get("Authorization") or self.headers.get("x-api-key")) else "absent"
        off = "yes" if thinking_off else "no"
        print(f"{self.command} {self.path} lines={count} mode={MODE} auth={auth} thinking_off={off}", file=sys.stderr, flush=True)

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
                lines = json.loads(user).get("lines", [])
            except (ValueError, AttributeError, TypeError):
                lines = []
            self.log(len(lines), thinking_off)
            if MODE == "401":
                return self.send_json(401, {"type": "error", "error": {"type": "authentication_error", "message": "invalid x-api-key"}})
            if MODE == "garbage":
                text = "sure! here you go"
            else:
                time.sleep(0.05)
                text = json.dumps({"translations": [f"⟦anthropic⟧ {l}" for l in lines]}, ensure_ascii=False)
            return self.send_json(200, {"id": "msg_mock", "type": "message", "role": "assistant", "model": "mock",
                                        "content": [{"type": "text", "text": text}], "stop_reason": "end_turn",
                                        "usage": {"input_tokens": 0, "output_tokens": 0}})
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
            return self.send_json(200, {"translations": [{"detected_source_language": "EN", "text": f"⟦{target}⟧ {t}"} for t in texts]})
        self.log(1, thinking_off)
        if MODE == "401":
            return self.send_json(400, {"error": "Invalid API key"})
        return self.send_json(200, {"translatedText": f"⟦{req.get('target', 'T')}⟧ {req.get('q', '')}"})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        lines, target = [], "T"
        path = self.path.rstrip("/")
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
            lines = json.loads(user).get("lines", [])
            m = re.search(r"into (.+?)(?: from |\.)", system)
            if m:
                target = m.group(1)
        except (ValueError, AttributeError, TypeError):
            pass
        self.log(len(lines), thinking_off)
        if path != "/v1/chat/completions":
            return self.send_json(404, error_body("not found", "invalid_request_error", None))
        if MODE == "401":
            return self.send_json(401, error_body("Incorrect API key provided.", "invalid_request_error", "invalid_api_key"))
        if MODE == "429":
            return self.send_json(429, error_body("Rate limit reached.", "requests", "rate_limit_exceeded"))
        delay = 0.05
        if MODE.startswith("slow:"):
            delay = int(MODE.split(":", 1)[1]) / 1000
        time.sleep(delay)
        if MODE == "garbage":
            return self.send_json(200, envelope("sure! here you go"))
        out = [f"⟦{target}⟧ {line}" for line in lines]
        if MODE == "short" and len(out) > 1:
            out = out[:-1]
        content = json.dumps({"translations": out}, ensure_ascii=False)
        if MODE == "fenced":
            content = "```json\n" + content + "\n```"
        self.send_json(200, envelope(content))


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
