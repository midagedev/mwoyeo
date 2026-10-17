# Example Mwoyeo command engine: reads one JSON line from stdin, prints one JSON line.
# Request:  {"source": "ja", "target": "ko", "lines": ["a", "b"]}
# Reply:    {"translations": ["[ko] a", "[ko] b"]}   or   {"error": "what went wrong"}
import json
import sys

req = json.loads(sys.stdin.readline())
print("loading...", file=sys.stderr)  # anything on stderr is ignored
print(json.dumps({"translations": [f"[{req['target']}] {line}" for line in req["lines"]]}, ensure_ascii=False))
