import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import MwoyeoCore

/// Deterministic texture so scroll matching has something to lock onto.
func texture(width: Int, height: Int, seed: Int = 1) -> GrayImage {
    var g = GrayImage(width: width, height: height)
    for y in 0..<height {
        for x in 0..<width {
            g[x, y] = UInt8(truncatingIfNeeded: (x * 7 + y * y * 13 + seed * 31 + (x * y) % 17) & 0xFF)
        }
    }
    return g
}

@Suite struct FrameDiffTests {
    @Test func wobbleOneTileTallIsNotAScroll() {
        let a = GrayImage(width: 96, height: 96, fill: 40)
        var b = a, c = a
        for y in 36..<44 { for x in 40..<52 { b[x, y] = 220 } }   // an emoji, then the same a pixel lower
        for y in 37..<45 { for x in 40..<52 { c[x, y] = 220 } }
        #expect(FrameDiff.scrollRegions(from: b, to: c, change: FrameDiff.changeMap(from: b, to: c, tile: 16), maxShift: 32).isEmpty)
    }

    @Test func animatedTileIsIgnoredUntilItGoesStill() {
        let a = GrayImage(width: 96, height: 96, fill: 200)
        var b = a, c = a
        for y in 36..<44 { for x in 36..<44 { b[x, y] = 20; c[x, y] = 120 } }   // an emoji in tile (2, 2), two frames
        var churn = Churn()
        churn.window = 1
        var prev = a, masked: [Bool] = []
        for (i, f) in [b, c, b, c].enumerated() {
            let m = FrameDiff.changeMap(from: prev, to: f, tile: 16)
            churn.add(m, at: Double(i) * 0.1)
            masked.append(churn.masking(m, at: Double(i) * 0.1).isUnchanged)
            prev = f
        }
        #expect(masked == [false, false, true, true])
        #expect(churn.coolsIn(at: 0.3).map { abs($0 - 1) < 1e-9 } == true)
        // Its edge reaching into a neighbouring tile is masked with it; an edit further off is not.
        var d = c
        for y in 30..<33 { for x in 50..<53 { d[x, y] = 20 } }   // tile (3, 1)
        #expect(churn.masking(FrameDiff.changeMap(from: c, to: d, tile: 16), at: 0.35).isUnchanged)
        d = c
        for y in 84..<88 { for x in 4..<8 { d[x, y] = 20 } }     // tile (0, 5)
        #expect(churn.masking(FrameDiff.changeMap(from: c, to: d, tile: 16), at: 0.35).intersects(PixelRect(x: 0, y: 80, width: 16, height: 16)))
        // A second later it is still: the change it made since is seen again.
        #expect(!churn.masking(FrameDiff.changeMap(from: a, to: c, tile: 16), at: 1.4).isUnchanged)
        #expect(churn.coolsIn(at: 1.4) == nil)
    }

    @Test func identicalFramesAreUnchanged() {
        let a = texture(width: 64, height: 48)
        let m = FrameDiff.changeMap(from: a, to: a, tile: 16)
        #expect(m.isUnchanged)
        #expect(m.dirtyRect == nil)
        #expect(m.columns == 4 && m.rows == 3)
    }

    @Test func smallEditFlagsOnlyItsTile() {
        let a = GrayImage(width: 64, height: 48, fill: 200)
        var b = a
        for y in 20..<23 { for x in 36..<39 { b[x, y] = 20 } } // a 3×3 "glyph" inside tile (2, 1)
        let m = FrameDiff.changeMap(from: a, to: b, tile: 16)
        #expect(m.changedCount == 1)
        #expect(m.changed[1 * 4 + 2])
        #expect(m.dirtyRect == PixelRect(x: 32, y: 16, width: 16, height: 16))
        #expect(m.dirtyRect(outside: [PixelRect(x: 30, y: 0, width: 20, height: 48)]) == nil)
        #expect(m.intersects(PixelRect(x: 40, y: 0, width: 4, height: 48)))
        #expect(!m.intersects(PixelRect(x: 0, y: 0, width: 30, height: 48)))
    }

    @Test func noiseBelowDeltaIsIgnored() {
        let a = GrayImage(width: 32, height: 32, fill: 100)
        var b = a
        for i in stride(from: 0, to: b.pixels.count, by: 3) { b.pixels[i] = 110 }
        #expect(FrameDiff.changeMap(from: a, to: b).isUnchanged)
    }

    @Test func sizeChangeMeansEverythingChanged() {
        let m = FrameDiff.changeMap(from: GrayImage(width: 10, height: 10), to: GrayImage(width: 20, height: 20), tile: 8)
        #expect(m.ratio == 1)
    }

    @Test(arguments: [7, -5, 1, 23])
    func detectsVerticalScroll(dy: Int) {
        let tall = texture(width: 80, height: 200)
        // Window of 120 rows at offset 40; scrolling the page moves the window by -dy.
        func window(at top: Int) -> GrayImage {
            GrayImage(width: 80, height: 120, pixels: Array(tall.pixels[(top * 80)..<((top + 120) * 80)]))
        }
        let a = window(at: 40), b = window(at: 40 - dy)
        #expect(FrameDiff.verticalShift(from: a, to: b, maxShift: 30) == Double(dy))
    }

