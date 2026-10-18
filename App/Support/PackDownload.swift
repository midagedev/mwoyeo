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

/// "Download <language> (once)": the one download a lens or the image window asks for, the pair it is for. Each window that can host
/// the sheet applies `packDownload(in:)` and shows it when its pair is set.
@MainActor @Observable
final class PackDownload {
    static let shared = PackDownload()

    private(set) var settings: PackPair?
    private(set) var image: PackPair?
    /// Counts the downloads that ended (installed, or the user said no), so that a list of packs reads its status again.
    private(set) var ended = 0

    func request(_ pair: PackPair, in host: PackHost) {
        switch host {
        case .settings: settings = pair
        case .image: image = pair
        }
    }

    func pair(for host: PackHost) -> PackPair? { host == .settings ? settings : image }

    private let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "packs")

    fileprivate func end(_ host: PackHost) {
        let pair = pair(for: host)
        switch host {
        case .settings: settings = nil
        case .image: image = nil
        }
        ended += 1
        Trace.count("pack.download.ended")
        log.notice("pack download ended: \(pair?.source ?? "?", privacy: .public) → \(pair?.target ?? "?", privacy: .public)")
        // The pack may be there now: the lenses forget the old failure and read their text again.
        Task { await AppModel.shared.languagePacksChanged() }
    }
}

private struct PackDownloadHost: ViewModifier {
    let host: PackHost
    let ended: () -> Void
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: PackDownload.shared.pair(for: host), initial: true) { _, pair in
                configuration = pair.map {
                    TranslationSession.Configuration(source: Locale.Language(identifier: $0.source), target: Locale.Language(identifier: $0.target))
                }
            }
            .translationTask(configuration) { session in
                // Shows the system's download sheet over this window; returns once the pack is installed or the user declines.
                try? await session.prepareTranslation()
                await MainActor.run {
                    configuration = nil
                    PackDownload.shared.end(host)
                    ended()
                }
            }
    }
}

extension View {
    /// Shows the language pack download sheet over this view's window whenever `PackDownload` has a pair for `host`.
    func packDownload(in host: PackHost, ended: @escaping () -> Void = {}) -> some View {
        modifier(PackDownloadHost(host: host, ended: ended))
    }
}
