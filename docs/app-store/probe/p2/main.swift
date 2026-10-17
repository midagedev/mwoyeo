import Foundation
import AppKit
import CoreML
import Vision
import Translation
import FoundationModels

func line(_ s: String) { print(s); fflush(stdout) }
line("sandboxed container = \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "nil")")

let sem = DispatchSemaphore(value: 0)
Task {
    // Translation: availability
    let av = LanguageAvailability()
    let st = await av.status(from: Locale.Language(identifier: "ja"), to: Locale.Language(identifier: "en"))
    line("Translation LanguageAvailability ja>en = \(st)")
    let st2 = await av.status(from: Locale.Language(identifier: "ko"), to: Locale.Language(identifier: "en"))
    line("Translation LanguageAvailability ko>en = \(st2)")
    // Translation: programmatic session (as TranslationService does) if installed
    if st == .installed || st2 == .installed {
        let (s, t) = st == .installed ? ("ja", "en") : ("ko", "en")
        let session = TranslationSession(installedSource: Locale.Language(identifier: s), target: Locale.Language(identifier: t))
        do { let r = try await session.translate(s == "ja" ? "こんにちは" : "안녕하세요"); line("Translation session translate = \(r.targetText)") }
        catch { line("Translation session translate ERROR \(error)") }
    }
    // Foundation Models availability
    let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    line("FoundationModels availability = \(model.availability)")
    // Vision on a drawn image (drawn on the main actor)
    let img: CGImage = await MainActor.run {
        let w = 400, h = 100
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        ("Hello Mac App Store" as NSString).draw(at: NSPoint(x: 10, y: 30), withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
    line("image drawn")
    let vreq = VNRecognizeTextRequest(); vreq.recognitionLevel = .fast
    do { try VNImageRequestHandler(cgImage: img).perform([vreq]); line("Vision VNRecognizeTextRequest(.fast) = \((vreq.results ?? []).compactMap { $0.topCandidates(1).first?.string })") } catch { line("Vision ERROR \(error)") }
    // CoreML load of compiled model outside the container (read-only path)
    let url = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "MIGAN_512.mlmodelc")
    let cfg = MLModelConfiguration(); cfg.computeUnits = .cpuAndGPU
    do { _ = try MLModel(contentsOf: url, configuration: cfg); line("CoreML MIGAN load .cpuAndGPU = OK") } catch { line("CoreML load ERROR \(error)") }
    await MainActor.run {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let g1 = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in }
        let g2 = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { _ in }
        let g3 = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ in }
        line("NSEvent global monitor mouse=\(g1 != nil) scroll=\(g2 != nil) keyDown=\(g3 != nil)")
    }
    exit(0)
}
RunLoop.main.run(until: Date().addingTimeInterval(150))

