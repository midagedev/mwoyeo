import AppKit
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
        case .customModel: String(localized: "Apple Intelligence follows your glossary exactly · for names in games and stories")
        }
    }
}

/// One radio in Settings › Translation: an Apple choice or an added engine.
enum EngineSelection: Hashable {
    case builtIn(TranslationEngineChoice)
    case added(UUID)

    /// What translates now.
    init(_ settings: AppSettings) {
        self = settings.activeEngineConfig.map { .added($0.id) } ?? .builtIn(settings.engine)
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
    /// Four corner brackets; it glows only while reading.
    case corners
    /// A faint grey line; the name tag shows only under the pointer.
    case minimal

    var id: String { rawValue }
    var title: String {
        switch self {
        case .glow: String(localized: "Glow")
        case .subtle: String(localized: "Subtle")
        case .corners: String(localized: "Corners")
        case .minimal: String(localized: "Minimal")
        }
    }
}

/// A file the translation log is written as.
enum TranscriptFileFormat: String, Codable, CaseIterable {
    case markdown, srt
    /// One JSON object per translated line (see `TranscriptFormat.jsonlLine`), for `tail -f` and scripts.
    case jsonl
}

/// The colours of the lens ring.
enum LensTint: String, Codable, CaseIterable, Identifiable {
    case spectrum, accent, ocean, sunset, forest, mono

    var id: String { rawValue }
    var title: String {
        switch self {
        case .spectrum: String(localized: "Spectrum")
        case .accent: String(localized: "Accent")
        case .ocean: String(localized: "Ocean")
        case .sunset: String(localized: "Sunset")
        case .forest: String(localized: "Forest")
        case .mono: String(localized: "Mono")
        }
    }

    /// The colours around the ring (the system accent for `.accent`, read when asked); the gradient closes on its first.
    var colors: [NSColor] {
        func hex(_ v: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        }
        let loop: [NSColor]
        switch self {
        case .spectrum:
            loop = [NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1), // orange
                    NSColor(srgbRed: 1.00, green: 0.22, blue: 0.37, alpha: 1), // pink
                    NSColor(srgbRed: 0.75, green: 0.35, blue: 0.95, alpha: 1), // purple
                    NSColor(srgbRed: 0.37, green: 0.36, blue: 0.90, alpha: 1), // indigo
                    NSColor(srgbRed: 0.39, green: 0.82, blue: 1.00, alpha: 1)] // cyan
        case .accent:
            let a = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
            loop = [a, a.blended(withFraction: 0.35, of: .white) ?? a, a, a.blended(withFraction: 0.25, of: .black) ?? a]
        case .ocean: loop = [hex(0x2E6BFF), hex(0x00B4D8), hex(0x48CAE4), hex(0x3A86FF)]
        case .sunset: loop = [hex(0xFF7A00), hex(0xFF3D7F), hex(0xB14EFF), hex(0xFFB703)]
        case .forest: loop = [hex(0x2DC653), hex(0x00A884), hex(0x8BD346), hex(0x1B998B)]
        case .mono: loop = [0.72, 0.40, 0.64, 0.36].map { NSColor(white: $0, alpha: 1) }
        }
        return loop + [loop[0]]
    }
}

/// When the lens shows its name tag.
enum LensTabVisibility: String, Codable, CaseIterable, Identifiable {
    /// Always, except on a minimal lens, where it shows under the pointer.
    case automatic, always, onHover

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .always: String(localized: "Always")
        case .onHover: String(localized: "On Hover")
        }
    }
}

