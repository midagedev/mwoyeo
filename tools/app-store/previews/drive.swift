// The hand of a preview take: scripted input on the real screen, so a take can be repeated exactly (docs/HERO.md does the same
// by hand). It also watches the take: someone touching the Mac, or a window of another app over the recorded rect, spoils it.
//
//   drive idle                                   seconds since the last HID input
//   drive window pid title secs                  waits for a window of pid whose title starts with title; prints when (epoch s)
//   drive clear  x,y,w,h  pid...                 exit 4 if a window of a process not listed overlaps the rect (global points)
//   drive run    x,y,w,h  pid...  -- step...     a timeline; each step is "t op args" (t: seconds from the start):
//       warp x y                  the pointer to (x, y)
//       point x y secs            the pointer to (x, y) over secs, like a hand would (ease in-out)
//       drag x y dx dy secs [dx dy secs]...   press at (x, y), move by (dx, dy) over secs (ease in-out), then each next
//                                 leg from there, without letting go; release
//       swipe x y dy secs         a two-finger trackpad swipe at (x, y): dy points of scroll (+ shows what is above)
//       click x y                 one click (bring a window to the front by its title bar)
//       key ctrl+opt+o            a key chord (ctrl, opt, cmd, shift; one letter)
//       end                       stop watching (the last step)
//     DRIVE_T0=<epoch seconds> sets t = 0 (default: now), so a timeline can follow a clock outside, such as the page's.
//     prints one line per step (planned and actual time) and exits 3 when HID input came that was not ours (the Mac was
//     touched), 4 when another app's window overlapped the rect, 0 otherwise.
// Build: swiftc -O drive.swift -o drive. Needs the Bash sandbox off, and the terminal's Accessibility permission to post events.
import AppKit
import CoreGraphics
import IOKit

func idleSeconds() -> Double {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    defer { IOObjectRelease(service) }
    guard let v = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
    else { return -1 }
    return v.doubleValue / 1e9
}

func rect(_ s: String) -> CGRect {
    let v = s.split(separator: ",").compactMap { Double($0) }
    guard v.count == 4 else { fatalError("rect is x,y,w,h: \(s)") }
    return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
}

/// Windows of other processes in front of ours that overlap `r` and can be seen (alpha > 0), as "owner pid [name] bounds".
/// The list runs front to back: what is behind a window of ours that covers `r` (the page) cannot be seen. The Dock's
/// window spans the screen but draws only at the bottom edge, below the rect.
func intruders(_ r: CGRect, allowed: Set<Int>) -> [String] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    var out: [String] = []
    for w in list {
        let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
        let name = w[kCGWindowName as String] as? String ?? ""
        guard let bd = w[kCGWindowBounds as String] as? [String: Double] else { continue }
        let b = CGRect(x: bd["X"] ?? 0, y: bd["Y"] ?? 0, width: bd["Width"] ?? 0, height: bd["Height"] ?? 0)
        if allowed.contains(pid) && b.contains(r) && (w[kCGWindowLayer as String] as? Int ?? 0) == 0 { break }
        if allowed.contains(pid) || owner == "Window Server" || owner == "Dock" || alpha == 0 || !b.intersects(r) { continue }
        out.append("\(owner) \(pid) [\(name)] \(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height))")
    }
    return out
}

let source = CGEventSource(stateID: .hidSystemState)
var lastPost = Date.distantPast
/// Every event carries its modifiers explicitly (none, unless a key chord's): an event made from the HID state source
/// otherwise inherits the modifiers that source last saw, and a drag with Option held is one macOS tiles.
func post(_ e: CGEvent?, flags: CGEventFlags = []) {
    e?.flags = flags
    e?.post(tap: .cghidEventTap)
    lastPost = Date()
}

func move(_ p: CGPoint) {
    post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
}

/// 0…1 → 0…1, slow at both ends.
func ease(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }

let hz = 60.0

