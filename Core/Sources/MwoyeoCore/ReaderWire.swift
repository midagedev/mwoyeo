import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import IOSurface

// The wire between the app and the two reader services (docs/design/recognition.md §4.2-4.3). The app sends a `ReadJob` (a
// small encoded value, plus the picture as an IOSurface); a service runs it to completion and answers with a `ReadReply`. Pure
// types and codecs: the Vision calls are in the services (`Shared/VisionExec.swift`), the transport is `App/Reader/ReaderConnection.swift`.

// MARK: Roles and kinds

/// Which service. The role is the service's identity: its bundle id ends in `.reader.<role>` and its Info.plist names it.
public enum ReaderRole: String, Codable, Sendable, CaseIterable {
    /// `VNRecognizeTextRequest` revision 3, revision 2 and `.fast`.
    case lines
    /// `RecognizeDocumentsRequest`, and `.fast` as the stand-in that needs no Neural Engine compile.
    case docs

    /// The Info.plist key of a service that names its role (one source directory builds both services).
    public static let infoKey = "MwoyeoReaderRole"

    /// `<app id>.reader.<role>`. Derived from the app's bundle id, so a re-identified copy talks to its own services.
    public func serviceName(appID: String) -> String { "\(appID).reader.\(rawValue)" }

    /// The service of this role runs jobs of `kind`.
    public func serves(_ kind: ReadKind) -> Bool {
        switch self {
        case .lines: [ReadKind.rev3, .rev2, .fast, .warmLines].contains(kind)
        case .docs: [ReadKind.doc, .fast, .warmDoc].contains(kind)
        }
    }

    /// The service that runs `kind` unless the caller picks another (`.fast` is on both).
    public static func home(of kind: ReadKind) -> ReaderRole {
        switch kind {
        case .rev3, .rev2, .fast, .warmLines: .lines
        case .doc, .warmDoc: .docs
        }
    }
}

public enum ReadKind: String, Codable, Sendable, CaseIterable {
    /// Accurate, revision 3, through the Objective-C request.
    case rev3
    /// Accurate, revision 2.
    case rev2
    /// The fast recognizer (Latin scripts only).
    case fast
    /// `RecognizeDocumentsRequest`: the reply carries paragraphs.
    case doc
    /// Warm-up: revision 3 on the drawn probe picture (`VisionExec.probePicture`), the language detected. No picture travels.
    case warmLines
    /// Warm-up: the document model on the probe picture, for the job's languages. No picture travels.
    case warmDoc

    public var isWarmUp: Bool { self == .warmLines || self == .warmDoc }
    public var needsPicture: Bool { !isWarmUp }
}

// MARK: Picture, job, reply

public enum ReaderPixelFormat: String, Codable, Sendable {
    /// 8-bit B, G, R, premultiplied A (`kCVPixelFormatType_32BGRA`): what ScreenCaptureKit's frames are.
    case bgra
    /// 8-bit R, G, B, premultiplied A (`kCVPixelFormatType_32RGBA`): what a decoded PNG becomes (`RGBAImage`).
    case rgba
}

/// The picture of a job, described. Its pixels travel beside the job: an IOSurface, or bytes. Always sRGB, 8 bits a component.
public struct ReadImage: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var format: ReaderPixelFormat
    /// The row stride of pixels sent as bytes; a surface has its own.
    public var bytesPerRow: Int

    public init(width: Int, height: Int, format: ReaderPixelFormat, bytesPerRow: Int) {
        self.width = width; self.height = height; self.format = format; self.bytesPerRow = bytesPerRow
    }
}

public struct ReadJob: Codable, Sendable, Equatable {
    /// The client's sequence number, echoed in the reply.
    public var id: UInt64
    public var kind: ReadKind
    /// Nil for the warm-up kinds.
    public var image: ReadImage?
    /// In image pixels, origin top left; nil reads the whole picture.
    public var roi: CGRect?
    /// Lines kinds: Vision's own identifiers ("en-US"), already matched to what the recognizer reads; empty detects the language.
    public var languages: [String]
    /// Document kinds: the languages as the app holds them (Codable keeps their components exactly); empty detects.
    public var documentLanguages: [Locale.Language]
    public var customWords: [String]
    /// What `MWOYEO_FAKE_READER` asks of this job (the service's environment is not the client's, so the job carries it).
    public var fake: [ReaderFakeAction]

    public init(id: UInt64 = 0, kind: ReadKind, image: ReadImage? = nil, roi: CGRect? = nil, languages: [String] = [],
                documentLanguages: [Locale.Language] = [], customWords: [String] = [], fake: [ReaderFakeAction] = []) {
        self.id = id; self.kind = kind; self.image = image; self.roi = roi
        self.languages = languages; self.documentLanguages = documentLanguages; self.customWords = customWords; self.fake = fake
    }
}

