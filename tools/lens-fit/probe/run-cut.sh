#!/bin/bash
# fit117: block rects of two real Preview screenshots (film3), through the app's own headless render. Needs the Bash sandbox off.
export PAGES=/tmp/r117/fit117/cut-pages
BIN=/tmp/latin-runs/dd-d14main/Build/Products/Debug/Mwoyeo.app/Contents/MacOS/Mwoyeo
cd /Users/hckim/repo/mwoyeo
MWOYEO_MEMORY_SECRETS=1 tools/paper-bench/run.sh "$BIN" /tmp/r117/fit117/cut-out > /tmp/r117/fit117/cut-run.log 2>&1
echo "rc=$?" > /tmp/r117/fit117/cut-run.rc
