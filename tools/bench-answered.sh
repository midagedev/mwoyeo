# Sourced by tools/paper-bench/run.sh and tools/usecase-bench/bench.sh (round flake117, 2026-10-22).
#
# WHY. Both benches skipped a scene whose <o>.out was non-empty, so a render that was cut, refused or read nothing stayed in the score as 0 blocks and a resumed run never looked at it again.
# A scene is DONE only when its render FINISHED and ANSWERED:
#   finished  <o>.load holds `rc=0`, the exit status the bench records after the render (a missing line is not finished: a cut run, or an output from before the line existed; the use-case bench
#             did not record it, so its older output directories are rendered again once);
#   answered  <o>.out holds at least one line `    → <text>` that is not `    → (no translation)`: the render read a block and gave an answer for it (a translation, or the text kept as written,
#             `kept: code`). That is the pair of lines (source, `→` answer) score.py of both benches reads; a render that read nothing (an empty .out, the Neural Engine stalled) or read blocks
#             and translated none (the engine did not answer in --max-wait) has none.
# A scene that is not done is rendered once more in the same run; the ones still not done are named in the closing line `unanswered: <n> <names>` (stderr, so the score output is what it was).
# A picture that holds nothing the reader can read is unanswered too, however often it is rendered (use-case pictures d08, d09 of the baseline): it costs one render more and is named, as a fact.
bench_answered() {   # <scene's output path without the extension>
    grep -Eq '^rc=0( |$)' "$1.load" 2>/dev/null || return 1
    grep '^    → ' "$1.out" 2>/dev/null | grep -qv '^    → (no translation)$'
}

bench_unanswered() {   # <names ...>
    echo "unanswered: $# $*" >&2
}
