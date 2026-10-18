import CoreGraphics
import Foundation

// usage: pdfglyphs <pdf> <page>...        (pages 1-based; none = all)
// One JSON line per glyph shown on the page, in content-stream order, form XObjects (figures) included:
//   {"p":page,"x":origin x,"y":baseline y (page points, y up),"w":advance,"s":size,"f":font without subset tag,"c":char code,"u":unicode}
// plus "d":depth when the glyph is inside a form XObject (a figure included as a PDF), which page text never is in pdfTeX output.
// PDFKit's attributed string names every font "Helvetica", so the fonts come from the content stream itself: Tf with the font
// dictionary's BaseFont, Widths and ToUnicode. Simple (one-byte) fonts only, which is what pdfTeX writes; a composite font is
// counted on stderr and its glyphs are written with width 0.

final class FontInfo {
    var name = ""
    var first = 0
    var widths: [Double] = []
    var missing = 0.0
    var composite = false
    var toUnicode: [Int: String] = [:]
}

struct TextState {
    var font: FontInfo?
    var size = 0.0
    var tc = 0.0, tw = 0.0, th = 1.0, tl = 0.0, rise = 0.0
}

final class Tracer {
    var page = 0
    var ctm = CGAffineTransform.identity
    var stack: [CGAffineTransform] = []
    var tm = CGAffineTransform.identity, tlm = CGAffineTransform.identity
    var ts = TextState()
    var tsStack: [TextState] = []
    var cs: CGPDFContentStreamRef
    var fontCache: [UInt: FontInfo] = [:]
    var out = ""
    var composites = 0
    var depth = 0

    init(cs: CGPDFContentStreamRef) { self.cs = cs }

    func font(named name: String) -> FontInfo? {
        guard let obj = CGPDFContentStreamGetResource(cs, "Font", name) else { return nil }
        var dict: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(obj, .dictionary, &dict), let d = dict else { return nil }
        let key = unsafeBitCast(d, to: UInt.self)
        if let f = fontCache[key] { return f }
        let f = FontInfo()
        var n: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(d, "BaseFont", &n), let n { f.name = String(cString: n) }
        if let plus = f.name.firstIndex(of: "+"), f.name.distance(from: f.name.startIndex, to: plus) == 6 { f.name = String(f.name[f.name.index(after: plus)...]) }
        if CGPDFDictionaryGetName(d, "Subtype", &n), let n, String(cString: n) == "Type0" { f.composite = true }
        var fc: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(d, "FirstChar", &fc) { f.first = Int(fc) }
        var arr: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(d, "Widths", &arr), let arr {
            for i in 0..<CGPDFArrayGetCount(arr) {
                var v: CGPDFReal = 0
                f.widths.append(CGPDFArrayGetNumber(arr, i, &v) ? Double(v) : 0)
            }
        }
        var desc: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(d, "FontDescriptor", &desc), let desc {
            var mw: CGPDFReal = 0
            if CGPDFDictionaryGetNumber(desc, "MissingWidth", &mw) { f.missing = Double(mw) }
        }
        var st: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(d, "ToUnicode", &st), let st {
            var fmt = CGPDFDataFormat.raw
            if let data = CGPDFStreamCopyData(st, &fmt) as Data? { f.toUnicode = Tracer.parseCMap(String(decoding: data, as: UTF8.self)) }
        }
        fontCache[key] = f
        return f
    }

    static func parseCMap(_ s: String) -> [Int: String] {
        var map: [Int: String] = [:]
        func uni(_ hex: Substring) -> String {
            var u16: [UInt16] = []
            var i = hex.startIndex
            while hex.distance(from: i, to: hex.endIndex) >= 4 {
                let j = hex.index(i, offsetBy: 4)
                u16.append(UInt16(hex[i..<j], radix: 16) ?? 0xFFFD); i = j
            }
            return String(decoding: u16, as: UTF16.self)
        }
        let lines = s.split(whereSeparator: \.isNewline)
        var mode = 0
        for ln in lines {
            if ln.contains("beginbfchar") { mode = 1; continue }
            if ln.contains("beginbfrange") { mode = 2; continue }
            if ln.contains("endbf") { mode = 0; continue }
            let toks = ln.split(whereSeparator: { $0 == " " || $0 == "<" || $0 == ">" || $0 == "[" || $0 == "]" || $0 == "\t" }).map { $0 }
            if mode == 1, toks.count >= 2, let c = Int(toks[0], radix: 16) { map[c] = uni(toks[1]) }
            if mode == 2, toks.count >= 3, let lo = Int(toks[0], radix: 16), let hi = Int(toks[1], radix: 16), hi >= lo, hi - lo < 4096 {
                if toks.count == 3 {
                    let base = uni(toks[2]); let last = base.unicodeScalars.last.map { Int($0.value) } ?? 0
                    for k in 0...(hi - lo) {
                        var sc = Array(base.unicodeScalars.dropLast())
                        if let u = Unicode.Scalar(UInt32(last + k)) { sc.append(u) }
                        map[lo + k] = String(String.UnicodeScalarView(sc))
                    }
                } else {
                    for (k, t) in toks[2...].enumerated() where lo + k <= hi { map[lo + k] = uni(t) }
                }
            }
        }
        return map
    }

