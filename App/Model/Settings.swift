import CoreGraphics
import Foundation
import MwoyeoCore

enum TranslationEngineChoice: String, Codable, CaseIterable, Identifiable {
    /// The language pack's fast model when installed, Apple Intelligence's translation model otherwise.
    case auto
    /// Always Apple Intelligence's high-fidelity translation model.
    case highFidelity
    /// A prompted on-device LLM (Foundation Models) that follows the glossary.
    case customModel

    var id: String { rawValue }
    /// Apple Intelligence's translation model can be asked for from macOS 26.4; before that only the language pack runs.
    static var hasHighFidelity: Bool {
        if #available(macOS 26.4, *) { true } else { false }
    }
    /// The choices this Mac offers.
    static var offered: [Self] { allCases.filter { $0 != .highFidelity || hasHighFidelity } }
    var title: String {
        switch self {
        case .auto: String(localized: "Automatic")
        case .highFidelity: String(localized: "High fidelity")
        case .customModel: String(localized: "Glossary first")
        }
    }
    var detail: String {
        switch self {
        case .auto: String(localized: "The fastest translation when a language pack is installed, Apple Intelligence otherwise")
        case .highFidelity: String(localized: "Always Apple Intelligence’s translation model · the most natural and the slowest, about 1 s a line")
        case .customModel: String(localized: "Foundation Models follows your glossary · for names in games and stories")
        }
    }
}

enum RenderMode: String, Codable, CaseIterable, Identifiable {
    /// Fast boxes while content moves, seamless in-place rewrite once it is still.
    case adaptive
    case fast
    case seamless

    var id: String { rawValue }
    var title: String {
        switch self {
        case .adaptive: String(localized: "Adaptive")
        case .fast: String(localized: "Quick")
        case .seamless: String(localized: "Seamless")
        }
    }
    var detail: String {
        switch self {
        case .adaptive: String(localized: "Boxes while things move; once still, the original is erased and rewritten in place")
        case .fast: String(localized: "Always shows translations on solid boxes. Uses the least battery")
        case .seamless: String(localized: "Always erases the original and rewrites it")
        }
    }
}

enum FontStyleChoice: String, Codable, CaseIterable, Identifiable {
    case system, rounded, serif
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: String(localized: "Default")
        case .rounded: String(localized: "Rounded")
        case .serif: String(localized: "Serif")
        }
    }
}

/// How the lens frame looks on screen.
enum LensStyle: String, Codable, CaseIterable, Identifiable {
    /// The spectrum ring with its glow, turning faster while it reads.
    case glow
    /// A thin spectrum line; it glows only while reading.
    case subtle
    /// A faint grey line; the name tag shows only under the pointer.
    case minimal

    var id: String { rawValue }
    var title: String {
        switch self {
        case .glow: String(localized: "Glow")
        case .subtle: String(localized: "Subtle")
        case .minimal: String(localized: "Minimal")
        }
    }
}

struct AppSettings: Codable, Equatable {
    /// BCP-47 identifier, or "auto" to detect per line.
    var sourceLanguage = "auto"
    var targetLanguage = Languages.preferredTarget
    /// The Apple choice. Apple is what translates unless `customEngineID` names an added engine.
    var engine = TranslationEngineChoice.auto
    /// Engines the user added (keys are in the Keychain, never here).
    var engines: [EngineConfig] = []
    /// The added engine in use; nil, or an id no longer in `engines`, means Apple.
    var customEngineID: UUID?
    /// Request fields each engine's server refused, learned at run time (not a cache: a quirk of that server and model).
    var engineRejections: [UUID: [String]] = [:]
    var renderMode = RenderMode.adaptive
    var useInpaintingModel = true
    /// One "source = target" pair per line.
    var glossary = ""
    var framesPerSecond = 8.0
    /// Seconds without change before the seamless pass runs.
    var settleDelay = 0.5
    var fontStyle = FontStyleChoice.system
    /// Opacity of the box behind text in fast mode.
    var boxOpacity = 0.94
    var lensStyle = LensStyle.glow
    /// Translations kept in memory for reuse.
    var cacheSize = 5000
    /// HotKeyAction raw value → combo; an action missing here has no shortcut.
    var shortcuts = HotKeyAction.defaults
    /// Ask GitHub once a day whether a newer version is out.
    var checksForUpdates = true
    var hasCompletedOnboarding = false
    // Saving: every lens writes what it reads to `exportFolder` while this is on; lens images go there when asked for.
    var savesTranscripts = false
    var exportFolder = ("~/Documents/Mwoyeo" as NSString).expandingTildeInPath
    /// Languages (and engine) remembered per app; the app in front decides which applies (see `effective`).
    var appProfiles: [AppProfile] = []

    /// The settings that translate while the app `frontmost` is in front: this app's profile over the base choice.
    func effective(frontmost: String?) -> AppSettings {
        var s = self
        let c = AppProfiles.effective(base: LanguageChoice(source: sourceLanguage, target: targetLanguage, customEngineID: customEngineID),
                                      profiles: appProfiles, frontmost: frontmost, engines: Set(engines.map(\.id)))
        s.sourceLanguage = c.source
        s.targetLanguage = c.target
        s.customEngineID = c.customEngineID
        return s
    }

    /// The added engine in use; nil is Apple.
    var activeEngineConfig: EngineConfig? { customEngineID.flatMap { id in engines.first { $0.id == id } } }

