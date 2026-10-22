#!/bin/bash
# fast117 gate: a line the language detector cannot be sure of reads in the page's language, whichever side of the long lines it stands on (design
# first-lens §13.6). Headless, on the fake Apple (MWOYEO_FAKE_ENGINE=slow:20: no model, no pack), the source on Detect. usage: check-groups.sh <Mwoyeo binary>
# <picture with short lines first (c01-slack-en.png: "# general", "Priya Shah", then "Morning all! ...")> <out dir>   (needs the Bash sandbox off and the scratch env)
# FAILURE MODE IT BLOCKS: the first batch of a lens splits by what each line was guessed alone ("# general" as Spanish, "Priya Shah" as French): one group per
# guess, the first Korean waits for the groups before the English one, and a guess with no language pack in it falls to the slow model (1.7 s of c01's first
# batch, measured; 30 ms when the batch is one English group).
BIN=${1:?binary}; PNG=${2:?picture}; OUT=${3:?out dir}; HERE=$(cd "$(dirname "$0")" && pwd); ANE=$HERE/../ane-env.sh
[ -n "${MWOYEO_SETTINGS_FILE:-}" ] && [ -n "${MWOYEO_DEFAULTS_SUITE:-}" ] && [ "${MWOYEO_MEMORY_SECRETS:-}" = 1 ] \
  || { echo "first-paint-groups: needs MWOYEO_SETTINGS_FILE, MWOYEO_DEFAULTS_SUITE and MWOYEO_MEMORY_SECRETS=1" >&2; exit 64; }
mkdir -p "$OUT"; fail=0
MWOYEO_FAKE_ENGINE=slow:20 MWOYEO_TRACE=1 "$ANE" run pool -- "$BIN" --render "$PNG" "$OUT/groups.png" --src auto --tgt ko --no-inpaint --warm --max-wait 60 \
    > "$OUT/groups.out" 2> "$OUT/groups.err" < /dev/null
first=$(grep -m1 'engine ←' "$OUT/groups.err")
[ -n "$first" ] || { echo "first-paint-groups: FAIL no engine call in the trace"; exit 1; }
ok() { if [ "$2" = 1 ]; then echo "first-paint-groups: PASS $1"; else echo "first-paint-groups: FAIL $1"; fail=1; fi; }
for line in '"# general"' '"Priya Shah"' '"Morning all!'; do
    ok "the first engine call holds $line" $(printf %s "$first" | grep -qF -- "$line" && echo 1 || echo 0)
done
calls=$(grep -c 'engine ←' "$OUT/groups.err")
echo "first-paint-groups: $calls engine calls in the run, the first: $(printf %s "$first" | cut -c1-200)"
exit $fail
