import Foundation

/// Where a language pair stands with the system's translator, for the models the chosen engine may use.
public enum PackStatus: Equatable, Sendable {
    /// The fast language pack is installed (or it is the model asked for and it is installed): the pair translates.
    case installed
    /// The pack is not installed and can be downloaded, and Apple Intelligence's model translates the pair meanwhile (slower).
    case viaIntelligence
    /// The pack is not installed and can be downloaded, and nothing else translates the pair: the lens waits for it.
    case downloadable
    /// There is no translation for the pair (the same language twice, or a pair Apple has none for).
    case unsupported

    /// Text of this pair is translated now, by the pack or by the model that stands in for it.
    public var translates: Bool { self == .installed || self == .viaIntelligence }

    /// There is a pack to download for the pair.
    public var canDownload: Bool { self == .viaIntelligence || self == .downloadable }
}

/// What this run knows of each language pack download a person asked for. The system's sheet reports only that it ended, so the
/// ledger keeps the two facts a lens, the menu panel, Settings and the image window need to say something true: a download is on its
/// way (the sheet is up, and asking again would only start a second one), or it ended and the pair still does not translate (the
/// person said no, it was interrupted, or there is no connection). A pack that arrived is forgotten: the translator translating is
/// the news.
public struct PackLedger: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// The sheet for the pack is up (or the download runs).
        case downloading
        /// The sheet ended and the pair still does not translate.
        case notFinished
    }

    public private(set) var phases: [PackPair: Phase] = [:]

    public init() {}

    public func phase(of pair: PackPair) -> Phase? { phases[pair] }

    public var isDownloading: Bool { phases.values.contains(.downloading) }

    /// The person asked for the pack.
    public mutating func requested(_ pair: PackPair) { phases[pair] = .downloading }

    /// The sheet ended; `installed` is whether the pair translates now.
    public mutating func ended(_ pair: PackPair, installed: Bool) {
        phases[pair] = installed ? nil : .notFinished
    }

    /// Packs were installed or removed somewhere (Settings, System Settings): what was kept about unfinished downloads may be stale.
    /// Downloads on their way stay.
    public mutating func packsChanged() {
        phases = phases.filter { $0.value == .downloading }
    }
}
