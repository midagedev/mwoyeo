#!/bin/sh
# All checks that need no engine: corpus validation, scorer, judge (and judge-run and judge-report, on a fake agy and planted verdicts) and run-preservation unit tests, the preserved runs
# (every run has a manifest and score.py reproduces its summary), the runner's Swift tests, the render parity between the
# runner and the scorer, the failure and leak counters (and that they fail when neutered), runs/SUMMARY.md being current.
# Usage: tests/run-all.sh [scratch dir for the Swift build]
set -e
cd "$(dirname "$0")/.."
SCRATCH="${1:-${TMPDIR:-/tmp}/translation-bench-build}"
python3 -I validate.py
python3 -I tests/test_score.py
python3 -I tests/test_judge.py
python3 -I tests/test_judge_run.py
python3 -I tests/test_judge_report.py
python3 -I tests/test_runs.py
python3 -I runs.py verify
python3 -I tests/test_failures.py
# FAIL-first: the same checks with the leak detection switched off must fail, or they would pass on the unfixed scorer
if python3 -I tests/test_failures.py --neuter >/dev/null 2>&1; then echo "test_failures passed with the leak counter neutered" >&2; exit 1; fi
python3 -I tests/test_latency.py
python3 -I tests/test_summary.py
python3 -I summary.py --check
(cd runner && swift test --scratch-path "$SCRATCH")
(cd runner && swift build --scratch-path "$SCRATCH")
python3 -I tests/check_render.py "$SCRATCH/debug/bench-run"
