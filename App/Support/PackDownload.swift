import MwoyeoCore
import Observation
import SwiftUI
import Translation
import os

/// Where a language pack's download sheet comes up: the system's sheet belongs to a window, and only a SwiftUI view in one can ask
/// for it (`translationTask`).
enum PackHost: Sendable {
    /// The Settings window, on Translation.
    case settings
    /// The image window, over the picture that needs the pack.
    case image
}

/// "Download <language> (once)": the one owner of every language pack download, whoever asks (a lens, the menu panel, a row in
/// Settings, the image window), and of what became of it (`PackLedger`) for all of them to say. Each window that can host the sheet
/// applies `packDownload(in:)` and shows it when its pair is set.
@MainActor @Observable
final class PackDownload {
    static let shared = PackDownload()

    private(set) var settings: PackPair?
    private(set) var image: PackPair?
    /// Which pairs are downloading, and which ended without the pack.
    private(set) var ledger = PackLedger()
    /// Counts the downloads that ended (installed, or the user said no), so that a list of packs reads its status again.
    private(set) var ended = 0

    /// Asks where a pair stands with the system: after its sheet ended, and for each row of the list in Settings. `--capture-ui` swaps it
    /// for a fake (`check-logic`, the captures of rows in every state): no download there is real.
    @ObservationIgnored var status: (PackPair) async -> PackStatus = { pair in
        await AppModel.shared.translator.packStatus(source: pair.source, target: pair.target)
    }

    /// Asks for the pack's sheet in `host`. A pair whose sheet is up already is not asked for twice: the second ask changes nothing, so
    /// the caller's job is only to bring the window forward.
    func request(_ pair: PackPair, in host: PackHost) {
        guard ledger.phase(of: pair) != .downloading else { return }
        ledger.requested(pair)
        switch host {
        case .settings: settings = pair
        case .image: image = pair
        }
        Trace.count("pack.download.requested")
        AppModel.shared.refreshHints()
    }

    func pair(for host: PackHost) -> PackPair? { host == .settings ? settings : image }

    private let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "packs")

    /// The sheet for `pair` in `host` ended (`error`: what `prepareTranslation` threw, nil when it returned). Whether the pack is there
    /// decides what everything says next, never the error: the person's "Cancel" and a missing connection both throw. A sheet that was
    /// replaced by another pair's (its task is cancelled) leaves the host's new pair alone. Returns whether the pair translates now.
    @discardableResult
    func end(_ pair: PackPair, in host: PackHost, error: (any Error)? = nil) async -> Bool {
        if self.pair(for: host) == pair {
            switch host {
            case .settings: settings = nil
            case .image: image = nil
            }
        }
        ended += 1
        let installed = await status(pair).translates
        ledger.ended(pair, installed: installed)
        Trace.count(installed ? "pack.download.installed" : "pack.download.notfinished")
        // Only what the system reported, never a language of the person's text: the error's type and code say declined from offline.
        let why = error.map { "\(type(of: $0)) \(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "returned"
        log.notice("pack download ended: \(pair.source, privacy: .public) → \(pair.target, privacy: .public) installed=\(installed, privacy: .public) (\(why, privacy: .public))")
        if installed {
            // The pack is there: the lenses forget the old failure and read their text again.
            await AppModel.shared.languagePacksChanged()
        } else {
            // Nothing new to read: the lenses, the panel and the rows only say it did not finish, and offer the same ask again.
            AppModel.shared.refreshHints()
        }
        return installed
    }

    /// Packs were installed or removed somewhere: unfinished downloads are not news any more.
    func packsChanged() { ledger.packsChanged() }

    /// The sheet's task asked the system for `pair`: the log says asked and ended for every sheet, so an ask that brought no sheet shows.
    func sheetAsked(_ pair: PackPair, in host: PackHost) {
        log.notice("pack sheet asked: \(pair.source, privacy: .public) → \(pair.target, privacy: .public) in \(String(describing: host), privacy: .public)")
    }

    /// The sheet could not be hosted (no window to show it over): the ask ends as a download that did not finish.
    func abandon(_ pair: PackPair, in host: PackHost) async {
        guard self.pair(for: host) == pair else { return }
        log.notice("pack download not hosted: \(pair.source, privacy: .public) → \(pair.target, privacy: .public)")
        await end(pair, in: host)
    }
}

extension TranslationSession.Configuration {
    /// The ask for `pair`'s pack. From macOS 26.4 it names the model, because the system's default is Apple Intelligence's translation model:
    /// asking for that when the person wants the pack would bring up no sheet for it. The pack, unless high fidelity is the engine chosen
    /// (then the pack would not help, `TranslationService.packStatus`). Before 26.4 the pack is the only model.
    init(_ pair: PackPair, engine: TranslationEngineChoice) {
        let source = Locale.Language(identifier: pair.source), target = Locale.Language(identifier: pair.target)
        guard #available(macOS 26.4, *) else { self.init(source: source, target: target); return }
        self.init(source: source, target: target, preferredStrategy: engine == .highFidelity ? .highFidelity : .lowLatency)
    }

    /// The ask for `pair` after the host's last one (`last`, kept when its sheet ended): that configuration set to the pair, with a new
    /// version. `translationTask` runs only when its configuration changes, and a fresh one for the same pair equals the last (both
    /// version 0): asked again after "Cancel", no sheet came and the row said "Downloading…" until a relaunch (hand test, 2026-10-20).
    static func asking(_ pair: PackPair, engine: TranslationEngineChoice, after last: Self?) -> Self {
        let fresh = Self(pair, engine: engine)
        var next = last ?? fresh
        next.source = fresh.source
        next.target = fresh.target
        if #available(macOS 26.4, *) { next.preferredStrategy = fresh.preferredStrategy }
        next.invalidate()
        return next
    }
}

private struct PackDownloadHost: ViewModifier {
    let host: PackHost
    /// Called when the sheet ended, with whether the pair translates now.
    let ended: (Bool) -> Void
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: PackDownload.shared.pair(for: host), initial: true) { _, pair in
                if let pair { configuration = .asking(pair, engine: AppModel.shared.settings.engine, after: configuration) }
            }
            .translationTask(configuration) { session in
                // The pair this sheet is for: set when the configuration was, and not the host's later one if it is replaced meanwhile.
                // None when the window comes back with the last configuration and nothing asked.
                guard let pair = await MainActor.run(body: { PackDownload.shared.pair(for: host) }) else { return }
                PackDownload.shared.sheetAsked(pair, in: host)
                // Shows the system's download sheet over this window; returns once the pack is installed or the user declines.
                var failure: (any Error)?
                do { try await session.prepareTranslation() } catch { failure = error }
                // The ending (the ledger, then every lens's re-read) runs in its own task so a task cancelled by another pair's ask
                // cannot skip it.
                Task { @MainActor in
                    let installed = await PackDownload.shared.end(pair, in: host, error: failure)
                    ended(installed)
                }
            }
    }
}

extension View {
    /// Shows the language pack download sheet over this view's window whenever `PackDownload` has a pair for `host`.
    func packDownload(in host: PackHost, ended: @escaping (Bool) -> Void = { _ in }) -> some View {
        modifier(PackDownloadHost(host: host, ended: ended))
    }
}
