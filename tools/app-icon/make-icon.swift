// Renders the app icon from code: App/AppIcon.icon (Icon Composer layers + icon.json, which Xcode compiles into
// Assets.car for macOS 26+) and the AppIcon.appiconset PNGs, flattened from the same layers by ictool.
//   swift tools/app-icon/make-icon.swift [--icon <dir.icon>] [--appiconset <dir>] [--preview <dir>]
// The motif is the brand's: a spectrum lens over lines of text, the lines bright inside the lens and faint outside.
// Geometry is in points on the 1024 pt Icon Composer canvas, which macOS masks to its rounded square (at 1024 px the
// shape is 824 px with a 100 px margin; at 16 px it is 14 px). Brand colours are Brand.spectrum / LensTint.spectrum.
import AppKit
import CoreImage

let args = CommandLine.arguments
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
let iconDir = URL(fileURLWithPath: option("--icon") ?? "App/AppIcon.icon", isDirectory: true)
let setDir = URL(fileURLWithPath: option("--appiconset") ?? "App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let preview = option("--preview").map { URL(fileURLWithPath: $0, isDirectory: true) }
let ictool = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

let S: CGFloat = 1024
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
/// LensTint.spectrum, once round: orange, pink, purple, indigo, cyan.
let spectrum = [rgb(1.00, 0.62, 0.04), rgb(1.00, 0.22, 0.37), rgb(0.75, 0.35, 0.95), rgb(0.37, 0.36, 0.90), rgb(0.39, 0.82, 1.00),
                rgb(1.00, 0.62, 0.04)]

// Layout, y up. The lens spans 72 % of the canvas; the bright lines sit on a 128 pt pitch that the faint lines continue.
let lens = CGRect(x: 144, y: 238, width: 736, height: 548)
let lensRadius: CGFloat = 132
let ringWidth: CGFloat = 44
/// The lens magnifies: text under it is drawn bolder than the faint text around it.
let lineHeight: CGFloat = 64, faintHeight: CGFloat = 44
let rows: [CGFloat] = [640, 512, 384]
let bright: [(x0: CGFloat, x1: CGFloat)] = [(256, 768), (256, 712), (256, 560)]
/// Faint text: the rows under the lens run past it on both sides, one more row above and below.
let faint: [(y: CGFloat, x0: CGFloat, x1: CGFloat)] = [(896, 112, 700), (640, 40, 984), (512, 40, 930), (384, 40, 984),
                                                        (128, 112, 800)]

func canvas() -> CGContext {
    CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func capsule(_ y: CGFloat, _ x0: CGFloat, _ x1: CGFloat, _ h: CGFloat = lineHeight) -> CGPath {
    CGPath(roundedRect: CGRect(x: x0, y: y - h / 2, width: x1 - x0, height: h), cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
}
let lensPath = CGPath(roundedRect: lens, cornerWidth: lensRadius, cornerHeight: lensRadius, transform: nil)

/// Fills the current clip with the spectrum swept around the lens centre (a conic gradient, in thin wedges), starting
/// at 45° as LensRing does at rest. The wedges overlap without antialiasing (antialiased seams show as fine spokes);
/// the clip's edge is still antialiased.
func sweepSpectrum(_ ctx: CGContext) {
    ctx.setShouldAntialias(false)
    defer { ctx.setShouldAntialias(true) }
    let c = CGPoint(x: lens.midX, y: lens.midY), n = 1440
    for i in 0..<n {
        let t = CGFloat(i) / CGFloat(n)
        let seg = t * CGFloat(spectrum.count - 1), k = min(Int(seg), spectrum.count - 2), f = seg - CGFloat(k)
        let a = spectrum[k].components!, b = spectrum[k + 1].components!
        ctx.setFillColor(rgb(a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f))
        let a0 = t * 2 * .pi + .pi / 4, a1 = a0 + 2 * .pi / CGFloat(n) * 1.5
        ctx.move(to: c)
        ctx.addLine(to: CGPoint(x: c.x + 1200 * cos(a0), y: c.y + 1200 * sin(a0)))
        ctx.addLine(to: CGPoint(x: c.x + 1200 * cos(a1), y: c.y + 1200 * sin(a1)))
        ctx.closePath(); ctx.fillPath()
    }
}

func ring(width: CGFloat) -> CGImage {
    let ctx = canvas()
    ctx.addPath(lensPath); ctx.setLineWidth(width); ctx.replacePathWithStrokedPath(); ctx.clip()
    sweepSpectrum(ctx)
    return ctx.makeImage()!
}

func layer(_ draw: (CGContext) -> Void) -> CGImage {
    let ctx = canvas()
    draw(ctx)
    return ctx.makeImage()!
}

// The layers, back to front.
let layers: [(name: String, image: CGImage)] = [
    ("text-faint", layer { ctx in
        ctx.setFillColor(rgb(1, 1, 1, 0.14))
        for l in faint { ctx.addPath(capsule(l.y, l.x0, l.x1, faintHeight)) }
        ctx.fillPath()
    }),
    ("glow", layer { ctx in
        let blurred = CIImage(cgImage: ring(width: ringWidth * 2)).applyingGaussianBlur(sigma: 34)
            .cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
        ctx.setAlpha(0.75)
        ctx.draw(CIContext().createCGImage(blurred, from: CGRect(x: 0, y: 0, width: S, height: S))!, in: CGRect(x: 0, y: 0, width: S, height: S))
    }),
    ("lens", layer { ctx in
        ctx.addPath(lensPath); ctx.setFillColor(rgb(0.06, 0.06, 0.075, 0.92)); ctx.fillPath()
    }),
    ("ring", ring(width: ringWidth)),
    ("text-bright", layer { ctx in
        ctx.setFillColor(rgb(1, 1, 1, 1))
        for (y, l) in zip(rows, bright) { ctx.addPath(capsule(y, l.x0, l.x1)) }
        ctx.fillPath()
    }),
]

func writePNG(_ image: CGImage, _ url: URL) throws {
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: url)
}

// icon.json: the schema Icon Composer writes (keys checked against IconComposerFoundation and Xcode-built .icon files).
// Four groups at most, front first. Background: the graphite of the old icon and AppGlyph, lit from the top. The ring is
// the one glass layer: the system lights its edges (the lens's glass rim) and keeps its spectrum within ~8 % of the
// brand colours; a glass lens panel instead would draw a second rim inside the ring.
let iconJSON = """
{
  "fill" : {
    "linear-gradient" : [
      "srgb:0.20000,0.20784,0.24706,1.00000",
      "srgb:0.05490,0.05490,0.07059,1.00000"
    ],
    "orientation" : {
      "start" : { "x" : 0.5, "y" : 0 },
      "stop" : { "x" : 0.5, "y" : 1 }
    }
  },
  "groups" : [
    {
      "layers" : [
        { "image-name" : "text-bright.png", "name" : "text-bright", "glass" : false }
      ],
      "name" : "Read",
      "shadow" : { "kind" : "neutral", "opacity" : 0.35 },
      "specular" : false,
      "translucency" : { "enabled" : false, "value" : 0.5 }
    },
    {
      "layers" : [
        { "image-name" : "ring.png", "name" : "ring", "glass" : true },
        { "image-name" : "lens.png", "name" : "lens", "glass" : false }
      ],
      "name" : "Lens",
      "shadow" : { "kind" : "layer-color", "opacity" : 0.5 },
      "specular" : true,
      "translucency" : { "enabled" : false, "value" : 0.5 }
    },
    {
      "layers" : [
        { "image-name" : "glow.png", "name" : "glow", "glass" : false, "blend-mode" : "plus-lighter" }
      ],
      "name" : "Glow",
      "shadow" : { "kind" : "none", "opacity" : 0 },
      "specular" : false,
      "translucency" : { "enabled" : false, "value" : 0.5 }
    },
    {
      "layers" : [
        { "image-name" : "text-faint.png", "name" : "text-faint", "glass" : false }
      ],
      "name" : "Page",
      "shadow" : { "kind" : "none", "opacity" : 0 },
      "specular" : false,
      "translucency" : { "enabled" : false, "value" : 0.5 }
    }
  ],
  "supported-platforms" : {
    "squares" : [ "macOS" ]
  }
}

"""

let fm = FileManager.default
try? fm.removeItem(at: iconDir)
try fm.createDirectory(at: iconDir.appendingPathComponent("Assets"), withIntermediateDirectories: true)
for l in layers { try writePNG(l.image, iconDir.appendingPathComponent("Assets/\(l.name).png")) }
try iconJSON.write(to: iconDir.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("wrote \(iconDir.path)")

/// ictool's flattening of the .icon, as macOS draws it (shape, margin, shadow), at px × px.
func export(_ rendition: String, _ px: Int, to url: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ictool)
    p.arguments = [iconDir.path, "--export-image", "--output-file", url.path, "--platform", "macOS", "--rendition", rendition,
                   "--width", "\(px)", "--height", "\(px)", "--scale", "1"]
    p.standardOutput = FileHandle.nullDevice // an empty JSON object per call
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0, fm.fileExists(atPath: url.path) else {
        throw NSError(domain: "ictool", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "ictool \(rendition) \(px) failed"])
    }
}

/// The shape's side at px, as macOS 26+ draws an app icon (tools/app-icon/system-icon.swift measured 14 of 16, 26 of 32,
/// 52 of 64, 824 of 1024). An appiconset image whose shape is smaller is put in a grey plate: the old 16 px one was.
func body(_ px: Int) -> Int { px <= 16 ? px - 2 : px <= 32 ? px - 6 : px <= 64 ? px - 12 : Int((CGFloat(px) * 824 / 1024).rounded()) }

// The appiconset, flattened from the .icon by ictool onto the classic grid with its drop shadow, so the two agree. With
// AppIcon.icon in the target actool compiles the .icon and does not read this set (measured: the 26+ deployment target
// never needs it); it stays for anything that looks for PNGs.
let tmp = fm.temporaryDirectory.appendingPathComponent("make-icon-\(getpid())", isDirectory: true)
try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmp) }
var images: [[String: String]] = []
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let px = pt * scale, side = body(px), name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    let flat = tmp.appendingPathComponent("\(side).png")
    try export("Default", side, to: flat)
    let art = NSImage(contentsOf: flat)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(px) / 1024, o = CGFloat(px - side) / 2
    if px >= 128 { ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 30 * k, color: rgb(0, 0, 0, 0.3)) }
    ctx.draw(art, in: CGRect(x: o, y: o, width: CGFloat(side), height: CGFloat(side)))
    try writePNG(ctx.makeImage()!, setDir.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: setDir.appendingPathComponent("Contents.json"))
print("wrote \(setDir.path)")

if let preview {
    try fm.createDirectory(at: preview, withIntermediateDirectories: true)
    for r in ["Default", "Dark", "ClearLight", "ClearDark", "TintedLight", "TintedDark"] {
        for px in [1024, 256, 64, 32, 16] { try export(r, px, to: preview.appendingPathComponent("\(r)-\(px).png")) }
    }
    print("wrote \(preview.path)")
}
