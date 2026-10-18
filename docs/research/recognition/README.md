# Recognition stall research (2026-10-18)

These are the investigations behind docs/design/recognition.md.

| File | What it covers |
|---|---|
| ocr-stall-112.md | The 1.1.2 RC's ~90 s silent lens: an in-process document read compiled ANE networks (34 s + 26 s) and blocked all Vision |
| flow-contention.md | Where OCR, translation, erase and drawing wait on each other: resource timeline and ranked contention points |
| vision-ane-stall.md | Vision on the ANE: device forcing does not avoid compiles, in-process serialisation, cancel, Code 13 streaks |