/// A word of a line: its box in image pixels and its place in the line's text, as UTF-8 offsets.
public struct ReadWord: Sendable, Equatable {
    public var rect: CGRect
    public var start: Int
    public var end: Int

    public init(rect: CGRect, start: Int, end: Int) { self.rect = rect; self.start = start; self.end = end }
}

/// A recognized line in image pixels, top-left origin.
///
/// On the wire the numbers of a line (its rect, then six per word: rect, start, end) travel as one blob of raw Doubles beside its
/// text, not as nested values: a page of 44 lines and 520 words took 3.0 ms to encode and 5.4 ms to decode as plain `Codable`
/// (measured 2026-10-18, `--reader-check hop`), more than everything else on the XPC hop together. Doubles keep every bit.
public struct ReadLine: Codable, Sendable, Equatable {
    public var rect: CGRect
    public var text: String
    public var words: [ReadWord]

    public init(rect: CGRect, text: String, words: [ReadWord] = []) { self.rect = rect; self.text = text; self.words = words }

    /// Every rect moved `dx` pixels to the right (`MWOYEO_FAKE_READER=shift1`, the mutation check of the equivalence gate).
    public func shifted(by dx: CGFloat) -> ReadLine {
        ReadLine(rect: rect.offsetBy(dx: dx, dy: 0), text: text,
                 words: words.map { ReadWord(rect: $0.rect.offsetBy(dx: dx, dy: 0), start: $0.start, end: $0.end) })
    }

    private enum CodingKeys: String, CodingKey { case text, numbers }

    public func encode(to encoder: Encoder) throws {
        var numbers = [Double]()
        numbers.reserveCapacity(4 + 6 * words.count)
        numbers += [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]
        for w in words {
            numbers += [w.rect.origin.x, w.rect.origin.y, w.rect.size.width, w.rect.size.height, Double(w.start), Double(w.end)]
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(numbers.withUnsafeBytes { Data($0) }, forKey: .numbers)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        let blob = try c.decode(Data.self, forKey: .numbers)
        let count = blob.count / MemoryLayout<Double>.size
        guard blob.count % MemoryLayout<Double>.size == 0, count >= 4, (count - 4) % 6 == 0 else {
            throw DecodingError.dataCorruptedError(forKey: .numbers, in: c, debugDescription: "a line carries 4 numbers and 6 per word, not \(count)")
        }
        var numbers = [Double](repeating: 0, count: count)
        _ = numbers.withUnsafeMutableBytes { blob.copyBytes(to: $0) }
        rect = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        words = stride(from: 4, to: count, by: 6).map {
            ReadWord(rect: CGRect(x: numbers[$0], y: numbers[$0 + 1], width: numbers[$0 + 2], height: numbers[$0 + 3]),
                     start: Int(numbers[$0 + 4]), end: Int(numbers[$0 + 5]))
        }
    }
}

/// Why a job did not answer. `description` is the original error's, verbatim: `OCRHealth.programsNotReady` classifies by it.
public enum ReadFailure: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    /// The Neural Engine programs are not ready (e5rt Code 13, `OCRHealth.programsNotReady`).
    case programsNotReady(String)
    /// The compiler service failed to compile the model (`e5rt_e5_compiler_compile`, Code 11, `OCRHealth.compileFailed`). Seen on
    /// a Mac short of disk space: the compile preallocates 2.4 GB of temp space, fails, and caches nothing (2026-10-19).
    case compileFailed(String)
    /// Vision threw something else.
    case failed(String)
    /// The service could not run the job as described (wrong role, missing or mismatched picture, undecodable).
    case badJob(String)
    /// The service stopped while it had the job (client side: the connection was interrupted).
    case interrupted
    /// No service answered (client side: the connection is invalid, the bundle has no such service).
    case unavailable(String)

    public var description: String {
        switch self {
        case let .programsNotReady(d), let .compileFailed(d), let .failed(d): d
        case let .badJob(m): "bad reader job: \(m)"
        case .interrupted: "the reader service stopped while it was reading"
        case let .unavailable(m): "the reader service is unavailable: \(m)"
        }
    }

    public static func from(_ error: Error) -> ReadFailure {
        if let failure = error as? ReadFailure { return failure }
        let d = String(describing: error)
        switch (OCRHealth.compileFailed(description: d), OCRHealth.programsNotReady(description: d)) {
        case (true, _): return .compileFailed(d)
        case (_, true): return .programsNotReady(d)
        default: return .failed(d)
        }
    }
}

