#!/bin/bash
# Gate of tools/bench-answered.sh and its two users, tools/paper-bench/run.sh and tools/usecase-bench/bench.sh (round flake117, 2026-10-22). Seconds, no app: the "app" is a fake BIN whose
# answer for a scene is a table, run through a scratch copy of the benches (a stub census, no lease, no disk floor); the user's settings and caches are never touched.
#   usage: bench-answered-check.sh     env: TOOLS=<a tools dir>  (default: this tree's; the FAIL-first points it at main's, whose benches skip any scene whose .out is not empty)
#                                           OUT=<scratch dir>    (default /tmp/bench-answered/check)
# FAILURE MODE IT BLOCKS: a render that was cut, refused or read nothing leaves an .out that is empty or has no answer, and the bench skipped that scene for ever, so it stayed 0 blocks in
# the score. The fake BIN answers a scene once empty and then really (the retry), never (named at the end), with an answer but a bad exit status (not finished), and the scenes
# found on disk are a done one (not rendered again), one with an .out and no answer (rendered again) and, in the use-case bench, one from before `rc=` was recorded (rendered again).
# Each check is also run on a scratch copy of the benches with one piece broken (the retry, the done test), and must FAIL there.
# One PASS/FAIL line per check; exit 0 when all pass.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TOOLS=${TOOLS:-$HERE}
S=${OUT:-/tmp/bench-answered/check}
rm -rf "$S"; mkdir -p "$S"
fail=0
say() { echo "$@" | tee -a "$S/summary.txt"; }
check() {   # name, 0|1 (1 = ok), detail
    if [ "$2" = 1 ]; then say "PASS $1 $3"; else say "FAIL $1 $3"; fail=1; fi
}

# The fake render: `--render <in.png> <out.png> ...`; the scene is the input's name, the answer depends on how often it was asked.
cat > "$S/fake" <<'EOF'
#!/bin/bash
scene=$(basename "$2" .png)
echo x >> "$CALLS/$scene"
n=$(wc -l < "$CALLS/$scene" | tr -d ' ')
good() { printf 'inpainter: none\nwork[still]: erase=1 ocr.blocks=1\n  Hello world\n    → 안녕 세상\nissues=0\nlayout: blocks=1 overlaps=0 spill=0 cut=0 clipped=0 holds=0\nimage: 100×50\n'; }
case "$scene:$n" in
    p1:1|c01-slack-en:1) printf 'warm-up: 1 ms\n' ;;                                             # read nothing, exit 0
    p2-c2:1) good; exit 3 ;;                                                                    # an answer, and an exit status that says the render did not finish
    p1-c1:*|d08-tategaki-ja:*) printf 'warm-up: 1 ms\n  Hello world\n    → (no translation)\n' ;; # read a block, translated none, every time
    *) good ;;
esac
EOF
chmod +x "$S/fake"

# A scratch copy of the benches (what each needs), with `mut` applied to the two scripts when given: a sed expression run on each.
tree() {   # name [sed expr] -> $S/<name>/tools
    local t=$S/$1/tools f
    mkdir -p "$t/paper-bench" "$t/usecase-bench/set" "$t/ane-census"
    cp "$TOOLS/ane-env.sh" "$t/"; [ -f "$TOOLS/bench-answered.sh" ] && cp "$TOOLS/bench-answered.sh" "$t/"
    cp "$TOOLS/paper-bench/score.py" "$TOOLS/paper-bench/allow.txt" "$t/paper-bench/"
    cp "$TOOLS/usecase-bench/score.py" "$t/usecase-bench/"
    for f in paper-bench/run.sh usecase-bench/bench.sh; do
        if [ -n "${2:-}" ]; then sed "$2" "$TOOLS/$f" > "$t/$f"; else cp "$TOOLS/$f" "$t/$f"; fi
        chmod +x "$t/$f"
    done
    printf '#!/usr/bin/env python3\n' > "$t/ane-census/census.py"
    # three scenes of the use-case set, whatever their expected texts are
    printf 'name\tuse_case\tsrc\twidth\theight\n' > "$t/usecase-bench/set/index.tsv"
    for f in c01-slack-en c02-kakao-ko d08-tategaki-ja; do
        awk -F'\t' -v n="$f" '$1 == n' "$TOOLS/usecase-bench/set/index.tsv" >> "$t/usecase-bench/set/index.tsv"
        cp "$TOOLS/usecase-bench/set/$f.expected.txt" "$t/usecase-bench/set/" 2>/dev/null
    done
}

