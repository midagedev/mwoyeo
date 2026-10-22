#!/bin/bash
cd /tmp/r117/first117
APP=/tmp/latin-runs/dd-first117/Build/Products/Release/Mwoyeo.app/Contents/MacOS/Mwoyeo
for n in p2 p4 p6 p7 p8 p10 p11 p12; do
  echo "load=$(uptime | sed 's/.*averages: //' | cut -d' ' -f1)" > data/vn-pages/$n.load
  env MWOYEO_TRACE=1 MWOYEO_MEMORY_SECRETS=1 MWOYEO_FAKE_ENGINE=fail MWOYEO_OCR_PATH=vn MWOYEO_DEFAULTS_SUITE=first117.vn MWOYEO_SETTINGS_FILE=$PWD/data/vn-pages/settings.json \
    /Users/hckim/repo/mwoyeo/tools/ane-env.sh run pool -- $APP --render /tmp/paper-quality/pages-own/$n.png data/vn-pages/$n.png --src en --tgt ko --no-inpaint --scale 2 --warm --max-wait 8 --no-drain > data/vn-pages/$n.out 2> data/vn-pages/$n.err < /dev/null
done
echo done > data/series-vnpages.done
