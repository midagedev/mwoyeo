import CoreML
import Foundation
import MwoyeoCore

/// MI-GAN (Core ML) inpainting for text on textured backgrounds.
///
/// Model contract (tools/inpaint/BENCH.md): input `input` float32 [1, 4, S, S] = [mask - 0.5, R, G, B] with
/// RGB in [-1, 1] and zeroed inside the hole, mask 1 = keep / 0 = hole. Output `output` float32 [1, 3, S, S]
/// RGB ≈ [-1, 1] (clamp), a full-frame reconstruction that must be composited back over the known pixels.
///
/// The model is in memory only while it is used. Measured (lens-robust, 2026-10-18, M4 Pro, Debug build; `--capture-ui … inpaint-footprint`):
/// found but not loaded, or loaded and idle, it costs next to nothing (a process at 123-133 MB with 0.5 MB of GPU memory). The first fill
/// makes the GPU allocate its working set, 225 MB that stays for as long as the model is loaded (a picture with text over a gradient took a
/// render from 197 MB, the same picture with the model off, to 526 MB). So the model loads at the first fill, not at launch, and goes
/// `idleSeconds` after the last one, which gives the 225 MB back (263 MB to 31 MB in the check). A load costs about 0.06-0.1 s.
final class Inpainter: @unchecked Sendable {
    let side: Int
    private let url: URL
    private let lock = NSLock()
    /// Guarded by `lock`: the loaded model, when it was last used (`systemUptime`), the scheduled release, and whether loading failed
    /// (then every fill throws at once, instead of trying the load again each time).
    private var model: MLModel?
    private var lastUse: TimeInterval = 0
    private var release: DispatchWorkItem?
    private var unloadable = false
    /// Seconds after the last fill that the model stays loaded.
    var idleSeconds: TimeInterval = 60

    struct LoadFailed: Error {}

