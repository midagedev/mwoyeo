"""fit117: Overscan.swift in Python (margins at :17, rect at :36), the capture a lens holds."""
import math
GRID = 2
def margins(w, h, wide):
    m = (lambda v: min(max(v * 0.4, 160), 320)) if wide else (lambda v: min(max(v * 0.3, 80), 240))
    return m(w), m(h)
def _snap(v, rule=round):
    return rule(v / GRID) * GRID
def _rnd(v):   # toNearestOrAwayFromZero
    return math.floor(v + 0.5) if v >= 0 else -math.floor(-v + 0.5)
def capture_rect(lens, wide, display, lead=(0, 0)):
    """lens (x,y,w,h), display (x,y,w,h) -> capture (x,y,w,h), as Overscan.rect(around:wide:display:lead:)"""
    x, y, w, h = lens
    mw, mh = margins(w, h, wide)
    rx, ry, rw, rh = x - mw + max(-1, min(1, lead[0])) * mw / 2, y - mh + max(-1, min(1, lead[1])) * mh / 2, w + 2 * mw, h + 2 * mh
    dx, dy, dw, dh = display
    rw = math.floor(min(rw, dw) / GRID) * GRID
    rh = math.floor(min(rh, dh) / GRID) * GRID
    rx = min(max(_rnd(rx / GRID) * GRID, dx), dx + dw - rw)
    ry = min(max(_rnd(ry / GRID) * GRID, dy), dy + dh - rh)
    return (rx, ry, rw, rh)
if __name__ == '__main__':
    print(capture_rect((100, 300, 300, 250), False, (0, 0, 817, 1057)))
