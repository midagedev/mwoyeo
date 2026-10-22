import AppKit

// usage: caption pill <out.png> <kr> <en>            a caption: a dark scrim pill with the Korean line (Apple SD Gothic Neo SemiBold 44 px, white) over the
//                                                    English subline (SF Pro Text 26 px, white at 72 %); the PNG is as big as its text, transparent around it
//        caption card <out.png> <kr> <en> <tag>      the end card, 1920 x 1080: flat #05070f, <kr> centred (SD Gothic Neo SemiBold 56 px, white), <en> under it (SF Pro Text 30 px,
//                                                    white at 72 %), <tag> under that (SF Pro Display Semibold 34 px, white at 72 %)
// Both print the size of the text block in pixels: `pill WxH` / `card text WxH`, so a caption that does not fit its slot is reported by numbers, not reworded.
// The words are the lead's (never written here). Pixels are output pixels (1920 x 1080 canvas), drawn at scale 1.
let args = CommandLine.arguments
guard args.count >= 5, args[1] != "card" || args.count >= 6 else { FileHandle.standardError.write(Data("usage: caption pill <out.png> <kr> <en> | card <out.png> <kr> <en> <tag>\n".utf8)); exit(2) }

func font(_ names: [String], _ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    for n in names { if let f = NSFont(name: n, size: size) { return f } }
    return NSFont.systemFont(ofSize: size, weight: weight)
}
let kr = font(["AppleSDGothicNeo-SemiBold"], 44, .semibold)
let enFont = NSFont.systemFont(ofSize: 26, weight: .regular)
func attributed(_ s: String, _ f: NSFont, _ alpha: CGFloat) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: NSColor(white: 1, alpha: alpha)])
}
func png(_ size: NSSize, _ draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

switch args[1] {
case "pill":
    let a = attributed(args[3], kr, 1), b = attributed(args[4], enFont, 0.72)
    let sa = a.size(), sb = b.size()
    let padX: CGFloat = 30, padY: CGFloat = 20, gap: CGFloat = 6
    let size = NSSize(width: ceil(max(sa.width, sb.width) + 2 * padX), height: ceil(sa.height + gap + sb.height + 2 * padY))
    let data = png(size) {
        NSColor(red: 5 / 255, green: 7 / 255, blue: 15 / 255, alpha: 0.58).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 16, yRadius: 16).fill()
        b.draw(at: NSPoint(x: padX, y: padY))
        a.draw(at: NSPoint(x: padX, y: padY + sb.height + gap))
    }
    try data.write(to: URL(fileURLWithPath: args[2]))
    print("pill \(Int(size.width))x\(Int(size.height))")
case "card":
    let a = attributed(args[3], font(["AppleSDGothicNeo-SemiBold"], 56, .semibold), 1)
    let b = attributed(args[4], NSFont.systemFont(ofSize: 30, weight: .regular), 0.72)
    let c = attributed(args[5], NSFont.systemFont(ofSize: 34, weight: .semibold), 0.72)
    let size = NSSize(width: 1920, height: 1080)
    let sa = a.size(), sb = b.size(), sc = c.size()
    let data = png(size) {
        NSColor(red: 5 / 255, green: 7 / 255, blue: 15 / 255, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let total = sa.height + 14 + sb.height + 44 + sc.height
        let top = (size.height - total) / 2
        c.draw(at: NSPoint(x: (size.width - sc.width) / 2, y: top))
        b.draw(at: NSPoint(x: (size.width - sb.width) / 2, y: top + sc.height + 44))
        a.draw(at: NSPoint(x: (size.width - sa.width) / 2, y: top + sc.height + 44 + sb.height + 14))
    }
    try data.write(to: URL(fileURLWithPath: args[2]))
    print("card text \(Int(ceil(max(sa.width, sb.width, sc.width))))x\(Int(ceil(sa.height + 14 + sb.height + 44 + sc.height)))")
default:
    FileHandle.standardError.write(Data("caption: pill or card\n".utf8)); exit(2)
}
