import AppKit
import ImageIO
import MwoyeoCore

/// A still picture read and translated the way a lens does it: one frame through `RegionPipeline` and the shared
/// `TranslationService`, composited with `LensImage.composite`. The image window and the headless `--render` both run
/// this, so what the self-test measures is what "Translate Image…" shows.
final class StillTranslation: @unchecked Sendable {
    /// The longer side is scaled down to this many pixels before the text is read: OCR and erasing cost grows with the
    /// pixel count, and text in a larger picture is still legible at this size.
    static let maxSide = 4000

    struct Decoded {
        /// The pixels as the pipeline reads them (straight RGBA8, sRGB).
        let image: CGImage
        let rgba: RGBAImage
        /// Image pixels per point; the pipeline measures text in points.
        let scale: CGFloat
    }

    struct Unreadable: Error, CustomStringConvertible { let description: String }

    /// `data` as a still, nil-scale meaning the picture's own density (144 dpi and up reads as 2×, a Retina screenshot).
    static func decode(_ data: Data, scale: CGFloat? = nil, maxSide: Int = maxSide) throws -> Decoded {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw Unreadable(description: "This file is not a picture Mwoyeo can read.")
        }
        return try decode(decoded, scale: scale ?? density(of: src), maxSide: maxSide)
    }

    static func decode(url: URL, scale: CGFloat? = nil, maxSide: Int = maxSide) throws -> Decoded {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw Unreadable(description: "Can’t read \(url.lastPathComponent) as a picture.")
        }
        return try decode(decoded, scale: scale ?? density(of: src), maxSide: maxSide)
    }

    private static func decode(_ decoded: CGImage, scale: CGFloat, maxSide: Int) throws -> Decoded {
        var source = decoded
        let longer = max(source.width, source.height)
        if longer > maxSide, let small = shrunk(source, by: CGFloat(maxSide) / CGFloat(longer)) { source = small }
        guard let rgba = RGBAImage(cgImage: source), let image = rgba.cgImage else {
            throw Unreadable(description: "This picture could not be decoded.")
        }
        return Decoded(image: image, rgba: rgba, scale: scale)
    }

    private static func shrunk(_ image: CGImage, by f: CGFloat) -> CGImage? {
        let w = max(1, Int((CGFloat(image.width) * f).rounded())), h = max(1, Int((CGFloat(image.height) * f).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func density(of src: CGImageSource) -> CGFloat {
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        return (p?[kCGImagePropertyDPIWidth] as? Double ?? 72) >= 144 ? 2 : 1
    }

    private final class Latest: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: OverlaySnapshot?
        var value: OverlaySnapshot? { lock.withLock { snapshot } }
        func put(_ s: OverlaySnapshot) { lock.withLock { snapshot = s } }
    }

    let image: CGImage
    let scale: CGFloat
    let pipeline: RegionPipeline
    private let gray: GrayImage
    private let capture: CGRect
    private let held = Latest()
    private let lensApp: ReaderContext

    /// The newest snapshot: the blocks translated so far.
    var latest: OverlaySnapshot? { held.value }

    /// `onSnapshot` hears every snapshot as it is made (the window shows the picture filling in).
    init(_ d: Decoded, settings: AppSettings, translator: TranslationService, inpainter: Inpainter?, lensApp: ReaderContext = ReaderContext(),
         onSnapshot: (@Sendable (OverlaySnapshot) -> Void)? = nil) {
        image = d.image
        scale = d.scale
        capture = CGRect(x: 0, y: 0, width: CGFloat(d.image.width) / d.scale, height: CGFloat(d.image.height) / d.scale)
        gray = d.rgba.withBGRA { GrayImage(bgra: $0, width: d.rgba.width, height: d.rgba.height, bytesPerRow: d.rgba.width * 4, step: 4) }
        let held = held
        self.lensApp = lensApp
        pipeline = RegionPipeline(options: PipelineOptions(settings, lensApp: lensApp), capture: capture, translator: translator, inpainter: inpainter,
                                  onSnapshot: { held.put($0); onSnapshot?($0) })
    }

    /// Feeds the picture to the pipeline; again, it is a screen read again (a held subtitle).
    func ingest() async {
        await pipeline.ingest(CapturedFrame(image: image, gray: gray, grayStep: 4, scale: scale, rect: capture,
                                            time: ProcessInfo.processInfo.systemUptime))
    }

    func update(settings: AppSettings) async { await pipeline.update(options: PipelineOptions(settings, lensApp: lensApp)) }

    /// Waits until reading and translating are done and the snapshots stop changing, or `maxWait` seconds after `start`.
    /// `giveUpWhenPaused` is asked while the translation rests after a failure: true ends the wait (the failure will not pass).
    func settle(from start: Date, maxWait: Double, giveUpWhenPaused: (@Sendable () async -> Bool)? = nil) async throws {
        var lastChange = Date(), lastVersion = -1
        while Date().timeIntervalSince(start) < maxWait {
            try await Task.sleep(for: .milliseconds(200))
            let state = await pipeline.debugState()
            if let v = latest?.version, v != lastVersion { lastVersion = v; lastChange = Date() }
            if !state.busy, !state.paused, Date().timeIntervalSince(lastChange) > 0.6 { break }
            if state.paused, let giveUpWhenPaused, await giveUpWhenPaused() { break }
        }
    }

    /// The picture with `snapshot`'s translations drawn on it, or the original alone when `translated` is false.
    func composite(_ snapshot: OverlaySnapshot?, translated: Bool = true) -> CGImage? {
        let layers = translated ? (snapshot?.blocks ?? []).map { LensImage.Layer(frame: $0.frame, image: $0.image) } : []
        return LensImage.composite(frame: image, scale: scale, layers: layers)
    }
}

extension RGBAImage {
    /// Temporarily exposes the pixels as BGRA (the capture format) for the gray downsampler.
    func withBGRA<T>(_ body: (UnsafeRawPointer) -> T) -> T {
        var bgra = pixels
        for i in stride(from: 0, to: bgra.count, by: 4) { bgra.swapAt(i, i + 2) }
        return bgra.withUnsafeBytes { body($0.baseAddress!) }
    }
}
