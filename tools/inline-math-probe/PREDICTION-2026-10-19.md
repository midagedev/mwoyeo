Written before the first measure run (2026-10-19).
terms: spans/page = InlineMath hits on the Vision text (the app's own .out pairs hold 3 spans on p3-p6, but kept-math blocks are not in pairs) -> expect 5-15 per page and path, n total 20-50 per path.
clean% (Docs): 50-85 (sub/superscripts + tight boxes); VN: similar or lower. Decision expected: below 90 -> ink-grown box.
trim ok: >= 80 %. grown clean: base + 10 points or more. shrink(-30% h): clean drops by >= 25 points (every glyph top/bottom cut). grow(+1.3 lh down): (c) fails on >= 70 % of spans.
next action: clean>=90 -> M1/M2 as designed; 60-90 and grown>=90 -> ink-grown box in M1; grown<90 -> Plan B (char boxes).