/// Where the name tag sits around the lens.
enum LensTabPosition: String, Codable, CaseIterable, Identifiable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing

    var id: String { rawValue }
    var isBottom: Bool { self == .bottomLeading || self == .bottomTrailing }
    var isTrailing: Bool { self == .topTrailing || self == .bottomTrailing }
    var title: String {
        switch self {
        case .topLeading: String(localized: "Top Left")
        case .topTrailing: String(localized: "Top Right")
        case .bottomLeading: String(localized: "Bottom Left")
        case .bottomTrailing: String(localized: "Bottom Right")
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
    var lensTint = LensTint.spectrum
    var lensTabVisibility = LensTabVisibility.automatic
    var lensTabPosition = LensTabPosition.topLeading
    /// Translations kept in memory for reuse.
    var cacheSize = 5000
    /// HotKeyAction raw value → combo; an action missing here has no shortcut.
    var shortcuts = HotKeyAction.defaults
    /// Ask GitHub once a day whether a newer version is out.
    var checksForUpdates = true
    var hasCompletedOnboarding = false
    // Saving: every lens writes what it reads to `exportFolder` while this is on; lens images go there when asked for.
    var savesTranscripts = false
    /// The DMG keeps `~/Documents/Mwoyeo` until a folder is chosen. The App Store build has no folder until one is chosen: the
    /// sandbox does not let it write to one by path (see `ExportFolder`).
    #if MAS
    var exportFolder = ""
    #else
    var exportFolder = ("~/Documents/Mwoyeo" as NSString).expandingTildeInPath
    #endif
    /// Security-scoped bookmark of the folder chosen in Settings (opaque bytes). Run-time state kept in UserDefaults, never
    /// in settings.json (`SettingsFileCheck.notInFile`): it only opens the folder for this install.
    var exportBookmark: Data?
    /// Which engines off this Mac the person allowed to be sent the lens's text, and for which host (`EnginePermissions`). Run-time state
    /// kept in UserDefaults, never in settings.json (`SettingsFileCheck.notInFile`): only the person grants it, in the engine's sheet.
    var enginePermissions = EnginePermissions()
    /// The files the translation log is written as (settings.json only: no row in Settings).
    var transcriptFormats: [TranscriptFileFormat] = [.markdown, .srt]
    /// The profiles (design §1.1, §5.1; `profiles` in settings.json): the languages, engine, memory and amount of an app, a window or a
    /// preset. Today's name for the property is kept, for the screens that read it. A 1.1.4 file's `appProfiles` is read into it.
    var appProfiles: [AppProfile] = []
    /// All apps' amount of context (design §1.4, §5.1: `context`): nil is `memory`, the default (the card, the note and the names, no screen
    /// lines). A profile's own `context` lays over it. The engines no longer hold an amount (`engines[].allow` holds what they may be sent).
    var context: AppContextOverride?
    /// All apps' "learn names and terms" (design §1.4, §5.1: `useLearned`); a profile may set its own. Written only when true.
    var useLearned = false
    /// What every lens is pinned to (design §1.3, §5.1: `profilePin`): a profile's id, or `all`; nil is Auto. A lens's own pin stays with
    /// the lens, not here.
    var profilePin: String?
    /// How the glossary's pairs are used, one mode for all (design §10, §5.1: `glossaryApply`). Written only when not `hint`.
    var glossaryApply = EntryApply.hint
    /// How text is cut into paragraphs, unless an app's profile says otherwise.
    var paragraphReader = ParagraphReader.automatic
    /// 1.1.4's Apple switch, as a view of the new model (design §5.2 case (d), §10): on means every user row and the glossary are used
    /// in both ways, hint and replace. It is never written: the file holds each row's `apply` and `glossaryApply`, and a 1.1.4 file that
    /// had it on is read into those. It stays only while the Memory sheet has the switch (R4 removes both).
    var appleUsesPinnedTerms: Bool {
        get { glossaryApply != .hint || appProfiles.contains { $0.entries.contains { $0.apply != .hint } } }
        set {
            glossaryApply = newValue ? .both : .hint
            for i in appProfiles.indices {
                appProfiles[i].entries = appProfiles[i].entries.map { row in var r = row; r.apply = newValue ? .both : .hint; return r }
            }
        }
    }
    /// An agent connected with `Mwoyeo --mcp` may use the app: read the translation log, read and write each app's memory, read and change
    /// the settings (all but this one). Off by default; the person turns it on in Settings, and an agent cannot (settings.json holds the
    /// key only while it is true).
    var agentConnection = false

    /// The settings that translate while the app `frontmost` is in front: this app's profile over the base choice. With a pin (`profilePin`,
    /// or a lens's own, `lensPin`) the head of the pinned chain decides instead (design §1.3): the pinned profile, or All apps alone.
    func effective(frontmost: String?, lensPin: String? = nil) -> AppSettings {
        var s = self
        if let lensPin { s.profilePin = lensPin }
        let base = LanguageChoice(source: sourceLanguage, target: targetLanguage, customEngineID: customEngineID)
        let known = Set(engines.map(\.id))
        let c: LanguageChoice
        switch s.pin {
        case .auto: c = AppProfiles.effective(base: base, profiles: appProfiles, frontmost: frontmost, engines: known)
        case .allAppsOnly, .profile:
            let head = ProfileChain.chain(for: WindowFacts(bundleID: frontmost), profiles: appProfiles, pin: s.pin).first?.profile
            c = AppProfiles.effective(base: base, profile: head, engines: known)
        }
        s.sourceLanguage = c.source
        s.targetLanguage = c.target
        s.customEngineID = c.customEngineID
        return s
    }

    /// The added engine in use; nil is Apple.
    var activeEngineConfig: EngineConfig? { customEngineID.flatMap { id in engines.first { $0.id == id } } }

    /// This value with the old fields of its engines turned into the new keys (design §5.2, the one Core converter): each engine's own
    /// `context` becomes All apps' amount (`context`), `useLearned` and the engine's `allow`, and is dropped. A value with none is returned as it
    /// is. The file and the preferences are read this way (`init(from:)`); this is for a value built in code the 1.1.4 way: the fixtures of
    /// the checks, and the old Context section of the engine sheet until it is rebuilt.
    func convertedFromOldFields() -> AppSettings {
        guard engines.contains(where: { $0.context != nil }) else { return self }
        let value = ProfileMigration.convert(LegacySettings(customEngineID: customEngineID, appProfiles: appProfiles, engines: engines)).value
        var s = self
        s.engines = value.engines ?? engines
        s.appProfiles = value.profiles.map(\.profile)
        s.context = value.context
        s.useLearned = value.useLearned ?? false
        return s
    }

    /// The glossary's pairs the translator may be told (design §10): all of them, unless the glossary is only replaced in the text.
    var glossaryHintPairs: [(String, String)] { glossaryApply == .replace ? [] : glossaryPairs }

    var glossaryPairs: [(String, String)] {
        glossary.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
    }

    // The keys, as the file and the preferences' copy hold them. `appProfiles` is `profiles` here; the old `appProfiles`, `appleUsesPinnedTerms`
    // and `engines[].context` are read (`init(from:)`) and never written (design §5.2).
    enum CodingKeys: String, CodingKey {
        case sourceLanguage, targetLanguage, engine, engines, customEngineID, engineRejections, renderMode, useInpaintingModel, glossary
        case framesPerSecond, settleDelay, fontStyle, boxOpacity, lensStyle, lensTint, lensTabVisibility, lensTabPosition, cacheSize, shortcuts
        case checksForUpdates, hasCompletedOnboarding, savesTranscripts, exportFolder, exportBookmark, enginePermissions, transcriptFormats
        case paragraphReader, agentConnection
        case profiles, context, useLearned, profilePin, glossaryApply
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourceLanguage, forKey: .sourceLanguage)
        try c.encode(targetLanguage, forKey: .targetLanguage)
        try c.encode(engine, forKey: .engine)
        try c.encode(engines.map(Self.withoutOldContext), forKey: .engines)
        try c.encodeIfPresent(customEngineID, forKey: .customEngineID)
        try c.encode(engineRejections, forKey: .engineRejections)
        try c.encode(renderMode, forKey: .renderMode)
        try c.encode(useInpaintingModel, forKey: .useInpaintingModel)
        try c.encode(glossary, forKey: .glossary)
        try c.encode(framesPerSecond, forKey: .framesPerSecond)
        try c.encode(settleDelay, forKey: .settleDelay)
        try c.encode(fontStyle, forKey: .fontStyle)
        try c.encode(boxOpacity, forKey: .boxOpacity)
        try c.encode(lensStyle, forKey: .lensStyle)
        try c.encode(lensTint, forKey: .lensTint)
        try c.encode(lensTabVisibility, forKey: .lensTabVisibility)
        try c.encode(lensTabPosition, forKey: .lensTabPosition)
        try c.encode(cacheSize, forKey: .cacheSize)
        try c.encode(shortcuts, forKey: .shortcuts)
        try c.encode(checksForUpdates, forKey: .checksForUpdates)
        try c.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try c.encode(savesTranscripts, forKey: .savesTranscripts)
        try c.encode(exportFolder, forKey: .exportFolder)
        try c.encodeIfPresent(exportBookmark, forKey: .exportBookmark)
        try c.encode(enginePermissions, forKey: .enginePermissions)
        try c.encode(transcriptFormats, forKey: .transcriptFormats)
        try c.encode(paragraphReader, forKey: .paragraphReader)
        try c.encode(agentConnection, forKey: .agentConnection)
        try c.encode(appProfiles.map(ProfileFile.init), forKey: .profiles)
        try c.encodeIfPresent(context, forKey: .context)
        try c.encode(useLearned, forKey: .useLearned)
        try c.encodeIfPresent(profilePin, forKey: .profilePin)
        try c.encode(glossaryApply, forKey: .glossaryApply)
    }

    /// An engine as the file keeps it: its old `context` is not written (the amount is All apps' now, `engines[].allow` is the engine's).
    private static func withoutOldContext(_ e: EngineConfig) -> EngineConfig {
        var out = e
        out.context = nil
        return out
    }

    // Decode leniently so adding a field never wipes a user's saved settings.
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        sourceLanguage = try c.decodeIfPresent(String.self, forKey: .sourceLanguage) ?? d.sourceLanguage
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? d.targetLanguage
        engine = (try? c.decodeIfPresent(TranslationEngineChoice.self, forKey: .engine)) ?? d.engine
        // The profiles, the amount, the permissions and the Apple switch: a file of 1.1.4 is converted here (design §5.2, one Core function),
        // one already in the new shape is read as it is. One engine or profile this build cannot read must not take the others with it.
        let converted = ProfileMigration.convert((try? LegacySettings(from: decoder)) ?? LegacySettings()).value
        engines = converted.engines ?? d.engines
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
        lensTint = (try? c.decodeIfPresent(LensTint.self, forKey: .lensTint)) ?? d.lensTint
        lensTabVisibility = (try? c.decodeIfPresent(LensTabVisibility.self, forKey: .lensTabVisibility)) ?? d.lensTabVisibility
        lensTabPosition = (try? c.decodeIfPresent(LensTabPosition.self, forKey: .lensTabPosition)) ?? d.lensTabPosition
        shortcuts = (try? c.decodeIfPresent([String: KeyCombo].self, forKey: .shortcuts)) ?? d.shortcuts
        checksForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checksForUpdates) ?? d.checksForUpdates
        cacheSize = max(100, try c.decodeIfPresent(Int.self, forKey: .cacheSize) ?? d.cacheSize)
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
        savesTranscripts = try c.decodeIfPresent(Bool.self, forKey: .savesTranscripts) ?? d.savesTranscripts
        exportFolder = try c.decodeIfPresent(String.self, forKey: .exportFolder) ?? d.exportFolder
        exportBookmark = (try? c.decodeIfPresent(Data.self, forKey: .exportBookmark)) ?? nil
        enginePermissions = (try? c.decodeIfPresent(EnginePermissions.self, forKey: .enginePermissions)) ?? d.enginePermissions
        transcriptFormats = ((try? c.decodeIfPresent([Lossy<TranscriptFileFormat>].self, forKey: .transcriptFormats)) ?? nil)?.compactMap(\.value) ?? d.transcriptFormats
        appProfiles = converted.profiles.map(\.profile)
        context = converted.context
        useLearned = converted.useLearned ?? false
        profilePin = converted.profilePin
        glossaryApply = converted.glossaryApply ?? .hint
        paragraphReader = (try? c.decodeIfPresent(ParagraphReader.self, forKey: .paragraphReader)) ?? d.paragraphReader
        agentConnection = (try? c.decodeIfPresent(Bool.self, forKey: .agentConnection)) ?? d.agentConnection
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
    /// The profile this lens is pinned to (design §1.3: Auto or pinned, per lens): a profile's id, or `all` for All apps alone. nil is Auto,
    /// or the pin of the whole app (`AppSettings.profilePin`). Kept with the lens, not in settings.json: the file's reset never touches it.
    var profilePin: String? = nil

    /// Follows `window` from where the lens is now, or pins it to the screen when nil. The name says which.
    mutating func follow(_ window: WindowInfo?) {
        anchor = window.map { w in
            WindowAnchor(windowID: w.id, appName: w.appName, title: w.title,
                         offset: CGPoint(x: rect.minX - w.bounds.minX, y: rect.minY - w.bounds.minY))
        }
        name = window.map { $0.appName.isEmpty ? String(localized: "Window") : $0.appName } ?? String(localized: "Screen")
    }
}

extension RegionConfig {
    /// A lens saved by an earlier build has no `profilePin`; one that cannot be read as a string is Auto too, never a lens lost.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        rect = try c.decode(CGRect.self, forKey: .rect)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        anchor = try c.decodeIfPresent(WindowAnchor.self, forKey: .anchor)
        profilePin = (try? c.decodeIfPresent(String.self, forKey: .profilePin)) ?? nil
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
