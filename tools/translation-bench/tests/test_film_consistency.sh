#!/bin/sh
# film_consistency.py on a tiny fixture: a name rendered three ways (one listed wrong form, one string found only by alignment
# with the reference), a term rendered two ways, and a speech-level probe that fails. The numbers are fixed by hand below;
# every assertion names what it blocks. Run it before the script exists and it must fail (FAIL-first).
# Usage: tests/test_film_consistency.sh
set -u
cd "$(dirname "$0")/.." || exit 2
TMP=$(mktemp -d "${TMPDIR:-/tmp}/film-consistency.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/sequences" "$TMP/memory" "$TMP/run"

cat > "$TMP/sequences/mini.json" <<'EOF'
{
 "id": "mini", "kind": "game", "source": "ja", "target": "ko", "title": "fixture", "speaker_visible": true,
 "lines": [
  {"id": 1, "speaker": "アキ", "to": "ルネ", "text": "ルネ、魔石だ", "ref": "르네, 마정석이다."},
  {"id": 2, "speaker": "アキ", "to": "ルネ", "text": "ルネは魔石を見た", "ref": "르네는 마정석을 보았다."},
  {"id": 3, "speaker": "アキ", "to": "ルネ", "text": "魔石を持つルネ", "ref": "마정석을 가진 르네"},
  {"id": 4, "text": "夜が明けた", "ref": "밤이 밝았다."}
 ],
 "screens": [[1, 2], [2, 3], [3, 4]],
 "probes": [
  {"id": "p1", "type": "name", "line": 1, "by": "memory", "mem": ["entities.ルネ.dst"], "evidence": ["르네"], "key": "ent:ルネ", "check": {"any": ["르네"], "none": ["루네"]}, "bad_sub": ["르네", "루네"]},
  {"id": "p2", "type": "name", "line": 2, "by": "memory", "mem": ["entities.ルネ.dst"], "evidence": ["르네"], "key": "ent:ルネ", "check": {"any": ["르네"], "none": ["루네"]}, "bad_sub": ["르네", "루네"]},
  {"id": "p3", "type": "name", "line": 3, "by": "memory", "mem": ["entities.ルネ.dst"], "evidence": ["르네"], "key": "ent:ルネ", "check": {"any": ["르네"], "none": ["루네"]}, "bad_sub": ["르네", "루네"]},
  {"id": "p4", "type": "term", "line": 1, "by": "memory", "mem": ["terms.魔石"], "evidence": ["마정석"], "key": "term:魔石", "check": {"any": ["마정석"], "none": ["마석"]}, "bad_sub": ["마정석", "마석"]},
  {"id": "p5", "type": "term", "line": 2, "by": "memory", "mem": ["terms.魔石"], "evidence": ["마정석"], "key": "term:魔石", "check": {"any": ["마정석"], "none": ["마석"]}, "bad_sub": ["마정석", "마석"]},
  {"id": "p6", "type": "term", "line": 3, "by": "memory", "mem": ["terms.魔石"], "evidence": ["마정석"], "key": "term:魔石", "check": {"any": ["마정석"], "none": ["마석"]}, "bad_sub": ["마정석", "마석"]},
  {"id": "p7", "type": "speech_level", "line": 1, "by": "memory", "mem": ["entities.アキ.speaks_to"], "evidence": ["반말"], "check": {"level": "banmal"}, "bad": "르네, 마정석입니다."},
  {"id": "p8", "type": "speech_level", "line": 2, "by": "memory", "mem": ["entities.アキ.speaks_to"], "evidence": ["반말"], "check": {"level": "banmal"}, "bad": "르네는 마정석을 보았습니다."}
 ]
}
EOF
cat > "$TMP/memory/mini.json" <<'EOF'
{"entities": [{"name": "アキ", "dst": "아키", "speaks_to": {"ルネ": "반말"}}, {"name": "ルネ", "dst": "르네"}],
 "terms": [{"src": "魔石", "dst": "마정석"}]}
EOF
cat > "$TMP/run/meta.json" <<'EOF'
{"condition": "A", "engine": "fixture-engine", "model": "fixture", "layout": "t2", "kind": "openAICompatible", "jobs": 1, "batch_size": 3, "price": "local", "sequences": ["mini"]}
EOF
# line 1: canonical name and term but polite ending (speech probe fails); line 2: listed wrong forms; line 3: a name found only by alignment
cat > "$TMP/run/mini.json" <<'EOF'
{"id": "mini", "condition": "A", "requests": [],
 "translations": {"1": "르네, 마정석입니다.", "2": "루네는 마석을 보았다.", "3": "마정석을 가진 뤼네", "4": "밤이 밝았다."}}
EOF

mkdir -p "$TMP/run2"
cp "$TMP/run/meta.json" "$TMP/run2/meta.json"
cat > "$TMP/run2/mini.json" <<'EOF'
{"id": "mini", "condition": "A", "requests": [],
 "translations": {"1": "르네, 마정석입니다.", "2": "르네는 마정석을 보았다.", "3": "마정석을 가진 뤼네", "4": "밤이 밝았다."}}
EOF

fails=0
check() {   # description, python expression over r (the first run of --json) that must be true
  if python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
r = d["runs"][0]
sys.exit(0 if eval(sys.argv[2]) else 1)' "$TMP/out.json" "$2"; then echo "PASS $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}

python3 -I film_consistency.py --root "$TMP" --json "$TMP/out.json" "$TMP/run" > "$TMP/out.txt" 2>&1
rc=$?
if [ $rc -ne 0 ]; then echo "FAIL film_consistency.py exited $rc"; cat "$TMP/out.txt"; exit 1; fi
check "the name shows three renderings (canonical, a listed wrong form, an aligned string)" \
  'r["keys"]["ent:ルネ"]["renderings"] == {"르네": 1, "루네": 1, "뤼네": 1}'
check "the term shows two renderings (canonical twice, one listed wrong form)" \
  'r["keys"]["term:魔石"]["renderings"] == {"마정석": 2, "마석": 1}'
check "a key with three renderings is not consistent, one with two is not either" \
  'r["names_consistent"] == [0, 1] and r["terms_consistent"] == [0, 1]'
check "a speaker with one line is not counted as a name (アキ appears in no text)" \
  '"ent:アキ" not in r["keys"]'
check "speech level: line 1 polite fails, line 2 plain passes" 'r["speech"] == [1, 2]'
check "probes: p1 p4 p6 p8 pass, p2 p3 p5 p7 fail" \
  'r["probes"] == [4, 8]'
check "no line is echoed or holds a kana in the fixture run" 'r["echo_kana"] == [0, 0, 4]'
check "one run gives one row" 'len(d["runs"]) == 1'
python3 -I film_consistency.py --root "$TMP" --json "$TMP/rep.json" --repeat "$TMP/run" "$TMP/run2" > "$TMP/rep.txt" 2>&1
if python3 -I -c '
import json, sys
a = json.load(open(sys.argv[1]))["repeats"][0]
sys.exit(0 if a["lines"] == [3, 4] and a["probes"] == [6, 8] and a["keys"] == [0, 2] else 1)' "$TMP/rep.json" && grep -q "identical lines 3/4" "$TMP/rep.txt"
then echo "PASS a repeat with line 2 changed: 3 of 4 lines identical, 6 of 8 verdicts, no key with the same renderings"
else echo "FAIL repeat agreement of two runs"; fails=$((fails + 1)); fi
if python3 -I -c '
import importlib.util, sys
sp = importlib.util.spec_from_file_location("fc", sys.argv[1]); F = importlib.util.module_from_spec(sp); sp.loader.exec_module(F)
got = F.merge_contained(["월계의신사", "월계의신사는내", "달빛", "(unaligned)", "츠", "큐츠"])
sys.exit(0 if got == {"월계의신사": "월계의신사", "월계의신사는내": "월계의신사", "달빛": "달빛", "(unaligned)": "(unaligned)", "츠": "츠", "큐츠": "큐츠"} else 1)' film_consistency.py
then echo "PASS an aligned string that contains a shorter one counts as the shorter (one-character strings merge nothing)"
else echo "FAIL aligned strings that contain a shorter one are one rendering"; fails=$((fails + 1)); fi
grep -q "fixture-engine" "$TMP/out.txt" && echo "PASS the table names the engine" || { echo "FAIL the table names the engine"; fails=$((fails + 1)); }
[ $fails -eq 0 ] && echo "test_film_consistency: ok" || { echo "test_film_consistency: $fails FAILED"; exit 1; }