    @Test func shiftedImageMatchesScrolledFrame() {
        let tall = texture(width: 40, height: 100)
        let a = GrayImage(width: 40, height: 60, pixels: Array(tall.pixels[(20 * 40)..<(80 * 40)]))
        let b = GrayImage(width: 40, height: 60, pixels: Array(tall.pixels[(10 * 40)..<(70 * 40)])) // content moved down 10
        let shifted = a.shifted(dx: 0, dy: 10)
        #expect(Array(shifted.pixels[(10 * 40)...]) == Array(b.pixels[(10 * 40)...]))
        #expect(shifted.pixels[0..<(10 * 40)].allSatisfy { $0 == 0 })
        #expect(a.shifted(dx: 0, dy: -60).pixels.allSatisfy { $0 == 0 })
        #expect(a.vacatedStrips(dx: 0, dy: 10) == [PixelRect(x: 0, y: 0, width: 40, height: 10)])
    }

    @Test func shiftsInTwoDimensions() {
        var a = GrayImage(width: 5, height: 4)
        for y in 0..<4 { for x in 0..<5 { a[x, y] = UInt8(10 * y + x + 1) } }
        let s = a.shifted(dx: -2, dy: 1, fill: 0)
        // Row 0 vacated; row 1 holds old row 0 moved 2 left; last 2 columns vacated.
        #expect(Array(s.pixels[0..<5]) == [0, 0, 0, 0, 0])
        #expect(Array(s.pixels[5..<10]) == [3, 4, 5, 0, 0])
        #expect(Array(s.pixels[15..<20]) == [23, 24, 25, 0, 0])
        #expect(Set(a.vacatedStrips(dx: -2, dy: 1)) == [PixelRect(x: 0, y: 0, width: 5, height: 1), PixelRect(x: 3, y: 1, width: 2, height: 3)])
    }

    @Test func reframesIntoLargerCanvas() {
        var a = GrayImage(width: 3, height: 2)
        for y in 0..<2 { for x in 0..<3 { a[x, y] = UInt8(10 * y + x + 1) } }
        // Capture grew by 1 px on every side: old content sits at (1, 1) of a 5×4 canvas.
        let r = a.reframed(dx: 1, dy: 1, width: 5, height: 4)
        #expect(Array(r.pixels[5..<10]) == [0, 1, 2, 3, 0])
        #expect(Array(r.pixels[10..<15]) == [0, 11, 12, 13, 0])
        let ring = a.uncovered(dx: 1, dy: 1, width: 5, height: 4)
        #expect(ring.reduce(0) { $0 + $1.width * $1.height } == 5 * 4 - 3 * 2)
        #expect(a.uncovered(dx: 9, dy: 0, width: 5, height: 4) == [PixelRect(x: 0, y: 0, width: 5, height: 4)])
        // Shrinking leaves nothing uncovered.
        #expect(a.uncovered(dx: -1, dy: 0, width: 2, height: 2).isEmpty)
    }

    /// The strips a grow uncovered, carried through the shrink back to the old size, lie outside the canvas: nothing is left to read
    /// (holdfix117 A2: the strip left of the capture was read as every row of the next frame).
    @Test func stripsOfAGrowAreGoneAfterTheShrinkBack() {
        let a = GrayImage(width: 304, height: 208)
        let strips = a.uncovered(dx: 38, dy: 26, width: 380, height: 260)
        #expect(strips.count == 4)
        #expect(PixelRect.moved(strips, dx: -38, dy: -26, width: 304, height: 208).isEmpty)
    }

    /// A strip a shrink cuts keeps the part the smaller canvas still has; a move keeps the strips that stay on the canvas as they are.
    @Test func aStripKeepsThePartTheCanvasHas() {
        let right = PixelRect(x: 300, y: 10, width: 20, height: 50)
        #expect(PixelRect.moved([right], dx: -10, dy: 0, width: 300, height: 200) == [PixelRect(x: 290, y: 10, width: 10, height: 50)])
        #expect(PixelRect.moved([right], dx: -40, dy: 5, width: 300, height: 200) == [PixelRect(x: 260, y: 15, width: 20, height: 50)])
        #expect(PixelRect.moved([right], dx: 0, dy: -60, width: 400, height: 200).isEmpty)
    }

    @Test func unrelatedChangeIsNotAScroll() {
        let a = texture(width: 80, height: 100, seed: 1)
        let b = texture(width: 80, height: 100, seed: 9)
        #expect(FrameDiff.verticalShift(from: a, to: b, maxShift: 20) == nil)
        #expect(FrameDiff.verticalShift(from: a, to: a, maxShift: 20) == nil)
    }