    /// Looks for the compiled model in the app bundle, then in Application Support. Does not load it (`MLModel`): that waits for the first fill.
    static func load() -> Inpainter? {
        let name = "MIGAN_512"
        var candidates: [URL] = []
        if let u = Bundle.main.url(forResource: name, withExtension: "mlmodelc") { candidates.append(u) }
        #if !MAS
        if let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            candidates.append(support.appendingPathComponent("Mwoyeo/Models/\(name).mlmodelc"))
        }
        #endif
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }.map { Inpainter(url: $0, side: 512) }
    }

    private init(url: URL, side: Int) {
        self.url = url
        self.side = side
    }

    /// Whether the model is in memory now (for the checks).
    var isLoaded: Bool { lock.withLock { model != nil } }

    /// The loaded model; loads it first if need be. Called with `lock` held.
    private func loadedModel() throws -> MLModel {
        if let model { return model }
        guard !unloadable else { throw LoadFailed() }
        let t = Trace.now
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU // measured fastest at 512 on M-series; `.all` was 4× slower
        guard let m = try? MLModel(contentsOf: url, configuration: config) else {
            unloadable = true
            throw LoadFailed()
        }
        Trace.count("inpaint.load")
        Trace.sample("inpaint.load.ms", (Trace.now - t) * 1000)
        model = m
        return m
    }

    /// After a fill: the model goes `idleSeconds` from now unless another fill comes first.
    private func scheduleRelease() {
        lock.withLock {
            lastUse = Trace.now
            release?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.releaseIfIdle() }
            release = item
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + idleSeconds, execute: item)
        }
    }

    private func releaseIfIdle() {
        lock.withLock {
            guard model != nil, Trace.now - lastUse >= idleSeconds - 0.01 else { return }
            model = nil
            release = nil
            Trace.count("inpaint.release")
        }
    }

    /// Fills `mask` (1 = erase, sized like `rect`) inside `rect` of `frame`, using the frame around it as context.
    /// Returns the repaired `rect` patch. Large rects are processed in overlapping model-sized tiles.
    func inpaint(frame: RGBAImage, rect: PixelRect, mask: [UInt8]) throws -> RGBAImage {
        lock.withLock { lastUse = Trace.now }   // a release already scheduled must not take the model between two tiles of this fill
        defer { scheduleRelease() }
        var patch = frame.cropped(to: rect)
        let s = side
        // Tile the rect with S×S windows centred on it; each window takes real frame pixels as context.
        let step = s * 3 / 4
        var ty = 0
        repeat {
            var tx = 0
            repeat {
                let tileW = min(step, rect.width - tx), tileH = min(step, rect.height - ty)
                let cx = rect.x + tx + tileW / 2, cy = rect.y + ty + tileH / 2
                let win = PixelRect(x: min(max(0, cx - s / 2), max(0, frame.width - s)),
                                    y: min(max(0, cy - s / 2), max(0, frame.height - s)), width: s, height: s)
                let only = PixelRect(x: rect.x + tx, y: rect.y + ty, width: tileW, height: tileH)
                #if !MAS
                FilmDump.emit("erase") { ["win": FilmDump.box(win), "only": FilmDump.box(only), "patch": FilmDump.box(rect)] }   // tools/film/DESIGN.md, H2
                #endif
                try run(window: win, frame: frame, rect: rect, mask: mask, into: &patch, only: only)
                tx += step
            } while tx < rect.width
            ty += step
        } while ty < rect.height
        return patch
    }

    /// Runs the model on one S×S window of the frame (padded with edge pixels if the frame is smaller)
    /// and writes reconstructed hole pixels that fall inside `only` into `patch`.
    ///
    /// In an autorelease pool of its own: Core ML's results are autoreleased, and a task on the pipeline's threads does not drain a pool at
    /// its end, so each fill left about 14 MB behind (20 fills took a process from 270 MB to 537 MB).
    private func run(window: PixelRect, frame: RGBAImage, rect: PixelRect, mask: [UInt8], into patch: inout RGBAImage,
                     only: PixelRect) throws {
        try autoreleasepool { try runPooled(window: window, frame: frame, rect: rect, mask: mask, into: &patch, only: only) }
    }

    private func runPooled(window: PixelRect, frame: RGBAImage, rect: PixelRect, mask: [UInt8], into patch: inout RGBAImage,
                           only: PixelRect) throws {
        let s = side
        let input = try MLMultiArray(shape: [1, 4, NSNumber(value: s), NSNumber(value: s)], dataType: .float32)
        let plane = s * s
        let ptr = input.dataPointer.bindMemory(to: Float.self, capacity: 4 * plane)

        @inline(__always) func isHole(_ fx: Int, _ fy: Int) -> Bool {
            let mx = fx - rect.x, my = fy - rect.y
            guard mx >= 0, my >= 0, mx < rect.width, my < rect.height else { return false }
            return mask[my * rect.width + mx] != 0
        }

        for y in 0..<s {
            let fy = min(max(window.y + y, 0), frame.height - 1)
            for x in 0..<s {
                let fx = min(max(window.x + x, 0), frame.width - 1)
                let i = y * s + x
                let hole = isHole(fx, fy)
                ptr[i] = hole ? -0.5 : 0.5
                if hole {
                    ptr[plane + i] = 0; ptr[2 * plane + i] = 0; ptr[3 * plane + i] = 0
                } else {
                    let c = frame.color(x: fx, y: fy)
                    ptr[plane + i] = Float(c.r) / 127.5 - 1
                    ptr[2 * plane + i] = Float(c.g) / 127.5 - 1
                    ptr[3 * plane + i] = Float(c.b) / 127.5 - 1
                }
            }
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)])
        let result: MLFeatureProvider = try lock.withLock { try loadedModel().prediction(from: provider) }
        guard let out = result.featureValue(for: "output")?.multiArrayValue else { return }
        let o = out.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
        // Output may be fp16 or fp32 depending on the compute unit; read through strides only for fp32.
        let isFloat32 = out.dataType == .float32

        @inline(__always) func value(_ c: Int, _ i: Int) -> UInt8 {
            let v: Float = isFloat32 ? o[c * plane + i] : out[[0, NSNumber(value: c), NSNumber(value: i / s), NSNumber(value: i % s)]].floatValue
            return UInt8(clamping: Int((min(max(v, -1), 1) * 127.5 + 127.5).rounded()))
        }

        for py in only.y..<(only.y + only.height) {
            for px in only.x..<(only.x + only.width) where isHole(px, py) {
                let wx = px - window.x, wy = py - window.y
                guard wx >= 0, wy >= 0, wx < s, wy < s else { continue }
                let i = wy * s + wx
                patch.set(x: px - rect.x, y: py - rect.y, RGBA(value(0, i), value(1, i), value(2, i)))
            }
        }
    }
}
