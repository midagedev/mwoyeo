# Command engines

A command engine is any program Mwoyeo can run. For each batch it writes one JSON line to the program's stdin and
reads one JSON line from stdout:

    in:   {"source": "ja", "target": "ko", "lines": ["...", "..."]}     (source is null when unknown)
    out:  {"translations": ["...", "..."]}                               one string per line, same order
    err:  {"error": "what went wrong"}

Lines printed before the answer (logs, warnings) are ignored: the last stdout line that is a JSON object counts.
Set the engine up with the program path and its arguments, for example `/usr/bin/python3` and `/path/to/my-engine.py`.

Try the example:

    echo '{"source":"ja","target":"ko","lines":["a","b"]}' | python3 -I echo-engine.py

## Wrap a Python model in 15 lines

```python
import json, sys
from transformers import pipeline

translate = pipeline("translation", model="Helsinki-NLP/opus-mt-ja-en")  # any model you have

req = json.loads(sys.stdin.readline())
try:
    out = [r["translation_text"] for r in translate(req["lines"])]
    print(json.dumps({"translations": out}, ensure_ascii=False))
except Exception as e:
    print(json.dumps({"error": str(e)}))
```

## Wrap a CLI

```sh
#!/bin/sh
# my-engine.sh: needs jq and a CLI that translates stdin to stdout, one line each.
req=$(head -n 1)
target=$(echo "$req" | jq -r .target)
echo "$req" | jq -r '.lines[]' | my-translate-cli --to "$target" | jq -R . | jq -cs '{translations: .}'
```