# paper-bench: p1 empty then answered, p2 answered, p2-c2 answered with rc=3 then answered, p1-c1 never answers, p3 found done, p4 found with an .out and no answer
run_paper() {   # tree -> runs the bench once into $S/<tree>/paper (calls kept across runs of the same tree); stderr in paper.err
    local t=$S/$1 d=$S/$1/pages
    mkdir -p "$d" "$t/calls-paper"
    for n in p1 p2 p2-c2 p1-c1 p3 p4; do : > "$d/$n.png"; done
    if [ ! -d "$t/paper" ]; then
        mkdir -p "$t/paper"
        printf '  Hello world\n    → 안녕 세상\nlayout: blocks=1 overlaps=0 spill=0 cut=0 clipped=0 holds=0\nimage: 100×50\n' > "$t/paper/p3.out"; printf 'load=1 start=1\nrc=0 end=2\n' > "$t/paper/p3.load"
        printf 'warm-up: 1 ms\n' > "$t/paper/p4.out"; printf 'load=1 start=1\nrc=0 end=2\n' > "$t/paper/p4.load"
    fi
    CALLS=$t/calls-paper PAGES=$d ANE_LEASE=off FREE_KB=20971520 ANE_LOCK=$S/lock "$t/tools/paper-bench/run.sh" "$S/fake" "$t/paper" > "$t/paper.out" 2> "$t/paper.err"
    echo $? > "$t/paper.rc"
}
calls() {   # dir scene -> how many times the fake was asked for it
    if [ -f "$1/$2" ]; then wc -l < "$1/$2" | tr -d ' '; else echo 0; fi
}
paper_ok() {   # tree -> 0 when the paper bench behaved (the checks below, one line each)
    local t=$S/$1 c=$S/$1/calls-paper
    echo "p1=$(calls $c p1) p2=$(calls $c p2) p2-c2=$(calls $c p2-c2) p1-c1=$(calls $c p1-c1) p3=$(calls $c p3) p4=$(calls $c p4) | $(tail -1 "$t/paper.err")"
}

tree good
run_paper good
r=$(paper_ok good)
check "paper-bench: an empty render is made once more, one that exits 3 too, the one never answered is made twice and no more, a done scene is not rendered, one with an .out and no answer is" \
    $([ "$r" = "p1=2 p2=1 p2-c2=2 p1-c1=2 p3=0 p4=1 | unanswered: 1 p1-c1" ] && echo 1 || echo 0) "$r"
run_paper good
r2=$(paper_ok good)
check "paper-bench: asked again, only the scene that never answered is rendered again (twice), and it is named again" \
    $([ "$r2" = "p1=2 p2=1 p2-c2=2 p1-c1=4 p3=0 p4=1 | unanswered: 1 p1-c1" ] && echo 1 || echo 0) "$r2"
check "paper-bench: the exit status is the scorer's (0 with 1 unanswered) and the score still comes out" $([ "$(cat "$S/good/paper.rc")" = 0 ] && grep -q '^TOTAL\|^total\|formula_translated' "$S/good/paper.out" && echo 1 || echo 0) "rc=$(cat "$S/good/paper.rc") $(head -c 80 "$S/good/paper.out" | head -1)"

