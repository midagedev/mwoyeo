#if !MAS
import AppKit
import MwoyeoCore
import Translation

/// The checks of the language pack flow, run by `--capture-ui … check-logic` (or alone: `pack-checks`; PASS/FAIL lines): every state of a
/// pair that cannot translate has a line on the lens, one action that works from where the person is, and a way back after a sheet that
/// ended without the pack. No download is real: the status the system would report is a fake (`PackDownload.status`), and "the sheet
/// ends" is `PackDownload.end`, called as the sheet's task calls it. The 2026-10-19 round's FAIL-first lines are in
/// docs/design/language-packs.md.
@MainActor
enum PackChecks {
    /// What the fake system says of a pair; the checks change it between "the sheet ended" calls.
    private final class FakeSystem: @unchecked Sendable {
        var status = PackStatus.downloadable
    }

    static func run(_ model: AppModel) async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") pack: \(what)" + (ok ? "" : note().isEmpty ? "" : " [\(note())]"))
            if !ok { failed += 1 }
        }
        func session(_ source: String, _ target: String) -> RegionSession {
            var config = RegionConfig(name: "Safari", rect: CGRect(x: 200, y: 300, width: 360, height: 200))
            config.follow(nil)
            var s = AppSettings()
            s.sourceLanguage = source
            s.targetLanguage = target
            return RegionSession(config: config, settings: s, translator: model.translator, inpainter: nil)
        }
        /// What the lens's pill would say, with the grant and the recognizer out of it (they come first and depend on this machine).
        func hint(_ lens: RegionSession) -> LensHint? {
            var signals = lens.hintSignals()
            signals.screen = .fine
            signals.recognitionPreparing = false
            signals.recognition = nil
            return signals.hint()
        }
        func line(_ lens: RegionSession) -> String? { hint(lens).map(LensHintText.line) }
        /// The model's work after a call that hands the rest to a task (`downloadPack` without a window): yields, never waits on a clock.
        func settle(_ done: () -> Bool) async { for _ in 0..<200 where !done() { await Task.yield() } }

        let download = PackDownload.shared
        let ja = PackPair(source: "ja", target: "en"), ko = PackPair(source: "ko", target: "en")
        let system = FakeSystem()
        download.status = { _ in system.status }
        var opened: [SettingsTab] = []
        model.openSettingsAction = { opened.append(model.settingsTab) }
        defer {
            download.status = { pair in await AppModel.shared.translator.packStatus(source: pair.source, target: pair.target) }
            model.openSettingsAction = nil
            model.received(nil)
        }
        let lens = session("auto", "en")
        model.received(.languagePackMissing(source: "ja", target: "en"))

        // 0. The words (English; the same literals the base-tree harness expects).
        // The expected words go through the catalogue too, so the check holds in every language the app runs in (it read English only,
        // and failed on a Mac whose language is Korean: 2026-10-19, lead gate).
        let japanese = Languages.name("ja"), korean = Languages.name("ko")
        check("the new lines read as designed", LensHintText.downloading(ja) == String(localized: "Downloading \(japanese)…")
              && LensHintText.notFinished(ja) == String(localized: "\(japanese) download didn’t finish — try again")
              && LensHintText.notSupported(PackPair(source: "ko", target: "ko")) == String(localized: "\(korean) → \(korean) isn’t supported"),
              "\(LensHintText.downloading(ja)) | \(LensHintText.notFinished(ja))")

        // 1. Nothing asked yet: the ask, with its action.
        check("a missing pack is asked for on the pill", hint(lens) == .downloadPack(ja) && line(lens) == LensHintText.downloadPack(ja))
        check("its click downloads", hint(lens)?.action == .downloadPack(ja))

        // 2. The click: Settings on Translation, and the pill says the download is on its way.
        model.downloadPack(ja)
        check("the click opens Settings on Translation", opened == [.translation], "\(opened)")
        check("and the pill says it is downloading", line(lens) == LensHintText.downloading(ja), "\(line(lens) ?? "nil")")
        check("a click on that goes to the window the sheet is in", hint(lens)?.action == .openTranslationSettings)
        check("the ledger holds it", download.ledger.phase(of: ja) == .downloading && download.settings == ja)

        // 3. Asking again while the sheet is up starts no second sheet, and still brings the window forward.
        model.downloadPack(ja)
        check("a second ask changes nothing but the window", download.ledger.phase(of: ja) == .downloading && download.settings == ja && opened.count == 2,
              "\(opened)")

        // 4. The sheet ends and the pack is not there (declined, interrupted, no connection): said so, the issue stays, the ask comes back.
        system.status = .downloadable
        let declined = await download.end(ja, in: .settings, error: NSError(domain: "pack-check", code: 1))
        check("a sheet that ended without the pack reports it", !declined)
        check("the pill says the download did not finish", line(lens) == LensHintText.notFinished(ja), "\(line(lens) ?? "nil")")
        check("the issue stays up (no flicker, no read for nothing)", model.issue == .languagePackMissing(source: "ja", target: "en"))
        check("its click asks again", hint(lens)?.action == .downloadPack(ja))
        check("the host is free for the next ask", download.settings == nil)

        // 5. The retry goes back to downloading, and a sheet that ends with the pack clears everything.
        model.downloadPack(ja)
        check("the retry is downloading again", line(lens) == LensHintText.downloading(ja) && download.settings == ja)
        system.status = .installed
        let arrived = await download.end(ja, in: .settings)
        check("a sheet that ended with the pack reports it", arrived)
        check("the issue and the ledger are cleared, the pill is quiet", model.issue == nil && download.ledger.phase(of: ja) == nil && hint(lens) == nil)

        // 6. No way to open Settings (no window for the sheet): never a download that runs with nothing to show it.
        model.received(.languagePackMissing(source: "ja", target: "en"))
        model.openSettingsAction = nil
        system.status = .downloadable
        model.downloadPack(ja)
        await settle { download.ledger.phase(of: ja) == .notFinished }
        check("without a window the ask ends as not finished, not as downloading", line(lens) == LensHintText.notFinished(ja), "\(line(lens) ?? "nil")")
        check("and leaves no sheet waiting for a window", download.settings == nil)
        model.openSettingsAction = { opened.append(model.settingsTab) }

        // 7. A sheet replaced by another pair's (its task is cancelled) leaves the new one alone.
        download.request(ja, in: .settings)
        download.request(ko, in: .settings)
        await download.end(ja, in: .settings, error: CancellationError())
        check("the replaced sheet's end leaves the new pair's sheet up", download.settings == ko && download.ledger.phase(of: ko) == .downloading)
        check("and the replaced pair reads as not finished", download.ledger.phase(of: ja) == .notFinished)
        system.status = .installed
        await download.end(ko, in: .settings)
        model.received(nil)
        download.packsChanged()
        check("a pack changing somewhere drops old failures", download.ledger.phase(of: ja) == nil && !download.ledger.isDownloading)

        // 8. The image window's host is separate: its sheet and the Settings one do not clash.
        download.request(ja, in: .image)
        check("the image window hosts its own sheet", download.image == ja && download.settings == nil)
        system.status = .downloadable
        await download.end(ja, in: .image)
        check("and its end frees it, saying not finished", download.image == nil && download.ledger.phase(of: ja) == .notFinished)
        download.packsChanged()

        // 9. A pair with no translation: said on a lens whose source is chosen, and what to do about it.
        let same = PackPair(source: "ko", target: "ko")
        model.received(.unsupportedPair(source: "ko", target: "ko"))
        check("a lens on Korean → Korean says the pair is not supported", hint(session("ko", "ko")) == .pairNotSupported(same)
              && line(session("ko", "ko")) == LensHintText.notSupported(same), "\(line(session("ko", "ko")) ?? "nil")")
        check("its click chooses languages", hint(session("ko", "ko"))?.action == .chooseLanguages)
        check("a lens on Detect says nothing (one block the detector got wrong)", hint(session("auto", "ko")) == nil)
        check("nor does a lens that reads another language", hint(session("ja", "ko")) == nil)
        let before = opened.count
        check("choosing languages opens Settings on General", model.openSettings(on: .general) && opened.count == before + 1 && opened.last == .general)
        model.received(nil)
        check("a translation that went well takes it away", hint(session("ko", "ko")) == nil)

        // 10. The system's status of a pair, asked after the sheet and for each row of the list. The same language twice has no translation.
        check("the same language twice is unsupported", await model.translator.packStatus(source: "ko", target: "ko") == .unsupported)
        // The table of what the models' statuses make of a pair (fast pack, Apple Intelligence's model; nil = not asked for by the engine).
        typealias S = LanguageAvailability.Status
        func status(_ fast: S?, _ intelligence: S?) -> PackStatus { TranslationService.classify(fast: fast, intelligence: intelligence) }
        check("the pack installed is installed, whatever the other model says", status(.installed, .installed) == .installed && status(.installed, .supported) == .installed
              && status(.installed, nil) == .installed)
        check("Apple Intelligence's model alone listing a pair installed does not make its pack installed", status(.supported, .installed) == .viaIntelligence)
        check("where the pack cannot be had, the model that translates is the one installed", status(.unsupported, .installed) == .installed && status(nil, .installed) == .installed)
        check("nothing installed and a pack to get waits for it", status(.supported, .supported) == .downloadable && status(.supported, nil) == .downloadable
              && status(.supported, .unsupported) == .downloadable && status(nil, .supported) == .downloadable)
        check("nothing at all is unsupported", status(.unsupported, .unsupported) == .unsupported && status(.unsupported, nil) == .unsupported
              && status(nil, .unsupported) == .unsupported && status(nil, nil) == .unsupported)
        // On this machine, with the real system: no pair is listed installed while its fast pack is not (the list used to ask for the system's
        // default model, which on a Mac with Apple Intelligence is the translation model, and said "Installed" for every pair).
        if #available(macOS 26.4, *) {
            let fast = LanguageAvailability(preferredStrategy: .lowLatency)
            var liar: String?
            for source in Languages.sources.dropFirst() where source != "en" {
                let fastStatus = await fast.status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: "en"))
                let listed = await model.translator.packStatus(source: source, target: "en")
                if listed == .installed, fastStatus != .installed { liar = source; break }
            }
            check("no pair is listed installed while its fast pack is not", liar == nil, "\(liar ?? "")")
        }

        // 11. The panel's banner, for a trouble no lens says in its row: one message and one action per state.
        let notice = LanguageNotice(.languagePackMissing(source: "ja", target: "en"))
        var ledger = PackLedger()
        check("the banner offers the download", notice?.action(ledger) == String(localized: "Download") && notice?.isDownloading(ledger) == false)
        ledger.requested(ja)
        check("the banner shows the download", notice?.message(ledger) == LensHintText.downloading(ja) && notice?.isDownloading(ledger) == true)
        ledger.ended(ja, installed: false)
        check("the banner offers the retry, and does not say it twice", notice?.action(ledger) == String(localized: "Try again")
              && notice?.message(ledger) == String(localized: "\(Languages.name("ja")) download didn’t finish"))
        check("a lens row has the short line, and the arrow is its action", LensHintText.rowLine(.downloadNotFinished(ja)) == String(localized: "\(Languages.name("ja")) download didn’t finish")
              && LensHintText.rowLine(.downloadingPack(ja)) == LensHintText.downloading(ja))
        check("an issue that is not about the pair has no language banner", LanguageNotice(.timedOut) == nil)
        return failed
    }
}
#endif