public struct ReadReply: Codable, Sendable, Equatable {
    public var id: UInt64
    public var role: ReaderRole
    /// The service's pid: the client records it (a recycle that cannot ask kills it).
    public var pid: Int32
    /// Line kinds.
    public var lines: [ReadLine]
    /// Document kinds: the lines of each paragraph.
    public var paragraphs: [[ReadLine]]
    /// From the job's arrival at the worker to its answer (a fake `slow` included).
    public var ms: Double
    /// `phys_footprint` of the service after the job, in bytes.
    public var footprint: UInt64
    public var error: ReadFailure?
    /// Lines Vision found that the read left out for a confidence under the least it keeps (`VisionExec.minConfidence`): the service's
    /// own count, told to the host's stats.
    public var lowConfidence: Int

    public init(id: UInt64, role: ReaderRole, pid: Int32, lines: [ReadLine] = [], paragraphs: [[ReadLine]] = [], ms: Double = 0,
                footprint: UInt64 = 0, error: ReadFailure? = nil, lowConfidence: Int = 0) {
        self.id = id; self.role = role; self.pid = pid; self.lines = lines; self.paragraphs = paragraphs
        self.ms = ms; self.footprint = footprint; self.error = error; self.lowConfidence = lowConfidence
    }
}

public struct ReaderHello: Codable, Sendable, Equatable {
    public var role: ReaderRole
    public var pid: Int32
    public var footprint: UInt64
    public var version: Int

    public init(role: ReaderRole, pid: Int32, footprint: UInt64, version: Int = ReaderWire.version) {
        self.role = role; self.pid = pid; self.footprint = footprint; self.version = version
    }
}

/// What a connection tells its owner (the host, in R3). Interruption and invalidation are events, not errors of a read.
public enum ReaderConnectionEvent: Sendable, Equatable {
    /// A service answered with a pid this connection had not seen: a first start, or a relaunch after an interruption.
    case connected(ReaderRole, pid: Int32)
    /// The service died or exited; the connection stays and the next job relaunches the service.
    case interrupted(ReaderRole, pid: Int32?)
    /// The connection is gone (no such service, or invalidated); the next job makes a new one.
    case invalidated(ReaderRole)
}

// MARK: The protocol

/// The service's side of the connection. Every method answers through its reply, once. One job runs at a time, to completion;
/// a second queues behind it (the host never sends one: invariant I2).
@objc public protocol ReaderXPC {
    /// `job` is an encoded `ReadJob` (`ReaderWire.encode`); the picture comes as `surface` or `bytes` (neither for a warm-up
    /// job). The reply is an encoded `ReadReply`, also for a failure.
    func read(_ job: Data, surface: IOSurface?, bytes: Data?, reply: @escaping (Data) -> Void)
    /// An encoded `ReaderHello`.
    func hello(reply: @escaping (Data) -> Void)
    /// Queues an exit behind the jobs already queued: replies with the pid when they are done, then exits.
    func exitWhenIdle(reply: @escaping (Int32) -> Void)
}

// MARK: Coding

