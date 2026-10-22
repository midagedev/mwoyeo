// first117: posts HID events on command and says when, on the monotonic clock the other tools share (CLOCK_UPTIME_RAW, ns).
// Commands on stdin, one per line:  key <keycode> [ctrl,opt,shift,cmd]   move <x> <y>   down <x> <y>   up <x> <y>   click <x> <y>   quit
// Each answers "<cmd> <t_ns>" on stdout, the time just before the event was posted. Points are global, top-left origin.
import CoreGraphics
import Foundation

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
let src = CGEventSource(stateID: .hidSystemState)
func flags(_ s: String) -> CGEventFlags {
    var f: CGEventFlags = []
    for p in s.split(separator: ",") {
        switch p { case "ctrl": f.insert(.maskControl); case "opt": f.insert(.maskAlternate); case "shift": f.insert(.maskShift); case "cmd": f.insert(.maskCommand); default: break }
    }
    return f
}
while let line = readLine() {
    let p = line.split(separator: " ").map(String.init)
    guard let cmd = p.first else { continue }
    let t = now()
    switch cmd {
    case "key":
        let code = CGKeyCode(UInt16(p[1]) ?? 0), f = p.count > 2 ? flags(p[2]) : []
        let d = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true); d?.flags = f; d?.post(tap: .cghidEventTap)
        let u = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false); u?.flags = f; u?.post(tap: .cghidEventTap)
    case "move", "down", "up", "click":
        let pt = CGPoint(x: Double(p[1]) ?? 0, y: Double(p[2]) ?? 0)
        func ev(_ type: CGEventType) { CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pt, mouseButton: .left)?.post(tap: .cghidEventTap) }
        switch cmd {
        case "move": ev(.mouseMoved)
        case "down": ev(.leftMouseDown)
        case "up": ev(.leftMouseUp)
        default: ev(.mouseMoved); usleep(30_000); ev(.leftMouseDown); usleep(40_000); ev(.leftMouseUp)
        }
    case "quit": exit(0)
    default: break
    }
    print("\(cmd) \(t)"); fflush(stdout)
}