    @Test func findsSubpixelScroll() {
        // Lines of text on a 4× finer "screen", box-downsampled like the capture; the page then scrolls by 2 screen
        // pixels = ½ gray pixel.
        let w = 480, h = 640
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(gray: 0.15, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let words = ["ok who stayed up for the patch notes", "guilty. they finally fixed it", "wait does that mean the skip",
                     "lol rip honestly", "Is anyone doing the co-op event", "I'm in! what time"]
        for i in 0..<15 {
            let s = NSAttributedString(string: words[i % words.count], attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.9, alpha: 1)])
            let x = 10 + (i * 37) % 60, y = h - 40 - i * 41
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
        }
        let base = ctx.data!
        func gray(top: Int) -> GrayImage {
            GrayImage(bgra: base + top * w * 4, width: w, height: 400, bytesPerRow: w * 4, step: 4)
        }
        let dy = FrameDiff.verticalShift(from: gray(top: 100), to: gray(top: 98), maxShift: 20)
        #expect(dy.map { abs($0 - 0.5) <= 0.25 } == true)
    }

    @Test func scrollsOnlyTheMovingColumn() {
        // A fixed sidebar (x < 48) and header (y < 16) around a log that scrolls up by 6 pixels.
        let page = texture(width: 128, height: 200, seed: 3), side = texture(width: 128, height: 128, seed: 8)
        func frame(top: Int) -> GrayImage {
            var g = GrayImage(width: 128, height: 128)
            for y in 0..<128 { for x in 0..<128 { g[x, y] = x < 48 || y < 16 ? side[x, y] : page[x, top + y] } }
            return g
        }
        let a = frame(top: 40), b = frame(top: 46)
        let regions = FrameDiff.scrollRegions(from: a, to: b, change: FrameDiff.changeMap(from: a, to: b), maxShift: 30)
        #expect(regions.count == 1)
        #expect(regions.first?.dy == -6)
        #expect(regions.first.map { $0.rect.x >= 32 && $0.rect.y >= 16 && $0.rect.x + $0.rect.width == 128 } == true)
        // One shift over the whole frame does not explain it.
        #expect(FrameDiff.verticalShift(from: a, to: b, maxShift: 30) == nil)
    }

    @Test func fixedMessageBoxSplitsTheScrollingLogFromATypingLine() {
        // Log (y < 96) scrolls up by 6; a fixed box (96..<120) sits still; a typing line (y >= 120) changes on its own.
        let page = texture(width: 128, height: 200, seed: 5), box = texture(width: 128, height: 144, seed: 9)
        func frame(top: Int, typing: Int) -> GrayImage {
            var g = GrayImage(width: 128, height: 144)
            for y in 0..<144 { for x in 0..<128 { g[x, y] = y < 96 ? page[x, top + y] : y < 120 ? box[x, y] : UInt8(truncatingIfNeeded: x * typing + y) } }
            return g
        }
        let a = frame(top: 40, typing: 3), b = frame(top: 46, typing: 5)
        let regions = FrameDiff.scrollRegions(from: a, to: b, change: FrameDiff.changeMap(from: a, to: b), maxShift: 30)
        #expect(regions.count == 1)
        #expect(regions.first?.dy == -6)
        #expect(regions.first.map { $0.rect.y + $0.rect.height <= 96 } == true)
    }

    @Test func loneBandAtOddsTakesItsNeighboursShift() {
        // Three bands scroll up by 6; the middle one repeats every 34 rows, so -40 matches it as well as -6 does.
        let page = texture(width: 96, height: 260, seed: 4)
        func frame(top: Int) -> GrayImage {
            var g = GrayImage(width: 96, height: 200)
            for y in 0..<200 { for x in 0..<96 {
                g[x, y] = x >= 32 && x < 64 ? UInt8(truncatingIfNeeded: ((y + top) % 34) * 7 + x) : page[x, y + top]
            } }
            return g
        }
        let a = frame(top: 40), b = frame(top: 46)
        let middle = PixelRect(x: 32, y: 0, width: 32, height: 200)
        #expect(FrameDiff.verticalShift(from: a.cropped(to: middle), to: b.cropped(to: middle), maxShift: 50) == -40)
        let regions = FrameDiff.scrollRegions(from: a, to: b, change: FrameDiff.changeMap(from: a, to: b), maxShift: 60)
        #expect(regions == [ScrollRegion(rect: PixelRect(x: 0, y: 0, width: 96, height: 200), dy: -6)])
    }

    @Test func accumulatorKeepsFractionalMoves() {
        var a = ShiftAccumulator()
        var total = 0
        for _ in 0..<20 { total += a.add(0.3) }
        #expect(total == 6)
        var b = ShiftAccumulator()
        var back = 0
        for _ in 0..<10 { back += b.add(-0.45) }
        #expect(back == -4) // -4.5 → 4 whole steps applied, -0.5 pending
        #expect(b.add(-0.5) == -1)
    }

    @Test func downsamplesBGRA() {
        // 4×2 BGRA: left 2×2 block white, right 2×2 block black → 2×1 gray at step 2.
        var bytes = [UInt8](repeating: 0, count: 4 * 2 * 4)
        for y in 0..<2 { for x in 0..<2 { for c in 0..<3 { bytes[(y * 4 + x) * 4 + c] = 255 } } }
        let g = bytes.withUnsafeBytes { GrayImage(bgra: $0.baseAddress!, width: 4, height: 2, bytesPerRow: 16, step: 2) }
        #expect(g.width == 2 && g.height == 1)
        #expect(g.pixels[0] >= 254 && g.pixels[1] == 0)
    }
}

@Suite struct TextEraseTests {
    let bg = RGBA(200, 220, 240)
    let ink = RGBA(30, 20, 60)

    /// 60×20 patch with a 4 px background ring; "glyphs" are vertical bars inside the text rect.
    func glyphPatch(background: RGBA, ink: RGBA) -> RGBAImage {
        var img = RGBAImage(width: 60, height: 20, color: background)
        for x in stride(from: 6, to: 54, by: 6) { for y in 6..<14 { img.set(x: x, y: y, ink); img.set(x: x + 1, y: y, ink) } }
        return img
    }