/// Calls `at` with 0…1 (eased) about 60 times a second for `secs` of wall time, ending at exactly 1: a move takes the time
/// asked for, however long each event takes to post.
func animate(_ secs: Double, _ at: (Double) -> Void) {
    let start = Date()
    while true {
        let x = min(1, Date().timeIntervalSince(start) / max(secs, 0.001))
        at(ease(x))
        if x >= 1 { return }
        usleep(UInt32(1e6 / hz))
    }
}

func point(to p: CGPoint, secs: Double) {
    let from = CGEvent(source: nil)?.location ?? p
    animate(secs) { f in move(CGPoint(x: from.x + (p.x - from.x) * f, y: from.y + (p.y - from.y) * f)) }
}

/// Press at `p`, move through each leg (offset from the leg's start, seconds) without letting go, release.
func drag(from p: CGPoint, legs: [(CGVector, Double)]) {
    move(p)
    usleep(100_000)
    post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left))
    usleep(100_000)
    var at = p
    for (d, secs) in legs {
        let from = at
        animate(secs) { f in
            at = CGPoint(x: from.x + d.dx * f, y: from.y + d.dy * f)
            post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: at, mouseButton: .left))
        }
    }
    usleep(80_000)
    post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: at, mouseButton: .left))
}

/// A trackpad swipe: continuous (pixel) scroll events with the gesture's phases, the speed rising and falling like a finger's.
func swipe(at p: CGPoint, dy: Double, secs: Double) {
    move(p)
    usleep(80_000)
    var sent = 0.0
    var first = true
    animate(secs) { f in
        let step = (dy * f - sent).rounded()
        sent += step
        let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: Int32(step), wheel2: 0, wheel3: 0)
        e?.location = p
        e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e?.setIntegerValueField(.scrollWheelEventScrollPhase, value: first ? 1 : 2)   // began, changed
        first = false
        post(e)
    }
    let end = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0)
    end?.location = p
    end?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    end?.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)                  // ended
    post(end)
}

let modifierKeys: [(String, CGKeyCode, CGEventFlags)] = [("ctrl", 59, .maskControl), ("opt", 58, .maskAlternate),
                                                          ("cmd", 55, .maskCommand), ("shift", 56, .maskShift)]

/// One modifier key going down or up (a flagsChanged event, as a keyboard sends), with the modifiers held after it.
func modifier(_ code: CGKeyCode, holding flags: CGEventFlags) {
    let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    e?.type = .flagsChanged
    post(e, flags: flags)
    usleep(20_000)
}

/// A chord as a hand plays it: the modifiers down one by one, the key down and up, the modifiers up in reverse. A key
/// event's flags alone do not release a modifier: without the flagsChanged ups, the HID state keeps them held.
func key(_ chord: String) {
    var held: [(CGKeyCode, CGEventFlags)] = []
    var code: CGKeyCode?
    let codes: [String: CGKeyCode] = ["o": 0x1F, "a": 0x00, "s": 0x01, "t": 0x11, "r": 0x0F]
    for part in chord.lowercased().split(separator: "+").map(String.init) {
        if let m = modifierKeys.first(where: { $0.0 == part || (part == "alt" && $0.0 == "opt") }) {
            held.append((m.1, m.2))
        } else {
            code = codes[part]
        }
    }
    guard let code else { fatalError("unknown key in \(chord)") }
    var flags: CGEventFlags = []
    for (c, f) in held { flags.insert(f); modifier(c, holding: flags) }
    post(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true), flags: flags)
    usleep(60_000)
    post(CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false), flags: flags)
    for (c, f) in held.reversed() { flags.remove(f); modifier(c, holding: flags) }
}

/// Modifiers the HID state still holds after a run (none, unless something went wrong): released, and named.
func releaseHeldModifiers() -> [String] {
    let state = CGEventSource.flagsState(.hidSystemState)
    var released: [String] = []
    var flags = state.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
    for (name, c, f) in modifierKeys where flags.contains(f) {
        flags.remove(f)
        modifier(c, holding: flags)
        released.append(name)
    }
    return released
}

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "idle":
    print(String(format: "%.1f", idleSeconds()))