    var glossaryPairs: [(String, String)] {
        glossary.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
    }

    // Decode leniently so adding a field never wipes a user's saved settings.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        sourceLanguage = try c.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? d.sourceLanguage
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? d.targetLanguage
        engine = (try? c.decodeIfPresent(TranslationEngineChoice.self, forKey: .engine)) ?? d.engine
        // One engine this build cannot read (saved by a newer version) must not take the others with it.
        engines = ((try? c.decodeIfPresent([Lossy<EngineConfig>].self, forKey: .engines)) ?? nil)?.compactMap(\.value) ?? d.engines
        customEngineID = (try? c.decodeIfPresent(UUID.self, forKey: .customEngineID)) ?? d.customEngineID
        engineRejections = (try? c.decodeIfPresent([UUID: [String]].self, forKey: .engineRejections)) ?? d.engineRejections
        renderMode = (try? c.decodeIfPresent(RenderMode.self, forKey: .renderMode)) ?? d.renderMode
        useInpaintingModel = try c.decodeIfPresent(Bool.self, forKey: .useInpaintingModel) ?? d.useInpaintingModel
        glossary = try c.decodeIfPresent(String.self, forKey: .glossary) ?? d.glossary
        framesPerSecond = try c.decodeIfPresent(Double.self, forKey: .framesPerSecond) ?? d.framesPerSecond
        settleDelay = try c.decodeIfPresent(Double.self, forKey: .settleDelay) ?? d.settleDelay
        fontStyle = (try? c.decodeIfPresent(FontStyleChoice.self, forKey: .fontStyle)) ?? d.fontStyle
        boxOpacity = try c.decodeIfPresent(Double.self, forKey: .boxOpacity) ?? d.boxOpacity
        lensStyle = (try? c.decodeIfPresent(LensStyle.self, forKey: .lensStyle)) ?? d.lensStyle
        shortcuts = (try? c.decodeIfPresent([String: KeyCombo].self, forKey: .shortcuts)) ?? d.shortcuts
        checksForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checksForUpdates) ?? d.checksForUpdates
        cacheSize = max(100, try c.decodeIfPresent(Int.self, forKey: .cacheSize) ?? d.cacheSize)
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
        savesTranscripts = try c.decodeIfPresent(Bool.self, forKey: .savesTranscripts) ?? d.savesTranscripts
        exportFolder = try c.decodeIfPresent(String.self, forKey: .exportFolder) ?? d.exportFolder
        appProfiles = ((try? c.decodeIfPresent([Lossy<AppProfile>].self, forKey: .appProfiles)) ?? nil)?.compactMap(\.value) ?? d.appProfiles
    }
}

/// Decodes to nil instead of throwing, so one bad element does not fail the array around it.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// A screen area being translated.
struct RegionConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Global Quartz coordinates (top-left origin of the primary display), in points.
    var rect: CGRect
    var isEnabled = true
    /// When set, the region moves with this window; otherwise it is pinned to the screen.
    var anchor: WindowAnchor?

    /// Follows `window` from where the lens is now, or pins it to the screen when nil. The name says which.
    mutating func follow(_ window: WindowInfo?) {
        anchor = window.map { w in
            WindowAnchor(windowID: w.id, appName: w.appName, title: w.title,
                         offset: CGPoint(x: rect.minX - w.bounds.minX, y: rect.minY - w.bounds.minY))
        }
        name = window.map { $0.appName.isEmpty ? String(localized: "Window") : $0.appName } ?? String(localized: "Screen")
    }
}

struct WindowAnchor: Codable, Equatable {
    var windowID: CGWindowID
    var appName: String
    var title: String
    /// Region origin minus window origin (points).
    var offset: CGPoint
}

/// Common source languages offered in the UI; anything Vision + Translation support works via "auto".
enum Languages {
    static let sources = ["auto", "en", "ja", "ko", "zh-Hans", "zh-Hant", "fr", "de", "es", "it", "pt-BR", "ru", "uk", "vi", "th"]
    static let targets = ["en", "ko", "ja", "zh-Hans", "zh-Hant", "fr", "de", "es", "it", "pt-BR", "ru", "uk", "vi", "th"]

    /// The first of the user's preferred languages that Mwoyeo can translate into.
    static var preferredTarget: String {
        for id in Locale.preferredLanguages {
            let l = Locale.Language(identifier: id)
            if l.languageCode == "zh" { return l.script == .hanTraditional || l.region == "TW" || l.region == "HK" ? "zh-Hant" : "zh-Hans" }
            if l.languageCode == "pt" { return "pt-BR" }
            if let code = l.languageCode?.identifier, targets.contains(code) { return code }
        }
        return "en"
    }

    static func name(_ id: String) -> String {
        if id == "auto" { return String(localized: "Detect") }
        return Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en").localizedString(forIdentifier: id) ?? id
    }

    /// Scripts Vision's fast recognizer handles; everything else needs the accurate recognizer.
    static func isLatinScript(_ id: String) -> Bool {
        ["en", "fr", "de", "es", "it", "pt", "nl", "sv", "da", "nb", "nn", "no", "fi", "pl", "cs", "ro", "tr", "id", "ms", "vi"]
            .contains(Locale.Language(identifier: id).languageCode?.identifier ?? id)
    }
}