    @Test func otsuSplitsBimodalHistogram() {
        var h = [Int](repeating: 0, count: 256)
        h[40] = 100; h[42] = 50; h[200] = 300; h[205] = 80
        let t = TextEraser.otsuThreshold(h)
        #expect(t >= 42 && t < 200)
    }

    @Test func masksDarkGlyphsOnLightBackground() {
        let patch = glyphPatch(background: bg, ink: ink)
        let m = TextEraser.mask(for: patch, textRect: PixelRect(x: 4, y: 4, width: 52, height: 12), dilation: 0)
        #expect(m.count == 8 * 2 * 8)
        #expect(m.bits[6 * 60 + 6] == 1 && m.bits[6 * 60 + 9] == 0)
        #expect(m.appearance.textColor == ink)
        #expect(m.appearance.backgroundColor == bg)
        #expect(m.appearance.isFlatBackground)
    }

    @Test func masksLightGlyphsOnDarkBackground() {
        let patch = glyphPatch(background: RGBA(20, 20, 30), ink: RGBA(250, 250, 250))
        let m = TextEraser.mask(for: patch, textRect: PixelRect(x: 4, y: 4, width: 52, height: 12), dilation: 1)
        #expect(m.appearance.textColor == RGBA(250, 250, 250))
        // Dilation by 1 turns each 2×8 bar into 4×10.
        #expect(m.count == 8 * 4 * 10)
    }

    @Test func ignoresBoxEdgesRunningOffThePatch() {
        // Glyph bars plus a dark box edge along the bottom ring that spans the whole patch width.
        var patch = glyphPatch(background: bg, ink: ink)
        for x in 0..<60 { for y in 17..<20 { patch.set(x: x, y: y, ink) } }
        let m = TextEraser.mask(for: patch, textRect: PixelRect(x: 4, y: 4, width: 52, height: 12), dilation: 0)
        #expect(m.count == 8 * 2 * 8)           // only the bars
        #expect(m.bits[18 * 60 + 30] == 0)       // the edge survives
        #expect(m.glyphBounds == PixelRect(x: 6, y: 6, width: 44, height: 8))
        #expect(m.appearance.backgroundColor == bg) // median ignores the edge
        #expect(m.appearance.isFlatBackground)
    }

    @Test func fillsHolesEnclosedByTheMask() {
        // A 3×3 ring of mask with an unmasked centre, plus an open "C" whose inside reaches the border.
        var bits = [UInt8](repeating: 0, count: 8 * 5)
        for (x, y) in [(1, 1), (2, 1), (3, 1), (1, 2), (3, 2), (1, 3), (2, 3), (3, 3)] { bits[y * 8 + x] = 1 }
        for (x, y) in [(5, 1), (6, 1), (5, 2), (5, 3), (6, 3)] { bits[y * 8 + x] = 1 }
        TextEraser.fillEnclosedHoles(&bits, width: 8, height: 5)
        #expect(bits[2 * 8 + 2] == 1)   // enclosed → filled
        #expect(bits[2 * 8 + 6] == 0)   // open to the border → untouched
        #expect(bits.reduce(0) { $0 + Int($1) } == 14)
    }

    @Test func fillContinuesAGradientThroughTheHole() {
        var img = RGBAImage(width: 40, height: 20, color: RGBA(0, 0, 0))
        for y in 0..<20 { for x in 0..<40 { img.set(x: x, y: y, RGBA(UInt8(x * 5), 100, UInt8(y * 10))) } }
        let clean = img
        var mask = [UInt8](repeating: 0, count: 40 * 20)
        for y in 7..<13 { for x in 10..<30 { mask[y * 40 + x] = 1; img.set(x: x, y: y, RGBA(0, 0, 0)) } }
        TextEraser.fill(&img, mask: mask, smoothing: 40)
        var worst = 0.0
        for y in 7..<13 { for x in 10..<30 { worst = max(worst, img.color(x: x, y: y).distance(to: clean.color(x: x, y: y))) } }
        #expect(worst < 12, "max color error \(worst)")
        // Unmasked pixels untouched.
        #expect(img.color(x: 0, y: 0) == clean.color(x: 0, y: 0))
    }

