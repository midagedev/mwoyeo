#!/bin/bash
# Release build of the exported main HEAD with a cold scratch id. usage: build.sh <label>
W=$1; D=/tmp/r117/first117; L=/tmp/latin-runs
ID=$(cat $D/data/cold-id.txt)
cd $D/src || exit 9
xcodegen generate > $D/logs/gen-$W.log 2>&1 || { echo "xcodegen rc=$?" > $L/build-$W.rc; exit 1; }
xcodebuild -scheme Mwoyeo -destination "platform=macOS" -configuration Release -derivedDataPath $L/dd-$W build MWOYEO_APP_ID="$ID" > $L/build-$W.log 2>&1
echo "xcodebuild rc=$?" > $L/build-$W.rc