    func show(_ bytes: [UInt8]) {
        guard let f = ts.font else { return }
        for b in bytes {
            let code = Int(b)
            let idx = code - f.first
            let w0 = (!f.composite && idx >= 0 && idx < f.widths.count) ? f.widths[idx] : (f.composite ? 0 : f.missing)
            let trm = CGAffineTransform(a: ts.size * ts.th, b: 0, c: 0, d: ts.size, tx: 0, ty: ts.rise).concatenating(tm).concatenating(ctm)
            let advText = w0 / 1000 * ts.size
            let advDev = advText * ts.th * Double(hypot(trm.a, trm.b)) / max(ts.size * ts.th, 1e-9)
            let sizeDev = Double(hypot(trm.c, trm.d))
            let u = f.toUnicode[code] ?? (code >= 32 && code < 127 ? String(UnicodeScalar(UInt8(code))) : "")
            if f.composite { composites += 1 }
            let esc = u.unicodeScalars.map { sc -> String in
                switch sc {
                case "\"": return "\\\""
                case "\\": return "\\\\"
                default: return sc.value < 32 ? String(format: "\\u%04x", sc.value) : String(sc)
                }
            }.joined()
            out += String(format: "{\"p\":%d,\"x\":%.3f,\"y\":%.3f,\"w\":%.3f,\"s\":%.3f,\"f\":\"%@\",\"c\":%d,\"u\":\"%@\"%@}\n",
                          page, Double(trm.tx), Double(trm.ty), advDev, sizeDev, f.name, code, esc, depth > 0 ? ",\"d\":\(depth)" : "")
            let tx = (advText + ts.tc + (code == 32 ? ts.tw : 0)) * ts.th
            tm = CGAffineTransform(translationX: tx, y: 0).concatenating(tm)
        }
    }

    func adjust(_ n: Double) { tm = CGAffineTransform(translationX: -n / 1000 * ts.size * ts.th, y: 0).concatenating(tm) }
}

func tracer(_ info: UnsafeMutableRawPointer?) -> Tracer { Unmanaged<Tracer>.fromOpaque(info!).takeUnretainedValue() }
func num(_ s: CGPDFScannerRef) -> Double { var v: CGPDFReal = 0; CGPDFScannerPopNumber(s, &v); return Double(v) }
func bytes(_ s: CGPDFScannerRef) -> [UInt8]? {
    var str: CGPDFStringRef?
    guard CGPDFScannerPopString(s, &str), let str, let p = CGPDFStringGetBytePtr(str) else { return nil }
    return Array(UnsafeBufferPointer(start: p, count: CGPDFStringGetLength(str)))
}

