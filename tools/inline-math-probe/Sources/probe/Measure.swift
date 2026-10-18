// The four measures of a crop (see README.md): (a) components cut by the crop's border, (b) the share of the span's ink that lies
// outside the box within ±0.6 line heights, (c) ink of the neighbouring lines inside the crop, (d) the trailing punctuation
// trimmed. Plus the ink-grown box: the box grown by the components it cuts or misses, within limits.
import CoreGraphics
import Foundation

struct Config {
    /// Gray levels below this are ink.
    var threshold = 170
    /// Pixels by which the ink is dilated to decide which parts "nearly touch" (a subscript under its letter).
    var dilate = 2
    /// Pixels added around the union of the word boxes.
    var pad = 0
    /// A component counts as cut when at least this many of its pixels lie outside the crop.
    var tol = 1
    /// A neighbour-line component counts as an intrusion with at least this many pixels in the crop.
    var minForeign = 4
    /// (b) looks this far (in line heights) above and below the box.
    var margin = 0.6
    var bLimit = 0.05
    /// The most the ink-grown box may exceed the word boxes' union sideways / vertically, in line heights.
    var growX = 0.25
    var growY = 0.6
    /// none | shrink (−30 % height) | grow (the bottom edge 1.3 line heights down, into the next line): the FAIL-first mutants.
    var mutate = "none"
}

struct Trim {
    var ok: Bool
    var kind: String
    var x1: Int
}

struct Metrics {
    /// Per component of the span's own line cut by the border: pixels outside.
    var cut: [Int] = []
    /// The same for components of other lines (a neighbour's ascender that reaches into the crop; (c) counts its pixels inside).
    var cutForeign: [Int] = []
    /// Components with ink on the border ring (cut or not).
    var touch = 0
    /// Share of the connected ink outside the box, near-connected (dilated) and strictly connected.
    var b = 0.0, bStrict = 0.0
    /// Per neighbour-line component in the crop: pixels inside.
    var foreign: [Int] = []

    func a(_ c: Config) -> Int { cut.filter { $0 >= c.tol }.count }
    /// (a) read strictly: every component the border cuts, whoever's it is.
    func aAll(_ c: Config) -> Int { (cut + cutForeign).filter { $0 >= c.tol }.count }
    func c(_ c: Config) -> Int { foreign.filter { $0 >= c.minForeign }.count }
    func clean(_ cfg: Config) -> Bool { a(cfg) == 0 && b < cfg.bLimit && c(cfg) == 0 }
    func cleanStrict(_ cfg: Config) -> Bool { aAll(cfg) == 0 && b < cfg.bLimit && c(cfg) == 0 }
    /// The first failing measure, for the montage.
    func why(_ cfg: Config) -> String {
        [a(cfg) > 0 ? "a" : "", b >= cfg.bLimit ? "b" : "", c(cfg) > 0 ? "c" : ""].joined()
    }
}

final class Row {
    var path = "", page = "", text = ""
    var line: JLine
    var lh = 0.0
    var trailing: [Character] = []
    var base = IntRect(x0: 0, y0: 0, x1: 0, y1: 0)
    var trim: Trim?
    var crop = IntRect(x0: 0, y0: 0, x1: 0, y1: 0)
    var m = Metrics()
    /// nil: the growth was refused (limits, or a neighbour's glyph in the way).
    var grown: IntRect?
    var grownM: Metrics?
    var grownWhy = ""
    var image: CGImage
    init(line: JLine, image: CGImage) { self.line = line; self.image = image }
}

final class Measurer {
    let ink: Ink
    let cfg: Config
    /// Every line of the page in this read, for deciding whose a component is.
    let lines: [JLine]
    init(ink: Ink, cfg: Config, lines: [JLine]) { self.ink = ink; self.cfg = cfg; self.lines = lines }

