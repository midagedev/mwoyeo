#!/bin/sh
# All checks that need no engine: corpus validation, scorer, judge and run-preservation unit tests, the preserved runs
# (every run has a manifest and score.py reproduces its summary), the runner's Swift tests, the render parity between the
# runner and the scorer. Usage: tests/run-all.sh [scratch dir for the Swift build]
set -e
cd "$(dirname "$0")/.."
SCRATCH="${1:-${TMPDIR:-/tmp}/translation-bench-build}"
python3 -I validate.py
python3 -I tests/test_score.py
python3 -I tests/test_judge.py
python3 -I tests/test_runs.py
python3 -I runs.py verify
(cd runner && swift test --scratch-path "$SCRATCH")
(cd runner && swift build --scratch-path "$SCRATCH")
python3 -I tests/check_render.py "$SCRATCH/debug/bench-run"
