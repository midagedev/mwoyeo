#!/bin/bash
# fast117 gate: the first paint end to end, headless, on the fake Apple (MWOYEO_FAKE_ENGINE=first-paint:<quick ms>:<final ms>): the real service,
# pipeline, book and transcript writer; no Apple model. usage: check.sh <Mwoyeo binary> <picture> <out dir>      (needs the Bash sandbox off and the scratch env)
# The final model's 4000 ms is longer than the translation log's hold (`TranscriptMerger.hold`, 3 s): a quick text that reached the log would be
# written, not folded into the final one.
# FAILURE MODES IT BLOCKS: a quick text in the translation log (the person's log would hold two translations of a line); a final text that differs
# from today's; a first paint outside the lens's first batch; a quick text painted with the setting off; a replacement drawn again when the text is equal.
BIN=${1:?binary}; PNG=${2:?picture}; OUT=${3:?out dir}; HERE=$(cd "$(dirname "$0")" && pwd); ANE=$HERE/../ane-env.sh
# A dev binary starts only on scratch state (2026-10-22: a bare launch rewrote the user's settings.schema.json).
[ -n "${MWOYEO_SETTINGS_FILE:-}" ] && [ -n "${MWOYEO_DEFAULTS_SUITE:-}" ] && [ "${MWOYEO_MEMORY_SECRETS:-}" = 1 ] \
  || { echo "first-paint-check: needs MWOYEO_SETTINGS_FILE, MWOYEO_DEFAULTS_SUITE and MWOYEO_MEMORY_SECRETS=1" >&2; exit 64; }
mkdir -p "$OUT"; rm -rf "$OUT"/tr-* ; fail=0
run() {  # <name> <extra args...>
  n=$1; shift
  MWOYEO_FAKE_ENGINE=first-paint:200:4000 MWOYEO_TRACE=1 "$ANE" run pool -- "$BIN" --render "$PNG" "$OUT/$n.png" --src en --tgt ko --no-inpaint --warm --max-wait 90 \
      --first-paint-log --transcript "$OUT/tr-$n" --transcript-formats jsonl "$@" > "$OUT/$n.out" 2> "$OUT/$n.err" < /dev/null
}
ok() { if [ "$2" = 1 ]; then echo "first-paint-check: PASS $1"; else echo "first-paint-check: FAIL $1"; fail=1; fi; }
run off; run on --first-paint
summ() { grep '^fp-summary' "$OUT/$1.out" | head -1; }
num() { summ "$1" | sed -n "s/.* $2=\([0-9]*\).*/\1/p"; }
for n in off on; do [ -n "$(summ $n)" ] || { echo "first-paint-check: FAIL $n: no fp-summary line (a binary without the first paint prints none)"; exit 1; }; done
ok "off: nothing is painted before its translation" $([ "$(num off painted)" = 0 ] && echo 1 || echo 0)
ok "off: no quick text anywhere in the output" $([ "$(grep -c ':ll⟧' "$OUT/off.out")" = 0 ] && echo 1 || echo 0)
for n in on; do
  p=$(num $n painted); r=$(num $n repainted); k=$(num $n kept); o=$(num $n open)
  ok "$n: only the first batch is painted first (1 to 3 lines)" $([ "$p" -ge 1 ] && [ "$p" -le 3 ] && echo 1 || echo 0)
  ok "$n: every quick text was replaced or kept, none left open ($p painted = $r repainted + $k kept)" $([ "$o" = 0 ] && [ "$p" = $((r + k)) ] && echo 1 || echo 0)
  ok "$n: a line whose final text is the quick one is kept ($k), and only the repainted ones are drawn again" \
     $([ "$k" -ge 1 ] && [ "$(sed -n 's/.* first_paint\.redrawn=\([0-9]*\).*/\1/p' "$OUT/$n.out" | head -1)" = "$r" ] && echo 1 || echo 0)
  ok "$n: the translator's cache holds the final text of every line and no quick one" \
     $([ "$(grep -c '^fp-cache:' "$OUT/$n.out")" = "$(grep -c '^fp-cache:' "$OUT/off.out")" ] && [ "$(grep -c '^fp-cache:' "$OUT/$n.out")" -ge 1 ] && [ "$(grep '^fp-cache:' "$OUT/$n.out" | grep -c ':ll⟧')" = 0 ] && echo 1 || echo 0)
  ok "$n: the log holds no quick text" $([ "$(cat "$OUT"/tr-$n/*.jsonl | grep -c ':ll⟧')" = 0 ] && echo 1 || echo 0)
  ok "$n: the log holds as many lines as with the setting off" $([ "$(cat "$OUT"/tr-$n/*.jsonl | grep -c .)" = "$(cat "$OUT"/tr-off/*.jsonl | grep -c .)" ] && echo 1 || echo 0)
  ok "$n: the final text of every line is the one with the setting off" \
     $(diff <(grep '^    → ' "$OUT/off.out" | sort) <(grep '^    → ' "$OUT/$n.out" | sort) > /dev/null && echo 1 || echo 0)
  ok "$n: the quick text was drawn before the final one" \
     $(python3 - "$OUT/$n.out" <<'PY'
import re,sys
rows=[l for l in open(sys.argv[1]) if l.startswith('fp-line:') and 'quick_first=1' in l]
ok=bool(rows)
for l in rows:
    d=int(re.search(r'drawn_ms=(\d+)',l).group(1)); f=int(re.search(r'final_ms=(\d+)',l).group(1))
    ok&=d<f
print(1 if ok else 0)
PY
)
done
exit $fail