    @Test func eraseThenFillRemovesGlyphs() {
        var patch = glyphPatch(background: bg, ink: ink)
        let m = TextEraser.mask(for: patch, textRect: PixelRect(x: 4, y: 4, width: 52, height: 12), dilation: 1)
        TextEraser.fill(&patch, mask: m.bits)
        for y in 0..<20 { for x in 0..<60 { #expect(patch.color(x: x, y: y).distance(to: bg) < 2) } }
    }
}

@Suite struct TextTests {
    @Test func editDistance() {
        #expect(TextSimilarity.editDistance("kitten", "sitting") == 3)
        #expect(TextSimilarity.editDistance("", "abc") == 3)
        #expect(TextSimilarity.editDistance("게임종료", "게임 종료") == 1)
        #expect(TextSimilarity.similarity("設定", "設定") == 1)
    }

    @Test func iou() {
        #expect(TextSimilarity.iou(CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 0, y: 0, width: 10, height: 10)) == 1)
        #expect(abs(TextSimilarity.iou(CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 5, y: 0, width: 10, height: 10)) - 1.0 / 3) < 1e-9)
        #expect(TextSimilarity.iou(CGRect(x: 0, y: 0, width: 1, height: 1), CGRect(x: 5, y: 5, width: 1, height: 1)) == 0)
    }

    @Test func matcherKeepsIdentityThroughJitter() {
        let old = [BlockMatcher.Item(rect: CGRect(x: 10, y: 10, width: 200, height: 20), text: "設定を保存しますか？"),
                   BlockMatcher.Item(rect: CGRect(x: 10, y: 50, width: 200, height: 20), text: "ゲームを終了する")]
        let new = [BlockMatcher.Item(rect: CGRect(x: 12, y: 52, width: 198, height: 21), text: "ゲームを終了する"),
                   BlockMatcher.Item(rect: CGRect(x: 11, y: 9, width: 201, height: 20), text: "設定を保存しますか"),
                   BlockMatcher.Item(rect: CGRect(x: 10, y: 300, width: 100, height: 20), text: "新しい")]
        #expect(BlockMatcher.match(old: old, new: new) == [1, 0, nil])
    }

    @Test func matcherUsesEachOldItemOnce() {
        let old = [BlockMatcher.Item(rect: CGRect(x: 0, y: 0, width: 100, height: 20), text: "abc")]
        let new = [BlockMatcher.Item(rect: CGRect(x: 0, y: 0, width: 100, height: 20), text: "abc"),
                   BlockMatcher.Item(rect: CGRect(x: 1, y: 0, width: 100, height: 20), text: "abc")]
        #expect(BlockMatcher.match(old: old, new: new) == [0, nil])
    }

    @Test func lruEvictsLeastRecentlyUsed() {
        let c = LRUCache<String, Int>(capacity: 2)
        c["a"] = 1; c["b"] = 2
        _ = c["a"]          // a is now most recent
        c["c"] = 3          // evicts b
        #expect(c["b"] == nil && c["a"] == 1 && c["c"] == 3 && c.count == 2)
        c["a"] = nil
        #expect(c.count == 1)
        c["d"] = 4; c["e"] = 5
        #expect(c["c"] == nil && c["d"] == 4 && c["e"] == 5)
        _ = c["d"]
        c.capacity = 1      // keeps the most recent
        #expect(c.count == 1 && c["d"] == 4 && c["e"] == nil)
    }

    @Test func fitFontSizeBinarySearch() {
        // Text 10 chars, each 0.6em wide, single line of 1.2em height.
        let size = TextFitter.fitFontSize(in: CGSize(width: 120, height: 40), minSize: 6, maxSize: 64) { s in
            CGSize(width: 6 * s, height: 1.2 * s)
        }
        #expect(size >= 19.5 && 6 * size <= 120.5)
        #expect(TextFitter.fitFontSize(in: CGSize(width: 1, height: 1), minSize: 6, maxSize: 64) { CGSize(width: $0, height: $0) } == 6)
        #expect(TextFitter.fitFontSize(in: CGSize(width: 999, height: 999), minSize: 6, maxSize: 64) { CGSize(width: $0, height: $0) } == 64)
    }

    @Test func coreTextWrapsWhenNarrow() {
        let s = NSAttributedString(string: "새로운 아이템을 획득했습니다! 공격력이 10 상승했습니다.",
                                   attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Apple SD Gothic Neo" as CFString, 20, nil)])
        let wide = TextFitter.measure(s, width: 2000), narrow = TextFitter.measure(s, width: 150)
        #expect(narrow.height > wide.height * 2)
        #expect(narrow.width <= 150)
    }

    @Test func stripsEchoedNumbering() {
        #expect(TranslationCleanup.stripEchoedNumbering("3. 게임을 종료합니다.", index: 3, source: "ゲームを終了する") == "게임을 종료합니다.")
        #expect(TranslationCleanup.stripEchoedNumbering("3) 장비", index: 3, source: "装備") == "장비")
        #expect(TranslationCleanup.stripEchoedNumbering("3. 장비", index: 3, source: "3. 装備") == "3. 장비")
        #expect(TranslationCleanup.stripEchoedNumbering("30개", index: 3, source: "30個") == "30개")
    }
}

@Suite struct OverscanTests {
    let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func capturesAroundTheLensAndStaysOnScreen() {
        let lens = CGRect(x: 400, y: 300, width: 400, height: 200)
        let r = Overscan.rect(around: lens, wide: false, display: display)
        #expect(r == lens.insetBy(dx: -120, dy: -80))
        // Near the left edge the capture slides right instead of being cut.
        let edge = CGRect(x: 10, y: 300, width: 400, height: 200)
        let e = Overscan.rect(around: edge, wide: true, display: display)
        #expect(e.minX == 0 && e.width == 400 + 2 * 160)
    }

    @Test func lensMovesInsideTheCaptureUntilNearItsEdge() {
        let lens = CGRect(x: 500, y: 300, width: 400, height: 200)
        let capture = Overscan.rect(around: lens, wide: true, display: display)  // 160 × 160 pt margins
        func plan(dx: CGFloat) -> Overscan.Plan {
            Overscan.plan(lens: lens.offsetBy(dx: dx, dy: 0), capture: capture, wide: true, allowResize: false, display: display)
        }
        #expect(plan(dx: 90) == .keep)
        guard case .move(let r) = plan(dx: 100) else { Issue.record("expected a re-centre"); return }
        #expect(r.size == capture.size && r.midX == lens.midX + 100)
        // Calming down shrinks the margins, but only when resizing is allowed.
        #expect(Overscan.plan(lens: lens, capture: capture, wide: false, allowResize: false, display: display) == .keep)
        guard case .resize = Overscan.plan(lens: lens, capture: capture, wide: false, allowResize: true, display: display)
        else { Issue.record("expected a resize"); return }
    }

    @Test func readsAheadWhereThingsAreHeading() {
        let lens = CGRect(x: 500, y: 300, width: 400, height: 200)
        let r = Overscan.rect(around: lens, wide: true, display: display, lead: CGVector(dx: 1, dy: 0))
        // Same size; three times the margin ahead as behind.
        #expect(r.size == Overscan.rect(around: lens, wide: true, display: display).size)
        #expect(r.maxX - lens.maxX == 3 * (lens.minX - r.minX))
    }
}

@Test func shiftsOnlyInsideARegion() {
    var a = GrayImage(width: 3, height: 4)
    for y in 0..<4 { for x in 0..<3 { a[x, y] = UInt8(10 * y + x + 1) } }
    let r = PixelRect(x: 1, y: 1, width: 2, height: 3)
    let s = a.shifted(dy: -1, within: r)
    #expect(s.pixels == [1, 2, 3, 11, 22, 23, 21, 32, 33, 31, 0, 0])
    #expect(GrayImage.vacated(dy: -1, within: r) == PixelRect(x: 1, y: 3, width: 2, height: 1))
    #expect(a.replacing(r, from: s) == s)
}

@Suite struct ScrollPredictorTests {
    @Test func followsTrackpadDeltasOneToOne() {
        var p = ScrollPredictor()
        p.latency = 0
        for i in 0..<10 { p.wheel(delta: -4, time: 1 + Double(i) * 0.01, precise: true) }
        // Only what came after the frame the overlay sits on counts.
        #expect(p.offset(from: 1.045, to: 2) == -20)
    }

    @Test func momentumTailIsFollowedToTheEnd() {
        var p = ScrollPredictor()
        p.latency = 0
        var d = -30.0, total = 0.0, tail = 0.0
        for i in 0..<40 {
            let t = Double(i) / 60
            p.wheel(delta: d.rounded(), time: t, precise: true)
            total += d.rounded()
            if t >= 0.5 { tail += d.rounded() }
            d *= 0.9
        }
        #expect(p.offset(from: -1, to: 1) == total)
        // Between two frames late in the glide, only the decayed events between them.
        #expect(p.offset(from: 0.5, to: 1) == tail)
    }

    @Test func learnsWheelLinesAndEasesThem() {
        var p = ScrollPredictor()
        p.latency = 0
        p.wheel(delta: -1, time: 0, precise: false)
        #expect(p.offset(from: 0, to: 1) == 0)   // unknown until a frame shows how far a line goes
        p.confirm(shift: -40, from: 0, to: 1)
        p.wheel(delta: -1, time: 2, precise: false)
        // Mid-animation part of the step, all of it once done.
        let mid = p.offset(from: 2, to: 2 + p.stepDuration / 2)
        #expect(mid < -20 && mid > -40)
        #expect(abs(p.offset(from: 2, to: 3) + 40) < 1e-9)
    }

    @Test func ignoresScrollingThatHitTheEnd() {
        var p = ScrollPredictor()
        p.latency = 0
        p.wheel(delta: -50, time: 0, precise: true)
        p.confirm(shift: 0, from: -1, to: 1)       // the page was already at its end
        p.confirm(shift: -60, from: -1, to: 1)     // pages that scroll a bit more per point are learnt
        #expect(abs(p.offset(from: -1, to: 1) + 53) < 1e-9)
    }
}

@Test func grayCropKeepsRows() {
    var a = GrayImage(width: 4, height: 3)
    for y in 0..<3 { for x in 0..<4 { a[x, y] = UInt8(10 * y + x) } }
    let c = a.cropped(to: PixelRect(x: 1, y: 1, width: 2, height: 2))
    #expect(c.pixels == [11, 12, 21, 22])
}

@Test func loneJamoBecomeCompatibilityLetters() {
    #expect(TranslationCleanup.standaloneJamo("\u{110F}\u{110F} RIP") == "ㅋㅋ RIP")
    // A leading consonant followed by a vowel is part of a syllable and stays.
    #expect(TranslationCleanup.standaloneJamo("\u{1100}\u{1161}") == "\u{1100}\u{1161}")
}

@Test func translationFilterKeepsWhatIsNotSourceText() {
    // Japanese page: only lines with Japanese in them are translated.
    #expect(TranslationFilter.needsTranslation("パッチ1.4でバグが直った", cjkSource: true))
    #expect(TranslationFilter.needsTranslation("318件", cjkSource: true))
    #expect(!TranslationFilter.needsTranslation("threadly", cjkSource: true))
    #expect(!TranslationFilter.needsTranslation("Starfall Valley", cjkSource: true))
    #expect(!TranslationFilter.needsTranslation("4 2.4k ▼", cjkSource: true))
    // English page: words are translated; handles, links and counters are not.
    #expect(TranslationFilter.needsTranslation("Is anyone doing the raid tonight?", cjkSource: false))
    #expect(TranslationFilter.needsTranslation("Share", cjkSource: false))
    #expect(!TranslationFilter.needsTranslation("2.4k", cjkSource: false))
    #expect(!TranslationFilter.needsTranslation("u/ollie_owl", cjkSource: false))
    #expect(!TranslationFilter.needsTranslation("@junpark", cjkSource: false))
    #expect(!TranslationFilter.needsTranslation("https://example.com/a", cjkSource: false))
    #expect(!TranslationFilter.needsTranslation("— 12 —", cjkSource: false))
}

/// H2 (round k3b, 2026-10-20): any block with "://" in it was kept as written, so a sentence with a link in it (issue-en md-light-plain:
/// 14 words of prose, a path and a URL) stayed English. A line that is mostly a link stays; a sentence that holds one is a sentence.
@Test func aSentenceWithALinkInItIsStillTranslated() {
    let prose = "Expected: the pill clears at once. The state is in Core/Sources/MwoyeoCore/ReadWait. swift; a build to try is at"
    #expect(TranslationFilter.needsTranslation(prose, cjkSource: false))                                  // the same words, no link: translated today
    #expect(TranslationFilter.needsTranslation(prose + " https://github.com/midagedev/mwoyeo/releases/latest.", cjkSource: false))
    #expect(TranslationFilter.needsTranslation("Download the latest build from https://example.com/releases today", cjkSource: false))
    #expect(!TranslationFilter.needsTranslation("Source: https://arxiv.org/abs/1706.03762", cjkSource: false))
    #expect(!TranslationFilter.needsTranslation("https://example.com/a  12 min", cjkSource: false))
}

@Test func restoresSourceTokenCase() {
    #expect(TranslationCleanup.restoreSourceTokens("S/starfallvalley 내 검색", source: "s/starfallvalley 内を検索") == "s/starfallvalley 내 검색")
    #expect(TranslationCleanup.restoreSourceTokens("U/mayafox · 5시간 전", source: "u/mayafox · 5時間前") == "u/mayafox · 5시간 전")
    #expect(TranslationCleanup.restoreSourceTokens("RTA 멤버들은", source: "RTA勢は") == "RTA 멤버들은")
    // A token is restored only where it stands as a word: the "A" of "A threshold" once turned "Man, and" into "MAn, And" (paper p12).
    let reference = "7 Nobuyuki Otsu. A threshold selection method. IEEE Transactions on Systems, Man, and Cybernetics. O i"
    #expect(TranslationCleanup.restoreSourceTokens("7 노부유키 오츠. 임계값 선택 방법. IEEE Transactions on Systems, Man, and Cybernetics. prosevorda", source: reference)
            == "7 노부유키 오츠. 임계값 선택 방법. IEEE Transactions on Systems, Man, and Cybernetics. prosevorda")
    #expect(TranslationCleanup.restoreSourceTokens("Ios 앱의 설정", source: "iOS app settings") == "iOS 앱의 설정")
    #expect(TranslationCleanup.restoreSourceTokens("ios와 macOS", source: "iOS and macOS") == "iOS와 macOS")
    // A word the source writes two ways is left as translated, whichever way: before, the last spelling in Set order won (paper p4, 2026-10-20).
    let twoWays = "Let R be a region and A the count of all features"
    #expect(TranslationCleanup.restoreSourceTokens("R을 영역, A를 모든 특징의 수라고 하자", source: twoWays) == "R을 영역, A를 모든 특징의 수라고 하자")
    #expect(TranslationCleanup.restoreSourceTokens("R을 영역, a를 모든 특징의 수라고 하자", source: twoWays) == "R을 영역, a를 모든 특징의 수라고 하자")
}

@Test func lineSplitsIntoStyleRuns() {
    func tok(_ text: String, _ x: CGFloat, _ w: CGFloat, _ c: RGBA?, solid: Bool = false) -> StyleRuns.Token {
        .init(text: text, minX: x, maxX: x + w, color: c, solid: solid)
    }
    let red = RGBA(240, 110, 100), grey = RGBA(150, 152, 158), white = RGBA(230, 230, 230)
    // "junpark Today at 8:13 PM": name and timestamp split; the inky-less "at" stays with its neighbours.
    let header = [tok("junpark", 0, 127, red), tok("Today", 130, 70, grey), tok("at", 204, 23, nil),
                  tok("8:13", 230, 50, grey), tok("PM", 284, 44, grey)]
    #expect(StyleRuns.runs(header, lineHeight: 27) == [0..<1, 1..<5])
    // An avatar read as "•" in front of "u/ollie_owl · 7時間前" is cut off, and so is the separator dot.
    let reddit = [tok("•", 0, 55, RGBA(190, 120, 250), solid: true), tok("u/ollie_owl", 58, 140, white),
                  tok("·", 205, 8, nil), tok("7", 220, 17, grey), tok("時", 237, 22, grey)]
    #expect(StyleRuns.runs(reddit, lineHeight: 45) == [1..<2, 3..<5])
    // An emoji read as "9" in front of "318件" is not part of the text (and so stays as drawn).
    let count = [tok("9", 0, 30, white, solid: true), tok("3", 34, 22, white), tok("1", 56, 12, white), tok("件", 82, 30, white)]
    #expect(StyleRuns.runs(count, lineHeight: 34) == [1..<4])
    // Stray marks for icons at either end go; meaningful punctuation stays.
    #expect(StyleRuns.runs([tok("，", 0, 17, white), tok("共", 20, 22, white), tok("有", 42, 22, white)], lineHeight: 30) == [1..<3])
    #expect(StyleRuns.runs([tok("Ollie", 0, 50, red), tok("•", 55, 10, red)], lineHeight: 30) == [0..<1])
    #expect(StyleRuns.runs([tok("#", 0, 12, grey), tok("general", 16, 70, grey)], lineHeight: 30) == [0..<2])
    #expect(StyleRuns.runs([tok("why", 0, 40, white), tok("?!", 42, 12, white)], lineHeight: 30) == [0..<2])
    // A mention or link inside a sentence stays in it; one ending the line is its own run.
    let blue = RGBA(88, 166, 255)
    #expect(StyleRuns.runs([tok("hey", 0, 40, white), tok("@junpark", 45, 100, blue), tok("are", 150, 35, white),
                            tok("you", 190, 35, white)], lineHeight: 30) == [0..<4])
    #expect(StyleRuns.runs([tok("thanks", 0, 60, white), tok("@junpark", 65, 100, blue)], lineHeight: 30) == [0..<1, 1..<2])
    // A header with the same colour on both sides of a badge is not merged across the badge's pill (solid).
    #expect(StyleRuns.runs([tok("Maya", 0, 60, red), tok("MOD", 70, 50, white, solid: true), tok("Today", 130, 60, grey)],
                           lineHeight: 30) == [0..<1, 2..<3])
    // Separate buttons on one OCR line split at the wide gap.
    #expect(StyleRuns.runs([tok("Reply", 0, 50, grey), tok("Share", 150, 50, grey)], lineHeight: 30) == [0..<1, 1..<2])
}