    func row(path: String, page: String, span: SpanWords) -> Row {
        let line = span.line!
        let r = Row(line: line, image: ink.image)
        r.path = path; r.page = page; r.text = span.text; r.trailing = span.trailing
        r.lh = max(1, line.h)
        var box = span.words.dropFirst().reduce(CGRect(x: span.words[0].x, y: span.words[0].y, width: span.words[0].w, height: span.words[0].h)) {
            $0.union(CGRect(x: $1.x, y: $1.y, width: $1.w, height: $1.h))
        }
        switch cfg.mutate {
        case "shrink": box = CGRect(x: box.minX, y: box.midY - box.height * 0.35, width: box.width, height: box.height * 0.7)
        case "grow": box.size.height += 1.3 * r.lh
        default: break
        }
        var b = IntRect(box)
        b = IntRect(x0: b.x0 - cfg.pad, y0: b.y0 - cfg.pad, x1: b.x1 + cfg.pad, y1: b.y1 + cfg.pad).clamped(ink.width, ink.height)
        r.base = b
        if !r.trailing.isEmpty { r.trim = trim(b, trailing: r.trailing, lh: r.lh, line: line) }
        r.crop = b
        if let t = r.trim, t.ok { r.crop.x1 = t.x1 }
        r.m = metrics(r.crop, line: line)
        // The ink-grown box starts from the trimmed crop; the trailing punctuation stays out of it.
        let cutAt = (r.trim?.ok ?? false) ? r.trim?.x1 : nil
        switch grow(r.crop, line: line, lh: r.lh, cutAt: cutAt) {
        case .success(let g): r.grown = g; r.grownM = metrics(g, line: line)
        case .failure(let why): r.grownWhy = why.reason
        }
        return r
    }

    /// Whose a component is: the span's line owns it when that line is the nearest, by the distance of the component's centroid to
    /// the line's middle, of the lines that share its columns, and the component is no longer than 3 line heights or taller than
    /// 2.5 (a table rule or a frame is no glyph). Ink of another line inside the crop is an intrusion (c); a part of the span
    /// outside the box is the span's (b); a rule is never the span's.
    final class Owner {
        let line: JLine
        let m: Measurer
        private var cache: [Int32: Bool] = [:]
        init(line: JLine, m: Measurer) { self.line = line; self.m = m }

        func callAsFunction(_ l: Int32) -> Bool {
            if let known = cache[l] { return known }
            let c = m.ink.comps[Int(l)]
            var own = Double(c.box.width) <= 3 * line.h && Double(c.box.height) <= 2.5 * line.h
            if own {
                let mine = abs(c.cy - (line.y + line.h / 2))
                own = !m.lines.contains { other in
                    other.x < Double(c.box.x1) && other.x + other.w > Double(c.box.x0) && !(other.x == line.x && other.y == line.y)
                        && abs(c.cy - (other.y + other.h / 2)) < mine
                }
            }
            cache[l] = own
            return own
        }
    }

    /// Raw components with ink inside `r`, and how many of their pixels are.
    func insideLabels(_ r: IntRect) -> [Int32: Int] {
        var inside: [Int32: Int] = [:]
        for y in r.y0..<r.y1 {
            for x in r.x0..<r.x1 {
                let l = ink.labels[y * ink.width + x]
                if l > 0 { inside[l, default: 0] += 1 }
            }
        }
        return inside
    }

    func metrics(_ r: IntRect, line: JLine) -> Metrics {
        var m = Metrics()
        guard r.width > 0, r.height > 0 else { return m }
        let own = Owner(line: line, m: self)
        let inside = insideLabels(r)
        var ring = Set<Int32>()
        for x in r.x0..<r.x1 { ring.insert(ink.labels[r.y0 * ink.width + x]); ring.insert(ink.labels[(r.y1 - 1) * ink.width + x]) }
        for y in r.y0..<r.y1 { ring.insert(ink.labels[y * ink.width + r.x0]); ring.insert(ink.labels[y * ink.width + r.x1 - 1]) }
        ring.remove(0)
        m.touch = ring.count
        var strict = Set<Int32>(), near = Set<Int32>()
        for (l, n) in inside {
            let outside = ink.comps[Int(l)].count - n
            if own(l) {
                strict.insert(l)
                if outside > 0 { m.cut.append(outside) }
            } else {
                m.foreign.append(n)
                if outside > 0 { m.cutForeign.append(outside) }
            }
        }
        for y in r.y0..<r.y1 {
            for x in r.x0..<r.x1 {
                let i = y * ink.width + x
                if ink.mask[i] != 0, strict.contains(ink.labels[i]) { near.insert(ink.dlabels[i]) }
            }
        }
        let mh = Int((cfg.margin * Double(line.h)).rounded())
        var inD = 0, outD = 0, inS = 0, outS = 0
        for y in max(0, r.y0 - mh)..<min(ink.height, r.y1 + mh) {
            let inRow = y >= r.y0 && y < r.y1
            for x in r.x0..<r.x1 {
                let i = y * ink.width + x
                guard ink.mask[i] != 0 else { continue }
                let l = ink.labels[i]
                guard own(l) else { continue }
                if near.contains(ink.dlabels[i]) { if inRow { inD += 1 } else { outD += 1 } }
                if strict.contains(l) { if inRow { inS += 1 } else { outS += 1 } }
            }
        }
        m.b = inD + outD == 0 ? 0 : Double(outD) / Double(inD + outD)
        m.bStrict = inS + outS == 0 ? 0 : Double(outS) / Double(inS + outS)
        return m
    }