func scan(_ cs: CGPDFContentStreamRef, into t: Tracer) {
    let table = CGPDFOperatorTableCreate()!
    CGPDFOperatorTableSetCallback(table, "q") { _, i in let t = tracer(i); t.stack.append(t.ctm); t.tsStack.append(t.ts) }
    CGPDFOperatorTableSetCallback(table, "Q") { _, i in
        let t = tracer(i)
        if let c = t.stack.popLast() { t.ctm = c }
        if let s = t.tsStack.popLast() { t.ts = s }
    }
    CGPDFOperatorTableSetCallback(table, "cm") { s, i in
        let f = num(s), e = num(s), d = num(s), c = num(s), b = num(s), a = num(s)
        let t = tracer(i); t.ctm = CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f).concatenating(t.ctm)
    }
    CGPDFOperatorTableSetCallback(table, "BT") { _, i in let t = tracer(i); t.tm = .identity; t.tlm = .identity }
    CGPDFOperatorTableSetCallback(table, "Tf") { s, i in
        let size = num(s); var n: UnsafePointer<CChar>?
        let t = tracer(i); t.ts.size = size
        if CGPDFScannerPopName(s, &n), let n { t.ts.font = t.font(named: String(cString: n)) }
    }
    CGPDFOperatorTableSetCallback(table, "Tc") { s, i in tracer(i).ts.tc = num(s) }
    CGPDFOperatorTableSetCallback(table, "Tw") { s, i in tracer(i).ts.tw = num(s) }
    CGPDFOperatorTableSetCallback(table, "Tz") { s, i in tracer(i).ts.th = num(s) / 100 }
    CGPDFOperatorTableSetCallback(table, "TL") { s, i in tracer(i).ts.tl = num(s) }
    CGPDFOperatorTableSetCallback(table, "Ts") { s, i in tracer(i).ts.rise = num(s) }
    CGPDFOperatorTableSetCallback(table, "Td") { s, i in
        let ty = num(s), tx = num(s); let t = tracer(i)
        t.tlm = CGAffineTransform(translationX: tx, y: ty).concatenating(t.tlm); t.tm = t.tlm
    }
    CGPDFOperatorTableSetCallback(table, "TD") { s, i in
        let ty = num(s), tx = num(s); let t = tracer(i)
        t.ts.tl = -ty
        t.tlm = CGAffineTransform(translationX: tx, y: ty).concatenating(t.tlm); t.tm = t.tlm
    }
    CGPDFOperatorTableSetCallback(table, "Tm") { s, i in
        let f = num(s), e = num(s), d = num(s), c = num(s), b = num(s), a = num(s)
        let t = tracer(i); t.tlm = CGAffineTransform(a: a, b: b, c: c, d: d, tx: e, ty: f); t.tm = t.tlm
    }
    CGPDFOperatorTableSetCallback(table, "T*") { _, i in
        let t = tracer(i); t.tlm = CGAffineTransform(translationX: 0, y: -t.ts.tl).concatenating(t.tlm); t.tm = t.tlm
    }
    CGPDFOperatorTableSetCallback(table, "Tj") { s, i in if let b = bytes(s) { tracer(i).show(b) } }
    CGPDFOperatorTableSetCallback(table, "'") { s, i in
        let t = tracer(i); t.tlm = CGAffineTransform(translationX: 0, y: -t.ts.tl).concatenating(t.tlm); t.tm = t.tlm
        if let b = bytes(s) { t.show(b) }
    }
    CGPDFOperatorTableSetCallback(table, "\"") { s, i in
        let t = tracer(i)
        let b = bytes(s)
        t.ts.tc = num(s); t.ts.tw = num(s)
        t.tlm = CGAffineTransform(translationX: 0, y: -t.ts.tl).concatenating(t.tlm); t.tm = t.tlm
        if let b { t.show(b) }
    }
    CGPDFOperatorTableSetCallback(table, "TJ") { s, i in
        var arr: CGPDFArrayRef?
        guard CGPDFScannerPopArray(s, &arr), let arr else { return }
        let t = tracer(i)
        for k in 0..<CGPDFArrayGetCount(arr) {
            var str: CGPDFStringRef?; var v: CGPDFReal = 0
            if CGPDFArrayGetString(arr, k, &str), let str, let p = CGPDFStringGetBytePtr(str) {
                t.show(Array(UnsafeBufferPointer(start: p, count: CGPDFStringGetLength(str))))
            } else if CGPDFArrayGetNumber(arr, k, &v) { t.adjust(Double(v)) }
        }
    }
    CGPDFOperatorTableSetCallback(table, "Do") { s, i in
        var n: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(s, &n), let n else { return }
        let t = tracer(i)
        guard t.depth < 6, let obj = CGPDFContentStreamGetResource(t.cs, "XObject", String(cString: n)) else { return }
        var st: CGPDFStreamRef?
        guard CGPDFObjectGetValue(obj, .stream, &st), let st, let d = CGPDFStreamGetDictionary(st) else { return }
        var sub: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(d, "Subtype", &sub), let sub, String(cString: sub) == "Form" else { return }
        var m = CGAffineTransform.identity
        var marr: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(d, "Matrix", &marr), let marr, CGPDFArrayGetCount(marr) == 6 {
            var v = [CGPDFReal](repeating: 0, count: 6)
            for k in 0..<6 { CGPDFArrayGetNumber(marr, k, &v[k]) }
            m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        }
        var res: CGPDFDictionaryRef?
        _ = CGPDFDictionaryGetDictionary(d, "Resources", &res)
        let child = CGPDFContentStreamCreateWithStream(st, res ?? d, t.cs)
        let saved = (t.ctm, t.stack, t.tm, t.tlm, t.ts, t.tsStack, t.cs)
        t.ctm = m.concatenating(t.ctm); t.stack = []; t.tsStack = []; t.cs = child; t.depth += 1
        scan(child, into: t)
        (t.ctm, t.stack, t.tm, t.tlm, t.ts, t.tsStack, t.cs) = saved
        t.depth -= 1
    }
    let sc = CGPDFScannerCreate(cs, table, Unmanaged.passUnretained(t).toOpaque())
    CGPDFScannerScan(sc)
    CGPDFScannerRelease(sc)
}

let a = CommandLine.arguments
guard a.count >= 2, let doc = CGPDFDocument(URL(fileURLWithPath: a[1]) as CFURL) else {
    FileHandle.standardError.write(Data("usage: pdfglyphs <pdf> [page...]\n".utf8)); exit(2)
}
let pages = a.count > 2 ? a[2...].compactMap { Int($0) } : Array(1...doc.numberOfPages)
var composite = 0
for p in pages {
    guard let page = doc.page(at: p) else { continue }
    let cs = CGPDFContentStreamCreateWithPage(page)
    let t = Tracer(cs: cs)
    t.page = p
    scan(cs, into: t)
    FileHandle.standardOutput.write(Data(t.out.utf8))
    composite += t.composites
}
if composite > 0 { FileHandle.standardError.write(Data("pdfglyphs: \(composite) glyphs of composite fonts (width 0)\n".utf8)) }