public enum ReaderWire {
    public static let version = 1

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try PropertyListDecoder().decode(type, from: data)
    }

    /// The interface both sides use: the surface argument may be an IOSurface.
    public static func interface() -> NSXPCInterface {
        let interface = NSXPCInterface(with: ReaderXPC.self)
        let classes = NSSet(array: [IOSurface.self]) as! Set<AnyHashable>
        interface.setClasses(classes, for: #selector(ReaderXPC.read(_:surface:bytes:reply:)), argumentIndex: 1, ofReply: false)
        return interface
    }

    /// `phys_footprint` of this process: the number Activity Monitor calls Memory, and `footprint(1)` reports.
    public static func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

// MARK: Fakes (gates)

/// What `MWOYEO_FAKE_READER` asks of one job. The service obeys the job and keeps no state of its own, so a restarted service
/// does not forget (or repeat) a fault: the client counts.
public enum ReaderFakeAction: Codable, Sendable, Equatable {
    /// Sleeps `ms`, then answers.
    case slow(ms: Int)
    /// Fails as a Mac does while its programs are not ready (Code 13).
    case e5rt
    /// Fails as a Mac short of disk space does: the model does not compile (Code 11).
    case nospace
    /// `exit(1)` on this job.
    case crash
    /// Moves every rect 1 px to the right.
    case shift1

    /// What a Mac logs while its programs are not ready; `OCRHealth.programsNotReady` knows it by "e5rtError".
    public static let e5rtDescription = "e5rtError(\"e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed\", 13)"
    /// What the same Mac logs when the compile fails (`OCRHealth.compileFailed` knows it by "e5rt_e5_compiler_compile").
    public static let nospaceDescription = "e5rtError(\"e5rt_e5_compiler_compile call failed\", 11)"

    /// What the service answers with instead of reading, nil for the actions that only change the timing or the pixels.
    public var failure: ReadFailure? {
        switch self {
        case .e5rt: .programsNotReady(Self.e5rtDescription)
        case .nospace: .compileFailed(Self.nospaceDescription)
        case .slow, .crash, .shift1: nil
        }
    }
}

/// `MWOYEO_FAKE_READER=<mode>[,<mode>…]`, read by the client (`ReaderFakePlan.environment`, App/Reader/ReaderConnection.swift):
/// - `docs-slow:<ms>`, `lines-slow:<ms>`: every job of that role sleeps, then answers;
/// - `lines-e5rt[:<n>]`, `docs-e5rt[:<n>]`: the first n (20) jobs of its newest model (`rev3`/`warmLines`, `doc`/`warmDoc`) fail with Code 13;
/// - `lines-nospace[:<n>]`, `docs-nospace[:<n>]`: the same jobs fail as a Mac short of disk space does (the compile fails, Code 11);
///   a role holds one of the two modes (the last one named wins);
/// - `crash`, `crash:lines`, `crash:docs`: the next job (of that role) makes its service exit(1), once;
/// - `shift1`: every rect of every reply moves 1 px (the mutation of the equivalence gate).
public final class ReaderFakePlan: @unchecked Sendable {
    private let lock = NSLock()
    private var slow: [ReaderRole: Int] = [:]
    private var failing: [ReaderRole: (action: ReaderFakeAction, left: Int)] = [:]
    private var crashArmed = false
    private var crashRole: ReaderRole?
    private var shift = false
    /// Modes of the spec this plan does not know (a typo would otherwise fake nothing, silently).
    public let unrecognized: [String]

    public init(_ spec: String?) {
        var unknown: [String] = []
        for raw in (spec ?? "").split(separator: ",") {
            let mode = raw.trimmingCharacters(in: .whitespaces)
            let parts = mode.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : nil
            switch parts.first ?? "" {
            case "docs-slow", "lines-slow":
                guard let ms = argument.flatMap({ Int($0) }) else { unknown.append(mode); continue }
                slow[parts[0].hasPrefix("docs") ? .docs : .lines] = ms
            case "docs-e5rt", "lines-e5rt", "docs-nospace", "lines-nospace":
                guard argument == nil || Int(argument ?? "") != nil else { unknown.append(mode); continue }
                failing[parts[0].hasPrefix("docs") ? .docs : .lines] =
                    (parts[0].hasSuffix("nospace") ? .nospace : .e5rt, argument.flatMap { Int($0) } ?? 20)
            case "crash":
                guard argument == nil || ReaderRole(rawValue: argument ?? "") != nil else { unknown.append(mode); continue }
                crashArmed = true
                crashRole = argument.flatMap { ReaderRole(rawValue: $0) }
            case "shift1" where argument == nil:
                shift = true
            default:
                unknown.append(mode)
            }
        }
        unrecognized = unknown
    }

    /// The actions for the next job of `role` and `kind`; counts down what is counted.
    public func actions(role: ReaderRole, kind: ReadKind) -> [ReaderFakeAction] {
        lock.withLock {
            var out: [ReaderFakeAction] = []
            if let ms = slow[role] { out.append(.slow(ms: ms)) }
            let newest: [ReadKind] = role == .lines ? [.rev3, .warmLines] : [.doc, .warmDoc]
            if newest.contains(kind), let fail = failing[role], fail.left > 0 {
                failing[role] = (fail.action, fail.left - 1)
                out.append(fail.action)
            }
            if crashArmed, crashRole == nil || crashRole == role {
                crashArmed = false
                out.append(.crash)
            }
            if shift { out.append(.shift1) }
            return out
        }
    }
}

// MARK: Pictures

/// Packs a picture into an IOSurface for a job, and turns the surface (or bytes) back into the CGImage Vision reads. Both formats
/// are sRGB with premultiplied alpha, the layouts the app's own pictures have (`RegionCapturer.makeFrame`, `RGBAImage.cgImage`),
/// so the CGImage the service builds is the one the app would have read in its own process.
public enum ReaderPixels {
    public static func fourCC(_ format: ReaderPixelFormat) -> OSType {
        switch format {
        case .bgra: kCVPixelFormatType_32BGRA
        case .rgba: kCVPixelFormatType_32RGBA
        }
    }

    static func bitmapInfo(_ format: ReaderPixelFormat) -> CGBitmapInfo {
        switch format {
        case .bgra: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        case .rgba: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
    }

    /// The format of a CGImage that already has one of the two layouts exactly, else nil.
    static func nativeFormat(of image: CGImage) -> ReaderPixelFormat? {
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.decode == nil,
              image.colorSpace?.name == CGColorSpace.sRGB else { return nil }
        let alpha = image.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue
        let order = image.bitmapInfo.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        if alpha == CGImageAlphaInfo.premultipliedFirst.rawValue, order == CGBitmapInfo.byteOrder32Little.rawValue { return .bgra }
        if alpha == CGImageAlphaInfo.premultipliedLast.rawValue, order == 0 || order == CGBitmapInfo.byteOrderDefault.rawValue { return .rgba }
        return nil
    }

    /// An IOSurface holding `image`. A picture in one of the two layouts is copied row by row; any other is drawn into sRGB RGBA
    /// (the colour conversion then happens here, not in the service).
    public static func surface(from image: CGImage) -> (surface: IOSurface, image: ReadImage)? {
        let native = nativeFormat(of: image)
        let format = native ?? .rgba
        guard let surface = IOSurface(properties: [.width: image.width, .height: image.height, .pixelFormat: Int(fourCC(format)),
                                                   .bytesPerElement: 4]) else { return nil }
        guard surface.lock(options: [], seed: nil) == kIOReturnSuccess else { return nil }
        defer { surface.unlock(options: [], seed: nil) }
        let base = surface.baseAddress
        let stride = surface.bytesPerRow
        if native != nil, let data = image.dataProvider?.data, let source = CFDataGetBytePtr(data),
           CFDataGetLength(data) >= image.bytesPerRow * (image.height - 1) + image.width * 4 {
            let rowBytes = image.width * 4
            for y in 0..<image.height { memcpy(base + y * stride, source + y * image.bytesPerRow, rowBytes) }
        } else {
            guard let context = CGContext(data: base, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: stride,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo(.rgba).rawValue) else { return nil }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (surface, ReadImage(width: image.width, height: image.height, format: format, bytesPerRow: stride))
    }

    /// The IOSurface behind a pixel buffer, as ScreenCaptureKit hands frames out (BGRA, IOSurface-backed): no copy. Nil if the
    /// buffer has no surface or another pixel format.
    public static func surface(of pixelBuffer: CVPixelBuffer) -> (surface: IOSurface, image: ReadImage)? {
        guard let ref = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return nil }
        let surface = unsafeBitCast(ref, to: IOSurface.self)
        let format: ReaderPixelFormat
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_32BGRA: format = .bgra
        case kCVPixelFormatType_32RGBA: format = .rgba
        default: return nil
        }
        return (surface, ReadImage(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer), format: format,
                                   bytesPerRow: surface.bytesPerRow))
    }

    /// The surface's pixels as a CGImage, without a copy: the surface stays read-locked until the image is released.
    public static func cgImage(surface: IOSurface, as image: ReadImage) -> CGImage? {
        guard surface.width == image.width, surface.height == image.height, surface.pixelFormat == fourCC(image.format),
              let hold = SurfaceHold(surface) else { return nil }
        let size = surface.bytesPerRow * surface.height
        let info = Unmanaged.passRetained(hold).toOpaque()
        guard let provider = CGDataProvider(dataInfo: info, data: surface.baseAddress, size: size, releaseData: { info, _, _ in
            if let info { Unmanaged<SurfaceHold>.fromOpaque(info).release() }
        }) else {
            Unmanaged<SurfaceHold>.fromOpaque(info).release()
            return nil
        }
        return makeImage(image, bytesPerRow: surface.bytesPerRow, provider: provider)
    }

    /// Pixels that travelled as bytes.
    public static func cgImage(bytes: Data, as image: ReadImage) -> CGImage? {
        guard image.bytesPerRow >= image.width * 4, bytes.count >= image.bytesPerRow * image.height,
              let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return makeImage(image, bytesPerRow: image.bytesPerRow, provider: provider)
    }

    private static func makeImage(_ image: ReadImage, bytesPerRow: Int, provider: CGDataProvider) -> CGImage? {
        CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo(image.format), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// A read lock on a surface for as long as a CGImage over its memory lives.
    private final class SurfaceHold {
        let surface: IOSurface

        init?(_ surface: IOSurface) {
            guard surface.lock(options: .readOnly, seed: nil) == kIOReturnSuccess else { return nil }
            self.surface = surface
        }

        deinit { surface.unlock(options: .readOnly, seed: nil) }
    }
}
