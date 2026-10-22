// Windows of other processes that lie in front of the Preview window and over the filmed frame (JXA, read only).
// usage: osascript -l JavaScript foreign.js <preview pid> <my app pid or 0> <window name part> <x:y:w:h in points>
// prints one line per intruder: owner pid x y w h layer name. Nothing printed = the frame is clean. Windows behind the Preview window are not seen by the viewer and are not counted.
ObjC.import('CoreGraphics')
function run(argv) {
    const pv = parseInt(argv[0]), app = parseInt(argv[1]), part = argv[2], f = argv[3].split(':').map(Number)
    const list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1, 0)))   // kCGWindowListOptionOnScreenOnly, kCGNullWindowID
    const out = []
    for (const w of list) {                                  // front to back
        const pid = w.kCGWindowOwnerPID, b = w.kCGWindowBounds, name = w.kCGWindowName || ''
        if (pid === pv && name.indexOf(part) >= 0) break     // reached the filmed window: everything after it is hidden by it
        if (pid === pv || pid === app || w.kCGWindowLayer < 0 || (w.kCGWindowAlpha !== undefined && w.kCGWindowAlpha === 0)) continue
        if (b.Width < 2 || b.Height < 2) continue
        if (w.kCGWindowOwnerName === 'Dock' && b.Width >= 1000 && b.Height >= 900) continue   // the Dock's full-screen tracking window: transparent, always there
        if (b.X < f[0] + f[2] && b.X + b.Width > f[0] && b.Y < f[1] + f[3] && b.Y + b.Height > f[1])
            out.push([w.kCGWindowOwnerName, pid, Math.round(b.X), Math.round(b.Y), Math.round(b.Width), Math.round(b.Height), w.kCGWindowLayer, name].join(' '))
    }
    return out.join('\n')
}
