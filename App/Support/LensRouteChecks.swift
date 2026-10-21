#if !MAS
import AppKit
import MwoyeoCore
import MwoyeoEngines

/// The checks of the lens's own route (round prof-lens, 2026-10-21; design names-and-context §1.3 "The whole chain is per lens, languages
/// and engine too (Q1)", §8 P1 and P2, and R2's default-path gate), run by `--capture-ui … check-logic` and alone by `lens-route-checks`.
/// Each lens translates with the profile of the app under it over the base, whichever app is in front; the service takes that route with
/// each call, and its cache and pace follow it. The lenses are real sessions on a fake capture; the engines are mock servers. Only counts
/// and names are printed.
///
/// Each check was shown FAIL on a mutation of the code it guards (the round report lists the lines).
@MainActor
enum LensRouteChecks {
    /// Two apps that are not installed: `ContextChecks.lens` knows them by name.
    static let a = ContextChecks.chat, b = ContextChecks.mail

    static func run(_ model: AppModel) async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") lens route: \(what)" + (ok || note().isEmpty ? "" : " [\(note())]"))
            if !ok { failed += 1 }
        }
        guard let mockX = ContextChecks.Mock(mode: "terms"), let mockY = ContextChecks.Mock(mode: "terms") else {
            check("the mock servers start", false)
            return failed
        }
        defer { mockX.stop(); mockY.stop() }
        func openAI(_ name: String, _ mock: ContextChecks.Mock) -> EngineConfig {
            EngineConfig(id: UUID(), name: name, kind: .openAICompatible(baseURL: mock.base.appendingPathComponent("v1"), model: "m1", thinking: .off, extraHeaders: [:]),
                         context: nil)
        }
        let x = openAI("X", mockX), y = openAI("Y", mockY)
        let note = "casual chat between friends"
        let read = { (app: String) in LensWatch.Read(bundleID: app, appName: app == a ? "Example Chat" : "Example Mail", title: "") }
        let saved = model.settings, savedFront = model.frontmostBundleID
        defer {
            model.settings = saved
            model.frontmostBundleID = savedFront
        }

        /// A lens as the app makes one: a session on a fake capture, over the window of `app` (nil: nothing known), attached to the model so
        /// that it hears every push. `sampleWindow` is the read the capture pass makes.
        var lenses: [(session: RegionSession, id: UUID)] = []
        func lens(_ base: AppSettings, over app: String?, attached: Bool = false) -> RegionSession {
            let s = RegionSession(config: RegionConfig(name: "Lens", rect: CGRect(x: 200, y: 300, width: 360, height: 200)), settings: base,
                                  translator: model.translator, inpainter: nil, capturer: FakeCapture(), recovery: LensRobustChecks.fast,
                                  appUnderLens: { _ in app.map(read) })
            if attached {
                let id = UUID()
                model.attach(s, id: id)
                lenses.append((s, id))
            }
            if !base.appProfiles.isEmpty { s.sampleWindow() }
            return s
        }
        func release() async {
            for l in lenses {
                model.detach(l.id)
                await l.session.stop()
            }
            lenses = []
        }

        // A is in front; engine Y is the base. B has a profile of its own: Japanese → Korean on engine X, with a note. A has Korean → German
        // on the base engine.
        let pa = AppProfile(bundleID: a, appName: "Example Chat", source: "en", target: "de")
        let pb = AppProfile(bundleID: b, appName: "Example Mail", source: "ja", target: "ko", customEngineID: x.id, note: note)
        var withProfiles = ContextChecks.settings(nil)
        withProfiles.engines = [x, y]
        withProfiles.customEngineID = y.id
        withProfiles.appProfiles = [pa, pb]
        var plain = ContextChecks.settings(nil)
        plain.engines = [x, y]
        plain.customEngineID = y.id

        // MARK: (a) no profile: every lens is main's

        let noProfile = [nil, a, b, "com.example.other"].map { LensRoute(base: plain, over: $0) }
        check("no profile: every lens's settings are the base, whichever app is under it", noProfile.allSatisfy { $0.settings == plain })
        let appleBase = ContextChecks.settings(nil)
        let appleRoute = LensRoute(base: appleBase, over: b)
        check("no profile: Apple's namespace and pace slot are main's strings",
              appleRoute.namespace == "en>ko|apple:\(appleBase.engine.rawValue)|\(appleBase.glossary.hashValue)"
              && appleRoute.slot.key == "en>ko|apple:\(appleBase.engine.rawValue)" && appleRoute.slot.engine == nil,
              "\(appleRoute.namespace) | \(appleRoute.slot.key)")
        var xAllowed = x
        xAllowed.allow = EngineAllow(lines: false, title: true, deepLInstructions: true)
        check("what an engine is allowed is not its identity: the fingerprint, so its cache and what it learned, stay",
              LensRoute.fingerprint(xAllowed) == LensRoute.fingerprint(x), "\(LensRoute.fingerprint(xAllowed)) vs \(LensRoute.fingerprint(x))")
        let own = ContextChecks.service(plain)
        _ = await own.translate([ContextChecks.line("Hello there, welcome back")])
        let routeForB = LensRoute(base: plain, over: b)
        check("no profile: the service's own namespace and pace slot are a lens's",
              own.storeCounts.keys.sorted() == [routeForB.namespace] && own.paceStats().map(\.key) == [routeForB.slot.key],
              "\(own.storeCounts.keys.sorted()) | \(own.paceStats().map(\.key))")
        check("no profile: a line the service translated is a hit for a lens over any app, and the transcript names the engine",
              own.cached(ContextChecks.line("Hello there, welcome back"), route: routeForB) != nil
              && own.translatedBy(ContextChecks.line("Hello there, welcome back"), route: routeForB) == "Y")

        // No window is read for the owner while no app profile exists; a lens that reads for its context is not a read for the owner.
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
        /// The window reads one burst of frames makes: (every read, reads for the owner).
        func reads(_ s: RegionSession) async -> (all: Int, owner: Int) {
            _ = Trace.takeCounts()
            for i in 0..<5 { if let f = frame(at: Double(i) * 0.1) { s.frameSink?(f) } }
            for _ in 0..<30 { await Task.yield() }
            let c = Trace.takeCounts()
            return (c["lens.window.read"] ?? 0, c["lens.owner.read"] ?? 0)
        }
        let quiet = await reads(lens(plain, over: b))
        check("no profile, no context: no window is read at all (lens.window.read 0, lens.owner.read 0)", quiet.all == 0 && quiet.owner == 0, "reads \(quiet)")
        let contextual = ContextChecks.engine("openai", base: mockX.base, context: EngineContext(enabled: true))
        var onSettings = ContextChecks.settings(contextual)
        onSettings.appProfiles = []
        let forContext = await reads(lens(onSettings, over: b))
        check("no profile, context wanted: the window is read for the context as main does, and none of it is a read for the owner",
              forContext.all > 0 && forContext.owner == 0, "reads \(forContext)")
        let forOwner = await reads(lens(withProfiles, over: b))
        check("a profile, no context wanted: the owner is read (a read per pass that is due, not per frame)", forOwner.owner == 1 && forOwner.all == 1, "reads \(forOwner)")

        // MARK: (b) a lens takes the profile of the app under it

        let over = lens(withProfiles, over: b)
        let overA = lens(withProfiles, over: a)
        let aPair = "\(Languages.name("en")) → \(Languages.name("de"))", bPair = "\(Languages.name("ja")) → \(Languages.name("ko"))"
        check("a lens over B has B's pair and B's engine, with A in front",
              over.route.settings.sourceLanguage == "ja" && over.route.settings.targetLanguage == "ko" && over.route.settings.customEngineID == x.id
              && over.route.app == b, "\(over.route.settings.sourceLanguage)>\(over.route.settings.targetLanguage) \(String(describing: over.route.settings.customEngineID))")
        check("a lens over A has A's pair on the base engine", overA.route.settings.sourceLanguage == "en" && overA.route.settings.targetLanguage == "de"
              && overA.route.settings.customEngineID == y.id && overA.route.app == a)
        check("the pill of each shows its own pair", over.pillDetail == bPair && overA.pillDetail == aPair, "\(over.pillDetail) | \(overA.pillDetail)")
        let nowhere = lens(withProfiles, over: nil)
        check("a lens over no known app has the base", nowhere.route.settings == withProfiles && nowhere.route.app == nil)
        let moved = lens(withProfiles, over: a)
        moved.appUnderLens = { _ in read(b) }
        moved.sampleWindow()
        check("a lens that is moved over another app takes that app's route at the next read",
              moved.route.settings.sourceLanguage == "ja" && moved.route.settings.customEngineID == x.id && moved.pillDetail == bPair)

        // A read that finds no app is not a change of app (design §1.3): the lens keeps its app's route until three reads in a row found none,
        // or it is dropped somewhere new, which reads again and takes the answer.
        let basePair = nowhere.pillDetail
        var tracker = OwnerTracker(b)
        let blips = [tracker.note(nil), tracker.note(nil)], keptB = tracker.app
        let foundA = tracker.note(a), appAfterFound = tracker.app
        let blipsAgain = [tracker.note(nil), tracker.note(nil)], keptA = tracker.app
        let third = tracker.note(nil)
        var dropTracker = OwnerTracker(b)
        let dropChanged = dropTracker.settle(nil)
        check("the owner rule: an app found replaces the owner at once; reads that find none are kept for two in a row, the third leaves, and a found app clears the count",
              blips == [false, false] && keptB == b && foundA && appAfterFound == a && blipsAgain == [false, false] && keptA == a && third && tracker.app == nil,
              "\(blips) \(String(describing: keptB)) \(foundA) \(blipsAgain) \(third) \(String(describing: tracker.app))")
        check("the owner rule: a lens dropped somewhere new takes the read as the answer at once, none included",
              dropChanged && dropTracker.app == nil && !dropTracker.settle(nil), "\(dropChanged) \(String(describing: dropTracker.app))")
        let blip = lens(withProfiles, over: b)
        func drain() async { for _ in 0..<30 { await Task.yield() } }
        await drain()
        _ = Trace.takeCounts()
        blip.appUnderLens = { _ in nil }
        blip.sampleWindow()
        await drain()
        let afterOne = Trace.takeCounts()["pipeline.reset"] ?? 0
        check("a single read that finds no app keeps the lens's route and does not reset the pipeline",
              blip.route.app == b && blip.route.settings.sourceLanguage == "ja" && blip.pillDetail == bPair && afterOne == 0,
              "app \(String(describing: blip.route.app)) pill \(blip.pillDetail) resets \(afterOne)")
        blip.appUnderLens = { _ in read(b) }
        blip.sampleWindow()
        blip.appUnderLens = { _ in nil }
        blip.sampleWindow()
        blip.sampleWindow()
        await drain()
        check("an app found again starts the count again: two more reads that find none do not leave", blip.route.app == b && blip.pillDetail == bPair,
              "app \(String(describing: blip.route.app))")
        blip.sampleWindow()
        await drain()
        let afterThree = Trace.takeCounts()["pipeline.reset"] ?? 0
        check("three reads in a row that find no app take the lens back to the base",
              blip.route.app == nil && blip.route.settings == withProfiles && blip.pillDetail == basePair && afterThree == 1,
              "app \(String(describing: blip.route.app)) pill \(blip.pillDetail) resets \(afterThree)")
        // Dropped somewhere new, the lens reads again at once and takes the answer, none included.
        let dropped = lens(withProfiles, over: b)
        await drain()
        dropped.appUnderLens = { _ in nil }
        dropped.lensDropped()
        await drain()
        check("a lens dropped where no app is found has the base at once", dropped.route.app == nil && dropped.pillDetail == basePair,
              "app \(String(describing: dropped.route.app))")
        var looks = 0
        let onto = lens(withProfiles, over: b)
        await drain()
        onto.appUnderLens = { _ in looks += 1; return read(a) }
        onto.lensDropped()
        await drain()
        let ontoApp = await onto.lensApp
        check("a lens dropped on another app's window takes that app's route and tells the pipeline that app, from one window read",
              onto.route.app == a && onto.pillDetail == aPair && ontoApp.bundleID == a && looks == 1,
              "app \(String(describing: onto.route.app)) pipeline \(String(describing: ontoApp.bundleID)) reads \(looks)")
        looks = 0
        let pushedTo = lens(withProfiles, over: b)
        pushedTo.appUnderLens = { _ in looks += 1; return read(b) }
        await pushedTo.update(settings: withProfiles)
        let pushedApp = await pushedTo.lensApp
        check("a push of the settings reads the window once, and the pipeline's app is the one that read found",
              looks == 1 && pushedApp.bundleID == b, "reads \(looks), pipeline \(String(describing: pushedApp.bundleID))")

        // The request of each: B's lens goes to X with B's memory, A's lens goes to the base engine Y, whichever app is in front.
        let svc = ContextChecks.service(withProfiles)
        let bLines = [ContextChecks.line("こんにちは世界")], aLines = [ContextChecks.line("Hello there")]
        let x0 = mockX.bodies.count, y0 = mockY.bodies.count
        let (toB, _, _) = await ContextChecks.send(mockX, svc, bLines, ContextChecks.lens(b, title: "Inbox", screen: bLines), route: over.route)
        check("the request of a lens over B goes to B's engine and carries B's note (and Y was not asked)",
              toB.text.contains(note) && toB.text.contains("Document: Example Mail") && mockX.bodies.count == x0 + 1 && mockY.bodies.count == y0,
              "X +\(mockX.bodies.count - x0) Y +\(mockY.bodies.count - y0)")
        let (toA, _, _) = await ContextChecks.send(mockY, svc, aLines, ContextChecks.lens(a, screen: aLines), route: overA.route)
        check("the request of a lens over A goes to the base engine, with no memory",
              !toA.text.contains(note) && mockY.bodies.count == y0 + 1 && mockX.bodies.count == x0 + 1, "X +\(mockX.bodies.count - x0) Y +\(mockY.bodies.count - y0)")
        let stale = await ContextChecks.send(mockY, svc, [ContextChecks.line("Another line")], ContextChecks.lens(b, title: "Inbox", screen: bLines), route: overA.route)
        check("a document of B under A's route (the window changed hands) sends none of B's memory to A's engine",
              !stale.sent.text.contains(note) && !stale.sent.text.contains("Document:"), "\(stale.sent.text.contains(note))")
        check("the engine and the profile of a request are one app's: no other receiver for B's memory",
              ContextRoute.otherReceivers(of: b, in: withProfiles).isEmpty && ContextRoute.pairings(lens: b, in: withProfiles).count == 1)

        // MARK: (c) two lenses of different pairs share nothing

        var two = ContextChecks.settings(x, target: "de")
        two.appProfiles = [AppProfile(bundleID: a, appName: "Example Chat", source: "en", target: "ko"), AppProfile(bundleID: b, appName: "Example Mail", source: "en", target: "ja")]
        let r1 = LensRoute(base: two, over: a), r2 = LensRoute(base: two, over: b), r3 = LensRoute(base: two, over: nil)
        let shared = ContextChecks.service(two)
        let hello = ContextChecks.line("Hello there, welcome back")
        let before = mockX.bodies.count
        let o1 = await shared.translate([hello], route: r1)
        check("two lenses of different pairs have different namespaces and pace slots",
              r1.namespace != r2.namespace && r1.slot.key != r2.slot.key && r1.namespace.hasPrefix("en>ko|") && r2.namespace.hasPrefix("en>ja|"),
              "\(r1.slot.key) | \(r2.slot.key)")
        check("a line cached by one lens is not a hit for the other", shared.cached(hello, route: r1) != nil && shared.cached(hello, route: r2) == nil
              && o1.translations[hello] != nil)
        let o2 = await shared.translate([hello], route: r2)
        check("the other lens asks the engine again, and gets its own pair's answer",
              mockX.bodies.count == before + 2 && o2.translations[hello] != nil && o2.translations[hello] != o1.translations[hello],
              "\(mockX.bodies.count - before) requests")
        check("each keeps its translation under its own namespace, and one for another pair stays empty",
              shared.cached(hello, route: r2) == o2.translations[hello] && shared.cached(hello, route: r1) == o1.translations[hello]
              && shared.cached(hello, route: r3) == nil && Set(shared.storeCounts.keys) == [r1.namespace, r2.namespace],
              "\(shared.storeCounts.keys.sorted())")
        let slots = shared.paceStats().map(\.key)
        check("each pair has a pace of its own", Set(slots) == [r1.slot.key, r2.slot.key]
              && shared.expectedSeconds(lines: 1, route: r1) != nil && shared.expectedSeconds(lines: 1, route: r2) != nil
              && shared.expectedSeconds(lines: 1, route: LensRoute(base: two, over: nil)) == nil, "\(slots)")
        check("the transcript names who answered for each lens's pair, and nothing for a pair that has no line",
              shared.translatedBy(hello, route: r1) == "X" && shared.translatedBy(hello, route: r2) == "X" && shared.translatedBy(hello, route: r3) == nil)

        // An engine that fails rests for every lens that uses it, each with Apple's cache and pace for its own pair (Apple is the fake engine of
        // the harness, `MWOYEO_FAKE_ENGINE`).
        if let bad = ContextChecks.Mock(mode: "401") {
            defer { bad.stop() }
            let broken = openAI("Z", bad)
            var failing = two
            failing.engines = [broken]
            failing.customEngineID = broken.id
            let f1 = LensRoute(base: failing, over: a), f2 = LensRoute(base: failing, over: b)
            setenv("MWOYEO_FAKE_ENGINE", "slow:5", 1)
            defer { unsetenv("MWOYEO_FAKE_ENGINE") }
            let resting = ContextChecks.service(failing)
            let g1 = await resting.translate([hello], route: f1)
            check("an engine that fails hands the group to Apple, and the lens that saw it has Apple's line for its pair",
                  bad.bodies.count == 1 && g1.translations[hello]?.hasPrefix("⟦ko⟧") == true && resting.cached(hello, route: f1) == g1.translations[hello],
                  "\(bad.bodies.count) requests")
            let g2 = await resting.translate([hello], route: f2)
            check("another lens of that engine does not ask it while it rests, and has Apple's line and pace for its own pair",
                  bad.bodies.count == 1 && g2.translations[hello]?.hasPrefix("⟦ja⟧") == true && resting.cached(hello, route: f2) == g2.translations[hello]
                  && resting.expectedSeconds(lines: 1, route: f2) != nil && resting.cached(hello, route: f1) == g1.translations[hello],
                  "\(bad.bodies.count) requests")
        } else {
            check("the failing mock server starts", false)
        }

        // MARK: (d) the front app does not move a lens over another app

        model.settings = withProfiles
        let lensB = lens(withProfiles, over: b, attached: true)
        let lensA = lens(withProfiles, over: a, attached: true)
        let lensNone = lens(withProfiles, over: nil, attached: true)
        await model.pushed()
        let beforeB = lensB.route.settings, beforeA = lensA.route.settings
        var steady = true
        for front in [a, b, nil, a] as [String?] {
            model.frontmostBundleID = front
            await model.pushed()
            steady = steady && lensB.route.settings == beforeB && lensA.route.settings == beforeA && lensNone.route.settings == withProfiles
        }
        check("the front app switching (A, B, none, A) changes none of the three lenses", steady)
        model.settings.targetLanguage = "fr"
        await model.pushed()
        check("a change of the base settings reaches each lens, which keeps its own app's profile over it",
              lensNone.route.settings.targetLanguage == "fr" && lensA.route.settings.targetLanguage == "de" && lensB.route.settings.sourceLanguage == "ja"
              && lensB.route.settings.targetLanguage == "ko")
        model.settings = withProfiles
        model.frontmostBundleID = b
        await model.pushed()
        let serviceB = await model.translator.translate([ContextChecks.line("こんにちは世界")])
        check("what has no lens of its own still follows the front app (the service's own route, the menu bar)",
              serviceB.translations.count == 1 && model.effectiveSettings.sourceLanguage == "ja" && model.effectiveSettings.customEngineID == x.id
              && model.translator.storeCounts.keys.contains { $0.hasPrefix("ja>ko|ext:") })
        await release()

        // MARK: (e) the language bar and Remember Languages edit the owners they did

        model.settings = withProfiles
        model.frontmostBundleID = a
        model.setLanguages(target: "fr")
        check("the menu bar's language bar edits the profile of the app in front", model.profile(for: a)?.target == "fr" && model.settings.targetLanguage == "ko"
              && model.profile(for: b)?.target == "ko")
        model.frontmostBundleID = "com.example.nobody"
        model.setLanguages(source: "de", target: "it")
        check("and the base settings when that app has no profile", model.settings.sourceLanguage == "de" && model.settings.targetLanguage == "it"
              && model.profile(for: a)?.target == "fr")
        model.rememberLanguages(LanguageChoice(source: "en", target: "ja", customEngineID: nil), for: b, named: "Example Mail")
        let remembered = model.profile(for: b)
        check("Remember Languages writes the pair and engine into the app's profile and keeps its memory",
              remembered?.source == "en" && remembered?.target == "ja" && remembered?.customEngineID == nil && remembered?.note == note
              && model.settings.sourceLanguage == "de")
        model.settings = withProfiles
        model.frontmostBundleID = nil

        await release()
        return failed
    }
}
#endif