# use-case bench: c01 empty then answered, c02 found from before `rc=` was recorded (an answer and no rc line), d08 never answers
run_uc() {   # tree
    local t=$S/$1 d=$S/$1/pngs
    mkdir -p "$d" "$t/calls-uc" "$t/uc/out"
    for n in c01-slack-en c02-kakao-ko d08-tategaki-ja; do : > "$d/$n.png"; done
    if [ ! -f "$t/uc/out/c02-kakao-ko-vn.out" ]; then
        printf '  Hello world\n    → 안녕 세상\nlayout: blocks=1 overlaps=0 spill=0 cut=0 clipped=0 holds=0\n' > "$t/uc/out/c02-kakao-ko-vn.out"; echo 0.5 > "$t/uc/out/c02-kakao-ko-vn.load"
    fi
    CALLS=$t/calls-uc PNGS=$d OUT=$t/uc ANE_LEASE=off FREE_KB=20971520 ANE_LOCK=$S/lock "$t/tools/usecase-bench/bench.sh" "$S/fake" vn > "$t/uc.out" 2> "$t/uc.err"
    echo $? > "$t/uc.rc"
}
uc_ok() {
    local t=$S/$1 c=$S/$1/calls-uc
    echo "c01=$(calls $c c01-slack-en) c02=$(calls $c c02-kakao-ko) d08=$(calls $c d08-tategaki-ja) | $(tail -1 "$t/uc.err")"
}
run_uc good
u=$(uc_ok good)
check "usecase-bench: an empty render is made once more, one from before the exit status was recorded is made again, the one never answered is made twice and named" \
    $([ "$u" = "c01=2 c02=1 d08=2 | unanswered: 1 d08-tategaki-ja-vn" ] && echo 1 || echo 0) "$u"
check "usecase-bench: the exit status of each render is recorded in its .load (rc=0), and the bench exits with the scorer's status" \
    $([ "$(cat "$S/good/uc.rc")" = 0 ] && grep -q 'rc=0' "$S/good/uc/out/c01-slack-en-vn.load" && echo 1 || echo 0) "rc=$(cat "$S/good/uc.rc") load=$(tr '\n' ' ' < "$S/good/uc/out/c01-slack-en-vn.load" 2>/dev/null)"

# the checks must be able to FAIL: the same scenario on a copy of the benches with the retry gone, and with the old done test (an .out that is not empty)
tree noretry 's/for try in 1 2; do/for try in 1; do/'
run_paper noretry; r=$(paper_ok noretry)
check "paper-bench: with the retry cut to one try the check FAILS (FAIL-first of the retry)" $([ "$r" != "p1=2 p2=1 p2-c2=2 p1-c1=2 p3=0 p4=1 | unanswered: 1 p1-c1" ] && echo 1 || echo 0) "$r"
tree olddone 's/bench_answered "\$o" \&\& continue/[ -s "$o.out" ] \&\& continue/'
run_paper olddone; r=$(paper_ok olddone)
check "paper-bench: with the old done test (a non-empty .out) the check FAILS (FAIL-first of the done test)" $([ "$r" != "p1=2 p2=1 p2-c2=2 p1-c1=2 p3=0 p4=1 | unanswered: 1 p1-c1" ] && echo 1 || echo 0) "$r"
run_uc noretry; u=$(uc_ok noretry)
check "usecase-bench: with the retry cut to one try the check FAILS" $([ "$u" != "c01=2 c02=1 d08=2 | unanswered: 1 d08-tategaki-ja-vn" ] && echo 1 || echo 0) "$u"
run_uc olddone; u=$(uc_ok olddone)
check "usecase-bench: with the old done test the check FAILS" $([ "$u" != "c01=2 c02=1 d08=2 | unanswered: 1 d08-tategaki-ja-vn" ] && echo 1 || echo 0) "$u"

echo "bench-answered-check: $([ $fail = 0 ] && echo 'all passed' || echo FAILED) ($S/summary.txt)"
exit $fail