case "window":
    let pid = Int(args[1]) ?? 0
    let end = Date().addingTimeInterval(Double(args[3]) ?? 20)
    while Date() < end {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        if list.contains(where: { ($0[kCGWindowOwnerPID as String] as? Int) == pid && ($0[kCGWindowName as String] as? String ?? "").hasPrefix(args[2]) }) {
            print(String(format: "%.3f", Date().timeIntervalSince1970))
            exit(0)
        }
        usleep(20_000)
    }
    exit(1)
case "clear":
    let r = rect(args[1])
    let found = intruders(r, allowed: Set(args.dropFirst(2).compactMap { Int($0) }))
    found.forEach { print("intruder", $0) }
    exit(found.isEmpty ? 0 : 4)
case "run":
    let r = rect(args[1])
    guard let sep = args.firstIndex(of: "--") else { fatalError("run x,y,w,h pid... -- step...") }
    let allowed = Set(args[2..<sep].compactMap { Int($0) })
    let steps = args[(sep + 1)...].map { $0.split(separator: " ").map(String.init) }
    let start = ProcessInfo.processInfo.environment["DRIVE_T0"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? Date()
    var touched: String?
    var intruder: String?
    // The watch: HID idle time falls back to ~0 on any input; ours is excused for a moment after each post.
    let watch = Thread {
        var prev = idleSeconds()
        while true {
            usleep(100_000)
            let now = idleSeconds()
            let ours = Date().timeIntervalSince(lastPost) < 0.6
            if now + 0.05 < prev && !ours && touched == nil {
                touched = String(format: "%.2f s (idle %.2f -> %.2f)", Date().timeIntervalSince(start), prev, now)
            }
            prev = now
            if intruder == nil, let w = intruders(r, allowed: allowed).first {
                intruder = String(format: "%.2f s: ", Date().timeIntervalSince(start)) + w
            }
        }
    }
    watch.start()
    for s in steps {
        guard let t = Double(s[0]) else { fatalError("bad step \(s)") }
        while Date().timeIntervalSince(start) < t && touched == nil && intruder == nil { usleep(20_000) }
        if touched != nil || intruder != nil { break }
        let at = Date().timeIntervalSince(start)
        let n = s.dropFirst(2).compactMap { Double($0) }
        switch s[1] {
        case "warp": move(CGPoint(x: n[0], y: n[1]))
        case "point": point(to: CGPoint(x: n[0], y: n[1]), secs: n[2])
        case "drag":
            let legs = stride(from: 2, to: n.count - 2, by: 3).map { (CGVector(dx: n[$0], dy: n[$0 + 1]), n[$0 + 2]) }
            drag(from: CGPoint(x: n[0], y: n[1]), legs: legs)
        case "swipe": swipe(at: CGPoint(x: n[0], y: n[1]), dy: n[2], secs: n[3])
        case "click":
            let p = CGPoint(x: n[0], y: n[1])
            move(p)
            usleep(80_000)
            post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left))
            usleep(60_000)
            post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
        case "key": key(s[2])
        case "end": break
        default: fatalError("unknown op \(s[1])")
        }
        print(String(format: "step %6.2f  at %6.2f  done %6.2f  ", t, at, Date().timeIntervalSince(start)) + s[1...].joined(separator: " "))
        if touched != nil || intruder != nil { break }
    }
    let stuck = releaseHeldModifiers()
    if !stuck.isEmpty { print("released held modifiers:", stuck.joined(separator: " ")) }
    // When our last event was: the next take's idle check excuses the input that was ours (DRIVE_STAMP names the file).
    if let stamp = ProcessInfo.processInfo.environment["DRIVE_STAMP"], lastPost != .distantPast {
        try? String(format: "%.3f", lastPost.timeIntervalSince1970).write(toFile: stamp, atomically: true, encoding: .utf8)
    }
    if let touched { print("touched", touched); exit(3) }
    if let intruder { print("intruder", intruder); exit(4) }
    print("clean")
default:
    print("usage: drive idle | clear x,y,w,h pid... | run x,y,w,h pid... -- \"t op args\"...")
    exit(2)
}
