#if !MAS
import AppKit
import Carbon.HIToolbox
import MwoyeoCore

/// The checks of Hide Lenses (round hidelens, 2026-10-21), run by `--capture-ui … check-logic` (PASS/FAIL lines): one key takes every lens
/// off the screen and brings them back as they were, a hidden lens reads nothing, and the reasons a lens is off the screen (the key, a
/// covering window) compose through `OffScreen`. Lenses are real sessions on a fake capture; time is the frames' own clock (`CapturedFrame.time`),
/// so nothing waits. Reading is measured by the work counters (`Trace`): a frame dropped before the pipeline is `lens.dropped.<reason>`,
/// and with it no `ocr.lines`, `ocr.blocks` or `translate.requests`; a lens reading again is `lens.resumed.<reason>` and frames that are not dropped.
@MainActor
enum HideLensChecks {
    static let ticks = 5

    static func run(_ model: AppModel) async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") hide lenses: \(what)" + (ok ? "" : " [\(detail())]"))
            if !ok { failed += 1 }
        }

        // A frame as the capture hands it on (8×8, not the lens's geometry: the pipeline drops it before any reading, so no OCR runs here).
        func frame(at time: TimeInterval) -> CapturedFrame? {
            let w = 8, h = 8, bytesPerRow = w * 4
            var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
            let image = pixels.withUnsafeMutableBytes { raw -> CGImage? in
                CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage()
            }
            guard let image else { return nil }
            let gray = pixels.withUnsafeBytes { GrayImage(bgra: $0.baseAddress!, width: w, height: h, bytesPerRow: bytesPerRow, step: 2) }
            return CapturedFrame(image: image, gray: gray, grayStep: 2, scale: 1, rect: CGRect(x: 0, y: 0, width: 8, height: 8), time: time)
        }
        var clock: TimeInterval = 1
        /// `ticks` frames, each a tick later than the last, into the lens's own capture callback.
        func feed(_ lenses: [RegionSession], ticks: Int = Self.ticks) {
            for _ in 0..<ticks {
                clock += 0.1
                guard let f = frame(at: clock) else { continue }
                lenses.forEach { $0.frameSink?(f) }
            }
        }
        func lens(_ name: String, _ rect: CGRect) async -> RegionSession {
            let s = RegionSession(config: RegionConfig(name: name, rect: rect), settings: AppSettings(), translator: model.translator, inpainter: nil,
                                  capturer: FakeCapture(), recovery: LensRobustChecks.fast)
            await s.start()
            return s
        }
        /// What a lens shows as text: the lines VoiceOver reads (`translationLines`), from the newest snapshot.
        func lines(_ s: RegionSession) -> [String] { (s.lensWindow as? RegionFrameWindow)?.translationLines?() ?? [] }
        func say(_ s: RegionSession, _ translation: String, in rect: CGRect) {
            s.received(OverlaySnapshot(version: 1, blocks: [], animated: false, origin: rect.origin,
                                       texts: [BlockText(frame: CGRect(x: 40, y: 40, width: 200, height: 30), source: "こんにちは", translation: translation)]))
        }
        func counts(_ c: [String: Int], _ prefix: String) -> [String: Int] { c.filter { $0.key.hasPrefix(prefix) } }
        /// A covered lens: its frame is off and its translations are invisible (the panel fades out where it is). Hidden by the key: no window is up at all.
        func covered(_ s: RegionSession) -> Bool { !s.lensWindow.isVisible && !s.showsTranslations }

        let rectA = CGRect(x: 120, y: 200, width: 320, height: 180), rectB = CGRect(x: 520, y: 200, width: 320, height: 180)
        let rectC = CGRect(x: 920, y: 200, width: 320, height: 180)
        let a = await lens("A", rectA), b = await lens("B", rectB)
        say(a, "Hello there", in: rectA)
        say(b, "Second lens", in: rectB)

        // The key hides every lens: panel, frame and pill off the screen, and nothing is read. Before it, both are up and their frames pass.
        let upBefore = a.windowsUp == 2 && b.windowsUp == 2
        _ = Trace.takeCounts()
        feed([a, b])
        var c = Trace.takeCounts()
        let passedBefore = counts(c, "lens.dropped").isEmpty

        _ = Trace.takeCounts()
        let hidden = RegionSession.toggleHiding([a, b])
        feed([a, b])
        c = Trace.takeCounts()
        check("the key takes both lenses (panel, frame, pill) off the screen: up with their frames passing before, no window up after",
              upBefore && passedBefore && hidden && a.windowsUp == 0 && b.windowsUp == 0 && a.isHiddenByUser && b.isHiddenByUser,
              "up \(upBefore) passed \(passedBefore) hidden \(hidden) windows \(a.windowsUp) \(b.windowsUp)")
        check("a hidden lens reads nothing: every frame of \(Self.ticks) ticks is dropped before the pipeline (lens.dropped.hidden), once paused each (lens.paused.hidden)",
              c["lens.dropped.hidden"] == 2 * Self.ticks && c["lens.paused.hidden"] == 2, "\(counts(c, "lens."))")
        check("and no text is recognized, no engine asked while hidden (ocr.lines, ocr.blocks, translate.requests absent)",
              hidden && c["lens.dropped.hidden"] != nil && c["ocr.lines"] == nil && c["ocr.blocks"] == nil && c["translate.requests"] == nil, "\(c)")
        check("a hidden lens keeps its last lines", a.isHiddenByUser && lines(a) == ["Hello there"] && lines(b) == ["Second lens"], "\(lines(a)) \(lines(b))")

        // The key again: the same lines, reading again.
        _ = Trace.takeCounts()
        let shown = RegionSession.toggleHiding([a, b])
        feed([a, b])
        c = Trace.takeCounts()
        check("the key again brings every lens back with the lines it had", hidden && !shown && a.windowsUp == 2 && b.windowsUp == 2 && !a.isHiddenByUser && lines(a) == ["Hello there"] && lines(b) == ["Second lens"],
              "\(shown) \(a.windowsUp) \(b.windowsUp) \(lines(a))")
        check("and reading resumes: one fresh read each (lens.resumed.hidden) and no frame dropped",
              c["lens.resumed.hidden"] == 2 && counts(c, "lens.dropped").isEmpty, "\(counts(c, "lens."))")

        // One lens hidden, one up (a lens that came back some other way): the key brings back, it does not hide the other.
        a.setHiddenByUser(true)
        let oneHidden = a.windowsUp == 0 && a.isHiddenByUser && b.windowsUp == 2
        let mixed = RegionSession.toggleHiding([a, b])
        check("with one lens hidden and one up the key shows them all", oneHidden && !mixed && a.windowsUp == 2 && b.windowsUp == 2, "\(oneHidden) \(mixed) \(a.windowsUp) \(b.windowsUp)")

        // Hide, a covering window, show: the covered lens stays off the screen and reads nothing until it is uncovered.
        RegionSession.toggleHiding([a, b])
        a.setOccluded(true)
        let bothHidden = a.isHiddenByUser && b.isHiddenByUser
        _ = Trace.takeCounts()
        RegionSession.toggleHiding([a, b])
        feed([a])
        c = Trace.takeCounts()
        check("hide, covered, show: the covered lens stays off the screen, the other comes back",
              bothHidden && covered(a) && !a.isHiddenByUser && b.windowsUp == 2 && !b.isHiddenByUser, "\(bothHidden) \(a.windowsUp) \(a.isHiddenByUser) \(b.windowsUp)")
        check("and it still reads nothing, for the reason that is left (lens.dropped.occluded, no resume yet)",
              c["lens.dropped.occluded"] == Self.ticks && c["lens.dropped.hidden"] == nil && c["lens.resumed.hidden"] == 1 && c["lens.resumed.occluded"] == nil, "\(counts(c, "lens."))")
        _ = Trace.takeCounts()
        a.setOccluded(false)
        feed([a])
        c = Trace.takeCounts()
        check("uncovered, it is back with its lines and reads again (lens.resumed.occluded)",
              a.windowsUp == 2 && lines(a) == ["Hello there"] && c["lens.resumed.occluded"] == 1 && counts(c, "lens.dropped").isEmpty, "\(a.windowsUp) \(counts(c, "lens."))")

        // Covered, hide, uncovered: the key still holds it, until the key brings it back.
        a.setOccluded(true)
        RegionSession.toggleHiding([a, b])
        _ = Trace.takeCounts()
        a.setOccluded(false)
        c = Trace.takeCounts()
        check("covered, hide, uncovered: it stays hidden (no resume)", a.windowsUp == 0 && a.isHiddenByUser && c["lens.resumed.occluded"] == nil && c["lens.resumed.hidden"] == nil, "\(a.windowsUp) \(counts(c, "lens."))")
        let heldByKey = a.isHiddenByUser
        RegionSession.toggleHiding([a, b])
        check("and the key brings it back", heldByKey && a.windowsUp == 2 && b.windowsUp == 2, "\(heldByKey) \(a.windowsUp) \(b.windowsUp)")

        // Show Original keeps working while hidden, and is what shows when the lens is back.
        RegionSession.toggleHiding([a, b])
        a.setTranslationsVisible(false)
        let originalWhileHidden = a.windowsUp == 0 && !a.showsTranslations
        RegionSession.toggleHiding([a, b])
        check("Show Original while hidden: the lens is back showing the original, not the translation", originalWhileHidden && a.windowsUp == 2 && !a.showsTranslations && b.showsTranslations,
              "\(originalWhileHidden) \(a.windowsUp) \(a.showsTranslations)")
        a.setTranslationsVisible(true)
        check("and Show Translation brings the translation back", originalWhileHidden && a.showsTranslations)

        // A lens added while hidden is up at once, and the add ends hiding for every lens (`AppModel.addRegion` calls `setHiding(false, …)`).
        RegionSession.toggleHiding([a, b])
        let new = await lens("C", rectC)
        check("a lens added while the others are hidden comes up shown", new.windowsUp == 2 && !new.isHiddenByUser && a.windowsUp == 0 && b.windowsUp == 0,
              "\(new.windowsUp) \(a.windowsUp) \(b.windowsUp)")
        let othersHidden = a.isHiddenByUser && b.isHiddenByUser && new.windowsUp == 2
        RegionSession.setHiding(false, in: [a, b, new])
        check("and ends hiding: every lens is back with its lines", othersHidden && [a, b, new].allSatisfy { $0.windowsUp == 2 && !$0.isHiddenByUser } && lines(a) == ["Hello there"] && lines(b) == ["Second lens"],
              "\([a, b, new].map(\.windowsUp)) \(lines(a)) \(lines(b))")

        // With no lens up the key has nothing to change (Pause removes the sessions: a lens that comes back is a new one, shown).
        let before = model.lensesHidden
        model.toggleLensesHidden()
        let none = RegionSession.toggleHiding([RegionSession]())
        check("with no lens up Hide Lenses hides nothing",
              !before && !model.lensesHidden && !none, "\(before) \(model.lensesHidden) \(none)")

        // A lens stopped while hidden (Pause) is gone, not left half up: stopping puts nothing back on the screen.
        RegionSession.toggleHiding([a, b, new])
        let allHidden = [a, b, new].allSatisfy { $0.isHiddenByUser && $0.windowsUp == 0 }
        for s in [a, b, new] { await s.stop() }
        check("lenses stopped while hidden leave no window up", allHidden && [a, b, new].allSatisfy { $0.windowsUp == 0 }, "\(allHidden) \([a, b, new].map(\.windowsUp))")

        // The shortcut: its name, its default, and settings.json accepts it (`Mwoyeo --check-settings`).
        let action = HotKeyAction(rawValue: "hideLenses")
        check("Hide Lenses is a shortcut action", action?.title == String(localized: "Hide Lenses"), "\(String(describing: action?.title))")
        // No default (the user, 2026-10-21: only Add Lens and Show Original have one, so few keys clash with other apps).
        check("it has no default shortcut", HotKeyAction.defaults["hideLenses"] == nil, "\(String(describing: HotKeyAction.defaults["hideLenses"]))")
        let all = HotKeyAction.defaults
        check("the defaults are two shortcuts, Add Lens and Show Original, on two different keys",
              Set(all.keys) == ["addLens", "toggleOriginal"] && Set(all.values.map { "\($0.keyCode).\($0.modifiers)" }).count == 2,
              "\(all.mapValues(\.display))")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hidelens-\(UUID().uuidString)").appendingPathExtension("json")
        try? Data(#"{"shortcuts":{"hideLenses":{"keyCode":4,"modifiers":6144,"display":"⌃⌥H"}}}"#.utf8).write(to: file)
        let command = SettingsFileCommand.check(file)
        try? FileManager.default.removeItem(at: file)
        check("settings.json with a hideLenses shortcut passes --check-settings", command.code == 0 && command.lines == ["ok"], "\(command.lines)")
        let schema = String(data: SettingsSchema.data(), encoding: .utf8) ?? ""
        check("and the settings schema names the action", schema.contains("\"hideLenses\""))
        return failed
    }
}
#endif