    // MARK: (d) trailing punctuation

    /// Cuts the crop's right edge before the punctuation glyphs: the ink components at its right end that are as small as the
    /// characters the text says follow the span. Fails when the glyph is too big for the character (a letter, not a comma), or when
    /// the span's last glyph overlaps the punctuation sideways (italic overhang): no vertical cut separates them.
    func trim(_ r: IntRect, trailing: [Character], lh: Double, line: JLine) -> Trim {
        let inside = insideLabels(r)
        var rem = inside.keys.filter { l in
            let c = ink.comps[Int(l)]
            return c.cx >= Double(r.x0) && c.cx < Double(r.x1) && c.cy >= Double(r.y0) && c.cy < Double(r.y1)
        }
        var removedX0 = Int.max
        for ch in trailing.reversed() {
            guard let last = rem.max(by: { ink.comps[Int($0)].box.x1 < ink.comps[Int($1)].box.x1 }) else { return Trim(ok: false, kind: "empty", x1: r.x1) }
            let lb = ink.comps[Int(last)].box
            let group = rem.filter { l in
                let b = ink.comps[Int(l)].box
                let ov = min(b.x1, lb.x1) - max(b.x0, lb.x0)
                return l == last || Double(ov) >= 0.5 * Double(min(b.width, lb.width))
            }
            let gb = group.dropFirst().reduce(lb) { $0.union(ink.comps[Int($1)].box) }
            let hMax = ".,".contains(ch) ? 0.35 : (":;".contains(ch) ? 0.6 : 0.9)
            guard Double(gb.height) <= hMax * lh, Double(gb.width) <= 0.5 * lh else { return Trim(ok: false, kind: "glyph", x1: r.x1) }
            rem.removeAll { group.contains($0) }
            removedX0 = min(removedX0, gb.x0)
        }
        guard let keep = rem.map({ ink.comps[Int($0)].box.x1 }).max() else { return Trim(ok: false, kind: "empty", x1: r.x1) }
        if keep > removedX0 + 1 { return Trim(ok: false, kind: "overlap", x1: r.x1) }
        return Trim(ok: true, kind: "ok", x1: max(r.x0 + 1, keep))
    }

    // MARK: the ink-grown box

    struct Refused: Error { var reason: String }

    /// Grows `r` by the components of the span's line that it cuts (when most of their ink is inside), and by those of its
    /// nearly-touching ink that lie wholly within its width (a subscript below, an exponent above); at most `growX` / `growY` line
    /// heights beyond `r`. Refused when a component it needs is beyond the limits, or when it would take in the trailing
    /// punctuation (`cutAt`).
    func grow(_ r0: IntRect, line: JLine, lh: Double, cutAt: Int?) -> Result<IntRect, Refused> {
        let own = Owner(line: line, m: self)
        let gx = Int((cfg.growX * lh).rounded()), gy = Int((cfg.growY * lh).rounded())
        var r = r0
        for _ in 0..<4 {
            let inside = insideLabels(r)
            var near = Set<Int32>()
            for (l, _) in inside where own(l) {
                // The dilated components holding this one's ink pixels (found through the components' bounding box).
                let b = ink.comps[Int(l)].box
                for y in b.y0..<b.y1 { for x in b.x0..<b.x1 where ink.labels[y * ink.width + x] == l { near.insert(ink.dlabels[y * ink.width + x]) } }
            }
            var candidates = Set<Int32>()
            for d in near { for l in ink.inDilated[Int(d)] where own(l) { candidates.insert(l) } }
            var next = r
            for l in candidates {
                let c = ink.comps[Int(l)]
                if let cutAt, c.box.x0 >= cutAt - 1 { continue }
                let withinX = c.box.x0 >= r.x0 - 2 && c.box.x1 <= r.x1 + 2
                let inFrac = Double(inside[l] ?? 0) / Double(c.count)
                if withinX || inFrac >= 0.65 { next = next.union(c.box) }
            }
            next = next.clamped(ink.width, ink.height)
            guard next.x0 >= r0.x0 - gx, next.x1 <= r0.x1 + gx, next.y0 >= r0.y0 - gy, next.y1 <= r0.y1 + gy else {
                return .failure(Refused(reason: "limits"))
            }
            if next == r { return .success(r) }
            r = next
        }
        return .success(r)
    }
}
