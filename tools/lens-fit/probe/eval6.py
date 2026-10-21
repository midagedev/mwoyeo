"""fit117 measurement 7: capture holds the whole column? Pure geometry on the film3 Preview screen (display 1512 x 982 pt, columns 149..737 and 777.5..1365.5, 588 pt wide),
lens x every 10 pt where the best column holds >= 40 % of the lens width and no rival (the same `under` rule), capture = Overscan.rect at rest / wide."""
import sys; sys.path.insert(0, '/tmp/r117/fit117/probe')
from columns import under
from overscan import capture_rect
COLS = [dict(left=149.0, right=737.5, top=0, bottom=982), dict(left=777.5, right=1365.5, top=0, bottom=982)]
D = (0, 0, 1512, 982)
print('%5s %8s %12s %12s' % ('W pt', 'lenses', 'rest: whole', 'wide: whole'))
for W in (240, 320, 400, 480, 600, 800):
    res = {False: [0, 0], True: [0, 0]}
    for x in range(0, 1512 - W + 1, 10):
        lens = (x, 300, W, 270); c = under(lens, COLS)
        if c is None: continue
        for wide in (False, True):
            cap = capture_rect(lens, wide, D); res[wide][1] += 1
            res[wide][0] += cap[0] <= c['left'] + 1 and cap[0] + cap[2] >= c['right'] - 1
    print('%5d %8d %11.0f%% %11.0f%%' % (W, res[False][1], 100 * res[False][0] / res[False][1], 100 * res[True][0] / res[True][1]))
