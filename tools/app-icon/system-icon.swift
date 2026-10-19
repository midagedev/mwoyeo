// Draws an app's icon as macOS draws it (NSWorkspace, the path Finder and the Dock use) and prints numbers that say
// whether the system put the art in a plate ("icon jail", macOS 26+), where the art sits and how its corners are cut.
//   swift tools/app-icon/system-icon.swift <App.app> <out-dir> [--ref <1024 png>] [--tag <name>]
// Writes <out-dir>/<tag>-system-<appearance>-<px>.png (and <tag>-ref-<px>.png). A plate shows as an edge colour that is
// not the reference's own edge colour: --ref is the artwork the app ships (the appiconset 1024, or the .icon's Default
// rendition from ictool). Copy the .app to a fresh path before measuring a rebuilt icon: Icon Services caches by path.
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: system-icon.swift <App.app> <out-dir> [--ref <png>] [--tag <name>]\n".data(using: .utf8)!)
    exit(2)
}
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let app = args[1], out = URL(fileURLWithPath: args[2], isDirectory: true), tag = option("--tag") ?? "icon"
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let sizes = [1024, 256, 64, 32, 16]
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// RGBA, straight (not premultiplied) alpha, row 0 at the top.
struct Pixels {
    let n: Int
    var p: [UInt8]
    func at(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        let i = (min(max(y, 0), n - 1) * n + min(max(x, 0), n - 1)) * 4
        let a = Double(p[i + 3])
        guard a > 0 else { return (0, 0, 0, 0) }
        return (Double(p[i]) * 255 / a, Double(p[i + 1]) * 255 / a, Double(p[i + 2]) * 255 / a, a)
    }
}

func draw(_ n: Int, _ body: (CGContext) -> Void) -> (CGImage, Pixels) {
    let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    body(ctx)
    let image = ctx.makeImage()!
    let buffer = UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: n * n * 4)
    return (image, Pixels(n: n, p: Array(buffer)))
}

func save(_ image: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}

