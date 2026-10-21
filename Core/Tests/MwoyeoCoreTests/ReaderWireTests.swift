import CoreGraphics
import CoreVideo
import Foundation
import IOSurface
import Testing
@testable import MwoyeoCore

@Suite struct ReaderWireTests {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try ReaderWire.decode(T.self, from: ReaderWire.encode(value))
    }

    private let line = ReadLine(rect: CGRect(x: 12.25, y: 30.0625, width: 400.5, height: 18.125), text: "Hello 世界 e\u{301}",
                                words: [ReadWord(rect: CGRect(x: 12.25, y: 30.0625, width: 40, height: 18.125), start: 0, end: 5),
                                        ReadWord(rect: CGRect(x: 60, y: 30.0625, width: 20, height: 18.125), start: 6, end: 9)])

    @Test func aJobSurvivesTheWireWithEveryField() throws {
        for kind in ReadKind.allCases {
            let job = ReadJob(id: 41, kind: kind, image: ReadImage(width: 1634, height: 2000, format: .bgra, bytesPerRow: 6592),
                              roi: CGRect(x: 0.5, y: 10, width: 300.25, height: 20), languages: ["en-US", "zh-Hans"],
                              documentLanguages: [Locale.Language(identifier: "ja"), Locale.Language(identifier: "zh-Hans")],
                              customWords: ["Mwoyeo", "co-op"], fake: [.slow(ms: 250), .e5rt, .crash, .shift1])
            #expect(try roundTrip(job) == job)
        }
        // No picture and no region: a warm-up job.
        #expect(try roundTrip(ReadJob(kind: .warmLines)) == ReadJob(kind: .warmLines))
    }

    @Test func aReplyKeepsItsRectsToTheBit() throws {
        let reply = ReadReply(id: 7, role: .docs, pid: 4242, lines: [line], paragraphs: [[line, line], [line]], ms: 343.5,
                              footprint: 91 << 20, error: nil)
        let back = try roundTrip(reply)
        #expect(back == reply)
        // Exact to the bit, not close: the equivalence gate allows a delta of 0 px.
        #expect(back.lines[0].rect.origin.y.bitPattern == line.rect.origin.y.bitPattern)
        #expect(back.paragraphs[1][0].words[1].rect == line.words[1].rect)
        #expect(String(back.lines[0].text.utf8.prefix(back.lines[0].words[1].end))!.hasSuffix("世"))
    }

    @Test func aReplyCarriesItsLowConfidenceCount() throws {
        let reply = ReadReply(id: 8, role: .lines, pid: 4242, lines: [line], ms: 1, lowConfidence: 4)
        #expect(try roundTrip(reply).lowConfidence == 4)
        #expect(ReadReply(id: 9, role: .lines, pid: 1).lowConfidence == 0, "none unless the service says so")
    }

    @Test func aLineWithManyWordsAndOddNumbersKeepsEveryBit() throws {
        // The numbers travel as raw Doubles: negative zero, tiny and huge values, and a line with no words, all come back to the bit.
        let odd = [CGRect(x: -0.0, y: 5e-324, width: 1.7976931348623157e308, height: 0.1 + 0.2),
                   CGRect(x: 1.0 / 3.0, y: -12345.678901234567, width: .pi, height: 0)]
        let line = ReadLine(rect: odd[0], text: "a\u{0}b\n\t", words: (0..<500).map { ReadWord(rect: odd[$0 % 2], start: $0, end: $0 + 3) })
        let back = try roundTrip(line)
        #expect(back == line)
        #expect(back.rect.origin.x.bitPattern == (-0.0).bitPattern)
        #expect(back.words.map(\.rect.size.height.bitPattern) == line.words.map(\.rect.size.height.bitPattern))
        #expect(try roundTrip(ReadLine(rect: odd[1], text: "")) == ReadLine(rect: odd[1], text: ""))
    }

    @Test func aLineWhoseNumbersAreTheWrongLengthIsRefused() throws {
        struct Raw: Codable { var text: String; var numbers: Data }
        for count in [0, 3, 5, 9, 11] {
            let blob = try ReaderWire.encode(Raw(text: "x", numbers: Data(count: count * 8)))
            #expect(throws: DecodingError.self) { try ReaderWire.decode(ReadLine.self, from: blob) }
        }
        let torn = try ReaderWire.encode(Raw(text: "x", numbers: Data(count: 4 * 8 + 3)))
        #expect(throws: DecodingError.self) { try ReaderWire.decode(ReadLine.self, from: torn) }
        let fine = try ReaderWire.encode(Raw(text: "x", numbers: Data(count: 10 * 8)))
        #expect(try ReaderWire.decode(ReadLine.self, from: fine).words.count == 1)
    }

    @Test func everyFailureSurvivesTheWire() throws {
        let failures: [ReadFailure] = [.programsNotReady(ReaderFakeAction.e5rtDescription), .failed("nilError"), .badJob("no picture"),
                                       .interrupted, .unavailable("failed at lookup")]
        for failure in failures {
            let reply = ReadReply(id: 1, role: .lines, pid: 1, error: failure)
            #expect(try roundTrip(reply).error == failure)
        }
    }

    @Test func aRectOutsideThePictureTravels() throws {
        // The facade skips a region with no pixel, but the wire must not choke on the numbers that describe one.
        let job = ReadJob(kind: .rev3, roi: CGRect(x: 4000, y: 4000, width: 40, height: 0.3))
        #expect(try roundTrip(job) == job)
        #expect(try roundTrip(ReadJob(kind: .doc, roi: .infinite)).roi == .infinite)
    }

    @Test func documentLanguagesComeBackEqualNotMerelySimilar() throws {
        // `Locale.Language(identifier: "en")` and its maximal form read alike but are not equal; the document request gets the
        // value the app built, so the job carries the components, not an identifier string.
        let ids = ["en", "ja", "ko", "zh", "zh-Hans", "zh-Hant", "pt-BR", "en-GB", "sr-Latn", "yue-Hans"]
        let job = ReadJob(kind: .doc, documentLanguages: ids.map { Locale.Language(identifier: $0) })
        let back = try roundTrip(job)
        #expect(back.documentLanguages == ids.map { Locale.Language(identifier: $0) })
        #expect(back.documentLanguages.map(\.maximalIdentifier) == ids.map { Locale.Language(identifier: $0).maximalIdentifier })
        #expect(back.documentLanguages[0] != Locale.Language(identifier: Locale.Language(identifier: "en").maximalIdentifier))
    }

    @Test func eachRoleServesItsKindsAndFastIsOnBoth() {
        #expect(ReadKind.allCases.filter { ReaderRole.lines.serves($0) } == [.rev3, .rev2, .fast, .warmLines])
        #expect(ReadKind.allCases.filter { ReaderRole.docs.serves($0) } == [.fast, .doc, .warmDoc])
        for kind in ReadKind.allCases { #expect(ReaderRole.home(of: kind).serves(kind)) }
        #expect(ReaderRole.docs.serviceName(appID: "dev.midagedev.mwoyeo") == "dev.midagedev.mwoyeo.reader.docs")
        #expect(ReaderRole.lines.serviceName(appID: "x.y.copy") == "x.y.copy.reader.lines")
    }

    @Test func aFailureKeepsTheTextTheHealthRulesClassifyBy() {
        #expect(OCRHealth.programsNotReady(ReadFailure.programsNotReady(ReaderFakeAction.e5rtDescription)))
        #expect(!OCRHealth.programsNotReady(ReadFailure.failed("nilError")))
        #expect(OCRHealth.passFailureIsTransient(ReadFailure.failed("nilError")))
        // A thrown error is typed from the text its description carries, and stays one when typed again.
        struct Thrown: Error, CustomStringConvertible { let description: String }
        #expect(ReadFailure.from(Thrown(description: "e5rtError(\"call failed\", 13)")) == .programsNotReady("e5rtError(\"call failed\", 13)"))
        #expect(ReadFailure.from(Thrown(description: "nilError")) == .failed("nilError"))
        #expect(ReadFailure.from(ReadFailure.interrupted) == .interrupted)
        #expect(!OCRHealth.programsNotReady(ReadFailure.interrupted))
    }

    // MARK: Fakes

    @Test func fakeSlowAndShiftApplyToEveryJobOfTheirRole() {
        let plan = ReaderFakePlan("docs-slow:5000,shift1")
        #expect(plan.actions(role: .docs, kind: .doc) == [.slow(ms: 5000), .shift1])
        #expect(plan.actions(role: .docs, kind: .fast) == [.slow(ms: 5000), .shift1])
        #expect(plan.actions(role: .lines, kind: .rev3) == [.shift1])
        #expect(ReaderFakePlan("lines-slow:90").actions(role: .lines, kind: .rev2) == [.slow(ms: 90)])
        #expect(ReaderFakePlan(nil).actions(role: .lines, kind: .rev3) == [])
        #expect(ReaderFakePlan("").unrecognized == [])
    }

    @Test func fakeE5rtFailsTheFirstNJobsOfTheNewestModelOnly() {
        let plan = ReaderFakePlan("lines-e5rt:2")
        #expect(plan.actions(role: .lines, kind: .rev2) == [])
        #expect(plan.actions(role: .lines, kind: .fast) == [])
        #expect(plan.actions(role: .docs, kind: .doc) == [])
        #expect(plan.actions(role: .lines, kind: .rev3) == [.e5rt])
        #expect(plan.actions(role: .lines, kind: .warmLines) == [.e5rt])
        #expect(plan.actions(role: .lines, kind: .rev3) == [])
        // The default is 20, as `MWOYEO_FAKE_OCR=e5rt`.
        let all = ReaderFakePlan("lines-e5rt")
        #expect((0..<25).filter { _ in !all.actions(role: .lines, kind: .rev3).isEmpty }.count == 20)
    }

    @Test func fakeCrashFiresOnceOnTheNextJob() {
        let any = ReaderFakePlan("crash")
        #expect(any.actions(role: .docs, kind: .doc) == [.crash])
        #expect(any.actions(role: .docs, kind: .doc) == [])
        let docs = ReaderFakePlan("crash:docs")
        #expect(docs.actions(role: .lines, kind: .rev3) == [])
        #expect(docs.actions(role: .docs, kind: .doc) == [.crash])
        #expect(docs.actions(role: .docs, kind: .doc) == [])
    }

    @Test func aMistypedFakeIsReportedNotIgnored() {
        let plan = ReaderFakePlan("shift1,docs-slow:fast,lines-e5rt:x,crash:gpu,shift2,shift1:3")
        #expect(plan.unrecognized == ["docs-slow:fast", "lines-e5rt:x", "crash:gpu", "shift2", "shift1:3"])
        #expect(plan.actions(role: .docs, kind: .doc) == [.shift1])
    }

    // MARK: Pictures

    /// A w×h picture whose bytes are known (a ramp the alpha is 255 on, so premultiplied equals straight).
    private func picture(width: Int, height: Int, format: ReaderPixelFormat, bytesPerRow: Int? = nil) -> (CGImage, [UInt8], Int) {
        let stride = bytesPerRow ?? width * 4
        var bytes = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height { for x in 0..<width {
            let i = y * stride + x * 4
            bytes[i] = UInt8((x * 37 + y * 11) & 255); bytes[i + 1] = UInt8((x * 5 + y * 71) & 255); bytes[i + 2] = UInt8((x * 13 + y * 3) & 255); bytes[i + 3] = 255
        } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: ReaderPixels.bitmapInfo(format), provider: provider,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return (image, bytes, stride)
    }

    private func rows(_ image: CGImage) -> [[UInt8]] {
        let data = image.dataProvider!.data!
        let base = CFDataGetBytePtr(data)!
        return (0..<image.height).map { y in Array(UnsafeBufferPointer(start: base + y * image.bytesPerRow, count: image.width * 4)) }
    }

    @Test(arguments: [ReaderPixelFormat.bgra, .rgba]) func aPictureComesBackFromItsSurfaceByteForByte(format: ReaderPixelFormat) throws {
        // 61 px wide: the surface pads its rows, so the strides differ.
        let (source, _, _) = picture(width: 61, height: 17, format: format, bytesPerRow: 61 * 4 + 12)
        let packed = try #require(ReaderPixels.surface(from: source))
        #expect(packed.image.format == format)
        #expect(packed.image.width == 61 && packed.image.height == 17)
        let back = try #require(ReaderPixels.cgImage(surface: packed.surface, as: packed.image))
        #expect(rows(back) == rows(source))
        #expect(back.bitmapInfo == source.bitmapInfo)
        #expect(back.colorSpace?.name == CGColorSpace.sRGB)
    }

    @Test func aPictureComesBackFromBytesToo() throws {
        let (source, bytes, stride) = picture(width: 9, height: 4, format: .rgba)
        let back = try #require(ReaderPixels.cgImage(bytes: Data(bytes), as: ReadImage(width: 9, height: 4, format: .rgba, bytesPerRow: stride)))
        #expect(rows(back) == rows(source))
        // Too few bytes for the stated size is refused, not read past.
        #expect(ReaderPixels.cgImage(bytes: Data(bytes.dropLast(5)), as: ReadImage(width: 9, height: 4, format: .rgba, bytesPerRow: stride)) == nil)
    }

    @Test func aPictureInAnotherLayoutIsDrawnIntoRGBA() throws {
        let gray = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                             bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        gray.setFillColor(gray: 0.5, alpha: 1)
        gray.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        let packed = try #require(ReaderPixels.surface(from: gray.makeImage()!))
        #expect(packed.image.format == .rgba)
        let back = try #require(ReaderPixels.cgImage(surface: packed.surface, as: packed.image))
        let pixel = rows(back)[3]
        #expect(pixel[3] == 255 && pixel[0] == pixel[1] && pixel[1] == pixel[2] && pixel[0] > 100 && pixel[0] < 160)
    }

    @Test func aSurfaceThatDoesNotMatchItsDescriptionIsRefused() throws {
        let (source, _, _) = picture(width: 16, height: 8, format: .bgra)
        let packed = try #require(ReaderPixels.surface(from: source))
        var wrongSize = packed.image
        wrongSize.width = 15
        #expect(ReaderPixels.cgImage(surface: packed.surface, as: wrongSize) == nil)
        var wrongFormat = packed.image
        wrongFormat.format = .rgba
        #expect(ReaderPixels.cgImage(surface: packed.surface, as: wrongFormat) == nil)
    }

    @Test func aPixelBufferGivesItsSurfaceWithoutACopy() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 32, 8, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pb = try #require(buffer)
        let packed = try #require(ReaderPixels.surface(of: pb))
        #expect(packed.image.format == .bgra && packed.image.width == 32 && packed.image.height == 8)
        #expect(packed.surface.baseAddress == CVPixelBufferGetIOSurface(pb).map { unsafeBitCast($0.takeUnretainedValue(), to: IOSurface.self).baseAddress })
        // No surface behind the buffer: nothing to send.
        var plain: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &plain)
        #expect(plain.flatMap { ReaderPixels.surface(of: $0) } == nil)
    }

    @Test func theFootprintIsAPlausibleNumber() {
        let mb = ReaderWire.physFootprint() >> 20
        #expect(mb > 5 && mb < 100_000)
    }

    @Test func aCompileFailureIsItsOwnFailureTypedFromTheCompilerCall() throws {
        struct Thrown: Error, CustomStringConvertible { let description: String }
        let d = ReaderFakeAction.nospaceDescription
        #expect(ReadFailure.from(Thrown(description: d)) == .compileFailed(d), "the text the service logged on 2026-10-19")
        #expect(ReadFailure.from(Thrown(description: ReaderFakeAction.e5rtDescription)) == .programsNotReady(ReaderFakeAction.e5rtDescription),
                "Code 13 is what it was")
        #expect(ReadFailure.from(ReadFailure.compileFailed(d)) == .compileFailed(d))
        #expect(ReadFailure.compileFailed(d).description == d)
        let failure = ReadFailure.compileFailed(d)
        #expect(failure.isCompileFailed && failure.isModelNotReady, "a compile failure still goes on with what is left, like Code 13")
        #expect(!ReadFailure.programsNotReady(ReaderFakeAction.e5rtDescription).isCompileFailed && !ReadFailure.failed("x").isModelNotReady)
        #expect(OCRHealth.passFailureIsTransient(failure), "the pass is read again after a backoff")
        // A fake fails with what the classifier makes of its text: the gate and the real error are one thing.
        for action in [ReaderFakeAction.e5rt, .nospace] {
            let made = try #require(action.failure)
            #expect(ReadFailure.from(Thrown(description: made.description)) == made)
        }
        #expect(ReaderFakeAction.slow(ms: 1).failure == nil && ReaderFakeAction.crash.failure == nil && ReaderFakeAction.shift1.failure == nil)
        let reply = ReadReply(id: 7, role: .lines, pid: 1, error: failure)
        #expect(try ReaderWire.decode(ReadReply.self, from: ReaderWire.encode(reply)).error == failure, "it crosses the wire as itself")
    }

    @Test func nospaceFakesCountDownLikeE5rtAndAreOneModePerRole() {
        let plan = ReaderFakePlan("lines-nospace:2,docs-nospace")
        #expect(plan.unrecognized.isEmpty)
        #expect(plan.actions(role: .lines, kind: .rev3) == [.nospace])
        #expect(plan.actions(role: .lines, kind: .warmLines) == [.nospace])
        #expect(plan.actions(role: .lines, kind: .rev3).isEmpty, "two jobs, then it reads")
        #expect(plan.actions(role: .lines, kind: .rev2).isEmpty && plan.actions(role: .lines, kind: .fast).isEmpty, "only the newest model compiles")
        #expect(plan.actions(role: .docs, kind: .doc) == [.nospace] && plan.actions(role: .docs, kind: .warmDoc) == [.nospace])
        #expect(ReaderFakePlan("lines-nospace:x").unrecognized == ["lines-nospace:x"])
        #expect(ReaderFakePlan("lines-e5rt:1,lines-nospace:1").actions(role: .lines, kind: .rev3) == [.nospace], "the last mode named wins")
        let job = ReadJob(kind: .rev3, fake: [.nospace])
        #expect((try? ReaderWire.decode(ReadJob.self, from: ReaderWire.encode(job)))?.fake == [.nospace])
    }
}
