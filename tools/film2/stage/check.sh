#!/bin/bash
# The stage's own checks, each with its FAIL-first mutation (a check that passes on a stage it should reject is no check):
#   1. the real stage passes shoot.sh (LINES equal the sequence, every line in two) and contrast.py (>= 7:1);
#   2. a stage with 72 px text needs three lines for L4          -> shoot.sh must exit 1 ("needs 3 lines");
#   3. a stage whose LINES copy has one character changed        -> shoot.sh must exit 1 ("LINES differ");
#   4. a stage with a light panel                                -> contrast.py must exit 1 ("FAIL ... contrast").
# usage: check.sh   (needs Chrome and the Bash sandbox off); the log lines are the evidence.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); M=${SCRATCH:-/tmp/film2/plates}/mut; rm -rf "$M"; mkdir -p "$M"
fail=0
say() { echo "check: $1 $2"; [ "$1" = PASS ] || fail=1; }

OUT=$M/real "$HERE/shoot.sh" 2 4 19 > "$M/real.log" 2>&1 && python3 -I "$HERE/contrast.py" "$M"/real/L*.png >> "$M/real.log" 2>&1 \
    && say PASS "the stage: $(grep '^contrast' "$M/real.log")" || say FAIL "the stage ($(tail -1 "$M/real.log"))"

python3 -I - "$HERE/scene.html" "$M" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read(); m = sys.argv[2]
def write(name, old, new):
    assert old in s, old
    open("%s/%s.html" % (m, name), "w", encoding="utf-8").write(s.replace(old, new, 1))
write("big", "font-size: 36px; line-height: 1.5", "font-size: 72px; line-height: 1.5")
write("drift", "シュザンヌ様、お急ぎになりませぬよう", "シュザンヌ様、お急ぎになりませんよう")
write("light", "--panel: rgba(8, 12, 26, 0.90)", "--panel: rgba(150, 158, 190, 0.90)")
PY
STAGE=$M/big.html OUT=$M/big "$HERE/shoot.sh" 4 > "$M/big.log" 2>&1; rc=$?
[ $rc -eq 1 ] && grep -q "needs [3-9] lines" "$M/big.log" && say PASS "72 px text rejected: $(grep 'needs' "$M/big.log" | head -1)" || say FAIL "72 px text not rejected (rc $rc)"
STAGE=$M/drift.html OUT=$M/drift "$HERE/shoot.sh" 4 > "$M/drift.log" 2>&1; rc=$?
[ $rc -eq 1 ] && grep -q "LINES differ" "$M/drift.log" && say PASS "drifted LINES rejected: $(grep 'differ' "$M/drift.log" | head -1)" || say FAIL "drifted LINES not rejected (rc $rc)"
STAGE=$M/light.html OUT=$M/light "$HERE/shoot.sh" 4 > "$M/light.log" 2>&1
python3 -I "$HERE/contrast.py" "$M/light/L4.png" > "$M/light.contrast" 2>&1; rc=$?
[ $rc -eq 1 ] && grep -q "^FAIL" "$M/light.contrast" && say PASS "light panel rejected: $(grep '^FAIL' "$M/light.contrast" | head -1)" || say FAIL "light panel not rejected (rc $rc)"
exit $fail
