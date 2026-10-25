// film4: posts HID pointer and key events for a take and logs each one, on the clock the recorder shares (CLOCK_UPTIME_RAW, ns).
// Grown from first117's post.swift (key/move/down/up/click) with the paths a film needs: a hand moves on a minimum-jerk curve (optionally bent
// through a control point), never in straight constant-speed lines, and a drag is the same curve with the button held.
// Usage: post <events.jsonl>; commands on stdin, one per line (points global, top-left origin):
//   key <keycode> [ctrl,opt,shift,cmd]       a chord (down + up)
//   mods <ctrl,opt,shift,cmd|none>            hold these modifiers (flagsChanged), e.g. ⌘ during a drag; `mods none` lets go
//   move <x> <y>                              one mouseMoved
//   path <ms> <x0> <y0> <x1> <y1> [<cx> <cy>] mouseMoved along a minimum-jerk curve at 120 Hz (bent through c when given)
//   drag <ms> <x0> <y0> <x1> <y1> [<cx> <cy>] the same as leftMouseDragged (after `down`)
//   down <x> <y> | up <x> <y> | click <x> <y> | dclick <x> <y>
//   quit
// Each command answers "<cmd> <t_start_ns> <t_end_ns>". Every posted event is a line of <events.jsonl>: {"t": ns, "e": type, "x", "y"}.
import CoreGraphics
import Foundation

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
let src = CGEventSource(stateID: .hidSystemState)
guard CommandLine.arguments.count > 1, let log = FileHandle(forWritingAtPath: {
    FileManager.default.createFile(atPath: CommandLine.arguments[1], contents: nil); return CommandLine.arguments[1] }()) else {
    FileHandle.standardError.write("usage: post <events.jsonl>\n".data(using: .utf8)!); exit(2)
}
var held: CGEventFlags = []
var pos = CGPoint.zero

func flags(_ s: String) -> CGEventFlags {
    var f: CGEventFlags = []
    for p in s.split(separator: ",") {
        switch p { case "ctrl": f.insert(.maskControl); case "opt": f.insert(.maskAlternate); case "shift": f.insert(.maskShift); case "cmd": f.insert(.maskCommand); default: break }
    }
    return f
}
func note(_ e: String, _ p: CGPoint, _ t: UInt64) {
    log.write(String(format: "{\"t\": %llu, \"e\": \"%@\", \"x\": %.2f, \"y\": %.2f}\n", t, e, p.x, p.y).data(using: .utf8)!)
}
func mouse(_ type: CGEventType, _ p: CGPoint, clicks: Int64 = 1) {
    guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
    e.flags = held
    if type == .leftMouseDown || type == .leftMouseUp { e.setIntegerValueField(.mouseEventClickState, value: clicks) }
    let t = now()
    e.post(tap: .cghidEventTap)
    pos = p
    let name: String
    switch type { case .mouseMoved: name = "move"; case .leftMouseDragged: name = "drag"; case .leftMouseDown: name = "down"; case .leftMouseUp: name = "up"; default: name = "?" }
    note(name, p, t)
}
func sleepUntil(_ t: UInt64) { let n = now(); if t > n { usleep(useconds_t((t - n) / 1000)) } }
// minimum jerk: s(u) = 10u^3 - 15u^4 + 6u^5 (zero speed and acceleration at both ends: a hand starting and stopping)
func curve(_ type: CGEventType, _ ms: Double, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint?) {
    let start = now(), n = max(1, Int(ms / 1000 * 120))
    for i in 1...n {
        let u = Double(i) / Double(n), s = u * u * u * (10 - 15 * u + 6 * u * u)
        let p: CGPoint
        if let c { let k = 1 - s; p = CGPoint(x: k * k * a.x + 2 * k * s * c.x + s * s * b.x, y: k * k * a.y + 2 * k * s * c.y + s * s * b.y) }
        else { p = CGPoint(x: a.x + (b.x - a.x) * s, y: a.y + (b.y - a.y) * s) }
        sleepUntil(start + UInt64(Double(i) / 120 * 1e9))
        mouse(type, p)
    }
}

while let line = readLine() {
    let p = line.split(separator: " ").map(String.init)
    guard let cmd = p.first else { continue }
    let d = p.dropFirst().compactMap { Double($0) }
    let t0 = now()
    switch cmd {
    case "key":
        let code = CGKeyCode(UInt16(p[1]) ?? 0), f = p.count > 2 ? flags(p[2]) : []
        let dn = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true); dn?.flags = f.union(held); dn?.post(tap: .cghidEventTap)
        note("key\(code)", pos, now())
        usleep(60_000)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false); up?.flags = f.union(held); up?.post(tap: .cghidEventTap)
    case "keydown", "keyup":
        let code = CGKeyCode(UInt16(p[1]) ?? 0), f = p.count > 2 ? flags(p[2]) : []
        let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: cmd == "keydown"); e?.flags = f.union(held); e?.post(tap: .cghidEventTap)
        note("\(cmd)\(code)", pos, now())
    case "mods":
        held = p.count > 1 && p[1] != "none" ? flags(p[1]) : []
        let e = CGEvent(source: src); e?.type = .flagsChanged; e?.flags = held; e?.post(tap: .cghidEventTap)
        note("mods\(held.rawValue)", pos, now())
    case "move" where d.count >= 2: mouse(.mouseMoved, CGPoint(x: d[0], y: d[1]))
    case "path" where d.count >= 5, "drag" where d.count >= 5:
        let c = d.count >= 7 ? CGPoint(x: d[5], y: d[6]) : nil
        curve(cmd == "path" ? .mouseMoved : .leftMouseDragged, d[0], CGPoint(x: d[1], y: d[2]), CGPoint(x: d[3], y: d[4]), c)
    case "down" where d.count >= 2: mouse(.leftMouseDown, CGPoint(x: d[0], y: d[1]))
    case "up" where d.count >= 2: mouse(.leftMouseUp, CGPoint(x: d[0], y: d[1]))
    case "click" where d.count >= 2:
        let q = CGPoint(x: d[0], y: d[1]); mouse(.leftMouseDown, q); usleep(70_000); mouse(.leftMouseUp, q)
    case "dclick" where d.count >= 2:
        let q = CGPoint(x: d[0], y: d[1])
        mouse(.leftMouseDown, q, clicks: 1); usleep(60_000); mouse(.leftMouseUp, q, clicks: 1); usleep(110_000)
        mouse(.leftMouseDown, q, clicks: 2); usleep(60_000); mouse(.leftMouseUp, q, clicks: 2)
    case "quit": exit(0)
    default: print("bad \(line)"); fflush(stdout); continue
    }
    print("\(cmd) \(t0) \(now())"); fflush(stdout)
}