@Test func labelsAreWordsNextToOtherStyles() {
    let red = RGBA(240, 110, 100), grey = RGBA(150, 152, 158), white = RGBA(255, 255, 255), body = RGBA(220, 222, 225)
    func item(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: RGBA) -> LabelRule.Item {
        .init(rect: CGRect(x: x, y: y, width: w, height: h), text: text, color: c)
    }
    let chat = [
        item("Maya", 750, 210, 85, 32, red), item("MOD", 855, 214, 55, 22, white), item("Today at 8:12 PM", 930, 214, 190, 26, grey),
        item("ok who stayed up for the patch notes last night", 750, 255, 680, 30, body),
        item("Today", 1555, 145, 70, 24, grey),                               // a divider, alone on its row
        item("急上昇", 655, 465, 80, 28, grey), item("新着", 795, 465, 55, 28, grey), // tabs: same style
        // A name with an emoji between it and the timestamp; a timestamp ending its row is translated.
        item("Ollie", 750, 570, 70, 32, RGBA(194, 124, 255)), item("Today at 8:14 PM", 875, 574, 190, 26, grey),
        item("u/mayafox", 580, 570, 120, 26, white), item("5時間前", 720, 570, 80, 26, grey),
    ]
    #expect(LabelRule.labels(chat) == [0, 1, 7, 9])
}