/// The system's icon for the bundle, drawn at n px under the given appearance.
func systemIcon(_ n: Int, _ appearance: NSAppearance) -> (CGImage, Pixels) {
    let icon = NSWorkspace.shared.icon(forFile: app)
    icon.size = NSSize(width: n, height: n)
    return draw(n) { ctx in
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        appearance.performAsCurrentDrawingAppearance {
            icon.draw(in: NSRect(x: 0, y: 0, width: n, height: n), from: .zero, operation: .copy, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

func reference(_ n: Int) -> (CGImage, Pixels)? {
    guard let path = option("--ref"), let src = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return nil }
    return draw(n) { $0.draw(src, in: CGRect(x: 0, y: 0, width: n, height: n)) }
}

struct Facts {
    var box = (x0: 0, y0: 0, x1: -1, y1: -1)
    var corners: [[Int]] = []      // per corner (TL TR BL BR), alpha at 2 %, 5 %, 8 % of the box width along the diagonal
    var edge = (r: 0.0, g: 0.0, b: 0.0)
    var art = (x0: 0, y0: 0, x1: -1, y1: -1)
}

func measure(_ px: Pixels) -> Facts {
    let n = px.n
    var f = Facts()
    f.box = (n, n, -1, -1)
    for y in 0..<n { for x in 0..<n where px.p[(y * n + x) * 4 + 3] >= 128 {
        f.box = (min(f.box.x0, x), min(f.box.y0, y), max(f.box.x1, x), max(f.box.y1, y))
    } }
    guard f.box.x1 >= f.box.x0 else { return f }
    let w = Double(f.box.x1 - f.box.x0 + 1), h = Double(f.box.y1 - f.box.y0 + 1)
    let origins = [(f.box.x0, f.box.y0, 1, 1), (f.box.x1, f.box.y0, -1, 1), (f.box.x0, f.box.y1, 1, -1), (f.box.x1, f.box.y1, -1, -1)]
    f.corners = origins.map { o in [0.02, 0.05, 0.08].map { d in
        Int(px.at(o.0 + o.2 * Int((d * w).rounded()), o.1 + o.3 * Int((d * w).rounded())).a)
    } }
    // Edge band: 1.5–3.5 % inside the shape, over the middle 40 % of each side. A plate is a band unlike the art's own.
    var sum = (0.0, 0.0, 0.0), count = 0.0
    let lo = 0.015, hi = 0.035
    for t in stride(from: 0.3, through: 0.7, by: 0.4 / 24) {
        for d in stride(from: lo, through: hi, by: (hi - lo) / 4) {
            let xs = [f.box.x0 + Int(d * w), f.box.x1 - Int(d * w)], ys = [f.box.y0 + Int(d * h), f.box.y1 - Int(d * h)]
            let mx = f.box.x0 + Int(t * w), my = f.box.y0 + Int(t * h)
            for (x, y) in [(xs[0], my), (xs[1], my), (mx, ys[0]), (mx, ys[1])] {
                let c = px.at(x, y)
                guard c.a >= 128 else { continue }
                sum = (sum.0 + c.r, sum.1 + c.g, sum.2 + c.b); count += 1
            }
        }
    }
    f.edge = count > 0 ? (sum.0 / count, sum.1 / count, sum.2 / count) : (0, 0, 0)
    // Art: what differs from the edge colour, inside the shape less its rim (a plate's lit rim is not art).
    f.art = (n, n, -1, -1)
    let rim = Int((0.04 * w).rounded(.up))
    for y in (f.box.y0 + rim)...(f.box.y1 - rim) { for x in (f.box.x0 + rim)...(f.box.x1 - rim) {
        let c = px.at(x, y)
        guard c.a >= 128 else { continue }
        let d = abs(c.r - f.edge.r) + abs(c.g - f.edge.g) + abs(c.b - f.edge.b)
        if d > 60 { f.art = (min(f.art.x0, x), min(f.art.y0, y), max(f.art.x1, x), max(f.art.y1, y)) }
    } }
    return f
}

func fmtBox(_ b: (x0: Int, y0: Int, x1: Int, y1: Int), _ n: Int) -> String {
    guard b.x1 >= b.x0 else { return "none" }
    let w = b.x1 - b.x0 + 1, h = b.y1 - b.y0 + 1
    return String(format: "x%d y%d w%d h%d (%.3f of canvas)", b.x0, b.y0, w, h, Double(w) / Double(n))
}
func fmtColor(_ c: (r: Double, g: Double, b: Double)) -> String { String(format: "rgb(%.0f,%.0f,%.0f)", c.r, c.g, c.b) }
func distance(_ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)) -> Double {
    ((a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g) + (a.b - b.b) * (a.b - b.b)).squareRoot()
}

print("system-icon \(tag): \(app)")
// The art's own edge colour, from the 1024 reference: at 32 and 16 px the band is a pixel or less and catches the rim
// the reference draws, which would read as a plate.
let artEdge = reference(1024).map { measure($0.1).edge }
var plates: [String] = []
for n in sizes {
    let ref = reference(n)
    if let ref { save(ref.0, "\(tag)-ref-\(n).png") }
    let refFacts = ref.map { measure($0.1) }
    if let r = refFacts {
        print(String(format: "  %4d ref     shape %@  corners TL%@ TR%@ BL%@ BR%@  edge %@", n, fmtBox(r.box, n),
                     "\(r.corners[0])", "\(r.corners[1])", "\(r.corners[2])", "\(r.corners[3])", fmtColor(r.edge)))
    }
    // The drawing appearance is passed on, but the Dock's icon style (Default, Dark, Clear, Tinted) is a system setting
    // Icon Services applies on its own: render the .icon's other renditions with ictool (make-icon.swift does).
    for (label, appearance) in [("aqua", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)] {
        let sys = systemIcon(n, appearance)
        save(sys.0, "\(tag)-system-\(label)-\(n).png")
        let f = measure(sys.1)
        var line = String(format: "  %4d %@ shape %@  corners TL%@ TR%@ BL%@ BR%@  edge %@  art %@", n,
                          label.padding(toLength: 6, withPad: " ", startingAt: 0),
                          fmtBox(f.box, n), "\(f.corners.first ?? [])", "\(f.corners.dropFirst().first ?? [])",
                          "\(f.corners.dropFirst(2).first ?? [])", "\(f.corners.dropFirst(3).first ?? [])", fmtColor(f.edge),
                          fmtBox(f.art, n))
        if let artEdge {
            let d = distance(f.edge, artEdge)
            let plate = d > 40
            line += String(format: "  edge-vs-ref %.0f  plate %@", d, plate ? "YES" : "no")
            plates.append(plate ? "YES" : "no")
        }
        print(line)
    }
}
if !plates.isEmpty {
    print("verdict \(tag): plate \(plates.contains("YES") ? "YES" : "no") (\(plates.filter { $0 == "YES" }.count) of \(plates.count) renders; edge vs the reference's 1024 edge \(fmtColor(artEdge!)))")
}