@Test func inkClustersTellIconsFromLetters() {
    // A filled purple disc (an avatar) and two thin grey strokes (letters) on a dark line 24 px tall.
    var patch = RGBAImage(width: 80, height: 32, color: RGBA(15, 16, 18))
    for y in 4..<28 { for x in 4..<28 where (x - 16) * (x - 16) + (y - 16) * (y - 16) <= 144 { patch.set(x: x, y: y, RGBA(190, 120, 250)) } }
    for y in 8..<26 { for x in 40..<43 { patch.set(x: x, y: y, RGBA(150, 152, 158)); patch.set(x: x + 10, y: y, RGBA(150, 152, 158)) } }
    let m = TextEraser.mask(for: patch, textRect: PixelRect(x: 3, y: 3, width: 74, height: 26), dilation: 0)
    let c = TextEraser.clusters(m, in: patch, lineHeight: 26)
    #expect(c.map(\.minX) == [4, 40, 50])
    #expect(c.map(\.solid) == [true, false, false])
    #expect(c[1].color == RGBA(150, 152, 158))
}

@Test func wordTokenLeavesOutAnIconItsBoxTookIn() {
    let grey = RGBA(147, 154, 163), yellow = RGBA(249, 218, 86)
    func cl(_ x: Int, _ w: Int, _ c: RGBA, solid: Bool = false) -> InkCluster { InkCluster(minX: x, maxX: x + w, color: c, ink: 60, solid: solid) }
    // Vision's box for "Today" also covers the moon emoji in front of it.
    let today = StyleRuns.token(text: "Today", minX: 100, maxX: 200, clusters: [cl(100, 22, yellow), cl(130, 12, grey), cl(145, 12, grey),
                                                                              cl(160, 12, grey), cl(175, 12, grey), cl(188, 12, grey)], lineHeight: 30)
    #expect(today.minX == 130 && today.maxX == 200 && today.color == grey && !today.solid)
    let avatar = StyleRuns.token(text: "•", minX: 0, maxX: 40, clusters: [cl(2, 36, RGBA(190, 120, 250), solid: true)], lineHeight: 30)
    #expect(avatar.solid)
}
