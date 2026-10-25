import Foundation
import MwoyeoCore

/// One problem found in settings.json. The file is read leniently: an issue is reported, never thrown.
struct SettingsFileIssue: Equatable {
    /// Line in the file; nil when it is not about a place in the file.
    var line: Int?
    var message: String

    /// `settings.json:<line>: <message>`, the line the command-line check prints.
    func described(file: String) -> String { "\(file):\(line ?? 1): \(message)" }
}

/// What the file says about one setting: its documentation, type and limits. The one place that lists the keys of
/// settings.json, for `SettingsSchema` (what an editor or an agent reads) and for `SettingsFileCheck` (what is accepted).
/// A setting's `kind` is a `FieldKind` tree (`SettingsFieldSpec.swift`): the same tree gives the schema and the check, nested objects included.
/// `SettingsFileCheck.uncoveredKeys` fails a check when AppSettings writes a key this table lacks.
struct SettingSpec {
    /// The tab of Settings a key belongs to (design names-and-context §9): what "Restore Defaults…" at the foot of that tab covers. `none` is
    /// a key no tab shows (a key of 1.1.4 that is read and never written).
    enum Tab: String, CaseIterable { case general, translation, appearance, shortcuts, about, none }
    /// What kind of thing a key holds (§9): a `preference` Restore sets to its default, a `consent` it keeps (shown as "kept", turned off only by
    /// hand), `data` it never touches (deleted per item, with its own confirmation).
    enum Nature: String, CaseIterable { case preference, consent, data }

    let key: String
    let kind: FieldKind
    let doc: String
    /// Realistic values of the whole setting, for `examples` in the schema; each must pass the check.
    var examples: [Any] = []
    /// A key of 1.1.4 the app still reads (and converts) and never writes (design §5.2); the schema marks it `deprecated`.
    var deprecated = false
    /// Where Restore Defaults finds the key (§9). Filled from `columns`, the one table; `missingRestoreColumns` fails a key that has no row.
    var tab: Tab?
    var nature: Nature?

    /// The §9 table, row for row: the tab and the nature of every key the file holds. A key not in it has no home for Restore Defaults, and the
    /// check says so (`missingRestoreColumns`). Keys that are not in the file at all (`SettingsFileCheck.notInFile`: `enginePermissions`,
    /// `exportBookmark`, `engineRejections`, `hasCompletedOnboarding`) are consent or data that Restore never touches and have no row here.
    static let columns: [String: (tab: Tab, nature: Nature)] = [
        "sourceLanguage": (.general, .preference), "targetLanguage": (.general, .preference), "renderMode": (.general, .preference),
        "settleDelay": (.general, .preference), "framesPerSecond": (.general, .preference), "transcriptFormats": (.general, .preference),
        "savesTranscripts": (.general, .consent), "exportFolder": (.general, .consent), "agentConnection": (.general, .consent),
        "engine": (.translation, .preference), "fastFirstPaint": (.translation, .preference), "customEngineID": (.translation, .preference), "cacheSize": (.translation, .preference),
        "paragraphReader": (.translation, .preference), "profilePin": (.translation, .preference),
        "context": (.translation, .consent), "useLearned": (.translation, .consent),
        "engines": (.translation, .data), "glossary": (.translation, .data), "glossaryApply": (.translation, .data), "profiles": (.translation, .data),
        "rewrites": (.translation, .preference), "script": (.translation, .preference),
        "useInpaintingModel": (.appearance, .preference), "fontStyle": (.appearance, .preference), "boxOpacity": (.appearance, .preference),
        "lensStyle": (.appearance, .preference), "lensTint": (.appearance, .preference), "lensTabVisibility": (.appearance, .preference),
        "lensTabPosition": (.appearance, .preference), "lensSnap": (.appearance, .preference), "lensAutoFit": (.appearance, .preference), "recentLineCount": (.appearance, .preference),
        "shortcuts": (.shortcuts, .preference),
        "checksForUpdates": (.about, .consent),
        // 1.1.4's keys: read and converted, never written, shown by no tab; what they were is what they became (`profiles`, `glossaryApply`).
        "appProfiles": (.none, .data), "appleUsesPinnedTerms": (.none, .consent),
    ]

    /// The keys of `specs` that lack the tab or the nature (§9: "a key without them fails"); empty when every key has both.
    static func missingRestoreColumns(_ specs: [SettingSpec]) -> [String] {
        specs.filter { $0.tab == nil || $0.nature == nil }.map(\.key)
    }

    static let all: [SettingSpec] = rows.map { row in
        var spec = row
        (spec.tab, spec.nature) = (columns[row.key]?.tab, columns[row.key]?.nature)
        return spec
    }

    private static let rows: [SettingSpec] = [
        .init(key: "sourceLanguage", kind: .choice(Languages.sources),
              doc: "Language of the text on screen: a code such as ja or zh-Hans, or auto to detect it per line."),
        .init(key: "targetLanguage", kind: .choice(Languages.targets), doc: "Language to translate into, as a code such as en or ko."),
        .init(key: "engine", kind: .choice(TranslationEngineChoice.allCases.map(\.rawValue)),
              doc: "Apple's translation choice: auto (the language pack when installed), highFidelity (Apple Intelligence's translation model) or customModel (a prompted on-device model that follows the glossary)."),
        .init(key: "fastFirstPaint", kind: .bool,
              doc: "Paint a lens's first translated lines at once with Apple's low-latency translation, and replace them with the high-fidelity translation when it lands. It acts only where high fidelity is what translates (engine highFidelity) and the language pack of the pair is installed; the translation kept, copied and logged is the high-fidelity one. Written to the file only when true; write false to turn it off."),
        .init(key: "engines", kind: .engines,
              doc: "Translation engines you added, each with a name, a kind, its address and what it may be sent (allow). API keys are never stored here; they stay in the Keychain. Add engines in Settings > Translation.",
              examples: SettingExamples.engines),
        .init(key: "customEngineID", kind: .idOrNull, doc: "The id of the added engine in use, or null to use Apple's translation."),
        .init(key: "renderMode", kind: .choice(RenderMode.allCases.map(\.rawValue)),
              doc: "How translations are drawn: adaptive (boxes while things move, a rewrite in place once still), fast (always boxes) or seamless (always erase and rewrite)."),
        .init(key: "useInpaintingModel", kind: .bool,
              doc: "Erase the original text with the on-device model when rewriting in place; off fills with a flat colour."),
        .init(key: "glossary", kind: .string, doc: "Fixed translations for names and terms in every app, one \"source = target\" pair per line, used the way glossaryApply says. Names and terms of one app, window or preset (a game's cast, a show's places) go in a profile instead: the note and entries of its profiles item."),
        .init(key: "framesPerSecond", kind: .number(1...30),
              doc: "How many times a second the screen is checked for changes. Settings offers 4, 8 and 15."),
        .init(key: "settleDelay", kind: .number(0.2...2),
              doc: "Seconds the screen must stay unchanged before the in-place rewrite runs in adaptive mode."),
        .init(key: "fontStyle", kind: .choice(FontStyleChoice.allCases.map(\.rawValue)), doc: "Typeface of the translated text."),
        .init(key: "boxOpacity", kind: .number(0.6...1), doc: "Opacity of the box behind translated text in fast mode."),
        .init(key: "lensStyle", kind: .choice(LensStyle.allCases.map(\.rawValue)),
              doc: "Look of the lens frame: glow (a ring with a soft glow), subtle (a thin line that glows while reading), corners (only the four corners) or minimal (a faint grey line)."),
        .init(key: "lensTint", kind: .choice(LensTint.allCases.map(\.rawValue)),
              doc: "Colours of the lens frame: spectrum, accent (the system accent colour), ocean, sunset, forest or mono. A minimal lens is grey whatever this says."),
        .init(key: "lensTabVisibility", kind: .choice(LensTabVisibility.allCases.map(\.rawValue)),
              doc: "When the lens shows its name tag: automatic (always, except under the pointer only on a minimal lens), always or onHover."),
        .init(key: "lensTabPosition", kind: .choice(LensTabPosition.allCases.map(\.rawValue)),
              doc: "Where the name tag sits: topLeading, topTrailing, bottomLeading or bottomTrailing."),
        .init(key: "lensSnap", kind: .bool,
              doc: "Snap a lens to the text columns under it: while you drag or resize it, a guide shows when an edge is within 8 points of a column's edge, and the lens lands on it when you let go. Hold ⌘ while dragging to place a lens freely. Written to the file only while false."),
        .init(key: "lensAutoFit", kind: .bool,
              doc: "Lenses you add start with Auto Fit on: after a read settles, a lens that cuts the text of its column at the left or right edge grows to the column once. It never makes a lens smaller. Each lens keeps its own choice, in its menu. Written to the file only while true."),
        .init(key: "cacheSize", kind: .integer(100...100_000), doc: "How many translations are kept in memory for reuse."),
        .init(key: "recentLineCount", kind: .integer(RecentLines.range),
              doc: "How many lines a lens that keeps recent lines (its menu's Keep Recent Lines, for a chat or a visual novel) holds on screen after they leave it, newest nearest the lens. Older ones fade."),
        .init(key: "shortcuts", kind: .shortcuts,
              doc: "Global keyboard shortcuts by action name; an action left out has no shortcut. Each has a Carbon keyCode, a Carbon modifiers mask and a display text. Easier to set in Settings > Shortcuts."),
        .init(key: "checksForUpdates", kind: .bool, doc: "Ask GitHub once a day whether a newer version is out."),
        .init(key: "savesTranscripts", kind: .bool,
              doc: "Translation log: every lens writes what it read and its translation to <exportFolder>/Transcripts (Markdown and SRT, see transcriptFormats) while this is true. The names and terms learned for a profile (useLearned) are written to <exportFolder>/Memory/<profile id>.json while this is true (an app's profile has its bundle id as id); the file is never read back."),
        .init(key: "exportFolder", kind: .string,
              doc: "Folder of the translation log (its Transcripts folder, while savesTranscripts is true), of the learned names (its Memory folder, same condition) and of saved lens images. The App Store version shows the folder chosen in Settings; a path typed here does not open one there."),
        .init(key: "transcriptFormats", kind: .choiceList(TranscriptFileFormat.allCases.map(\.rawValue)),
              doc: "Files of the translation log: markdown, srt, and jsonl (one JSON line per translated line with time, lens, app, source, target, engine, original and translation, added as it happens so tail -f works)."),
        .init(key: "profiles", kind: .profiles,
              doc: "Profiles: a name, a language pair and optionally an engine, a paragraph reader, a note and names and terms, an amount of context and a learn switch. `when` says where a profile is used: each condition is an app (a bundle ID, the app field of each translation log line), a window-title phrase, or both; with none a profile is a preset, used only when it is picked. A lens uses every profile whose conditions match the window it covers, narrowest first (an app and a title, then a title, then an app), then All apps (the top-level keys); the first profile decides the languages and where the learned names are kept. Each name or term has apply: hint (told to the translator where it appears), replace (written into the text before translating, free, and the only way to give a name to Apple Translation) or both. Easier to set from a lens's menu and Settings > Translation; the memory is where one app's names belong, the glossary is for every app. Every item needs id, source and target (copy sourceLanguage and targetLanguage to keep an app on them); an item without them is dropped. Writing a note or names is enough for an added engine (OpenAI-compatible or Anthropic) to be sent the app's name and category, the note and the names that occur in the text, even with context off; no screen lines and no window title go with them. A context mode of off turns that off too.",
              examples: SettingExamples.profiles),
        .init(key: "context", kind: .amount,
              doc: "How much goes with each line for every profile that sets no amount of its own (All apps' amount): off (only the line), memory (the app's name and category, the note and the names that occur in the text; this is what a missing key means), nearby (also the lines around the text on screen) or conversation (also the lines read before, previousLines of them). What an engine may be sent of that is its allow."),
        .init(key: "useLearned", kind: .bool,
              doc: "Also send the names and terms picked up while translating, and record the terms the engine's reply names, for every profile that does not say otherwise. Learned terms stay in memory and are saved only as the learned-memory file (savesTranscripts). Written to the file only when true; write false to turn it off."),
        .init(key: "profilePin", kind: .textOrNull(maxLength: 255, minLength: 1),
              doc: "Pins every lens to one profile: its id, or all for All apps only. Left out or null, each lens picks by its window (Auto). It must name a profile in profiles. A lens's own choice stays with the lens."),
        .init(key: "glossaryApply", kind: .choice(EntryApply.allCases.map(\.rawValue)),
              doc: "How the glossary's pairs are used, one mode for all: hint (told to the translator when a pair occurs in the text), replace (the translation is written into the text before translating, free; Apple Translation uses it too) or both. A pair a profile's names have a row for is not used. Written to the file only when not hint."),
        .init(key: "rewrites", kind: .rewrites,
              doc: "All apps' rules table: changes to the text on this Mac at no token cost, applied in order. A row has a stage (before: the source line the engine is sent; after: the engine's answer), a find text (1 to 200 characters), a replace text (up to 200; left out, the text is deleted), regex (find is a JavaScript regular expression with flags gu, and $1 in replace works; left out, false) and on (left out, true). Up to \(RewriteLimits.maxRows) rows; a bad row is reported and dropped. A regex row runs in a service of the app with no network or files and has \(Int(RewriteLimits.lineBudgetMs)) ms a line together with the rest of its profile's regex rows; over that it is turned off (on: false). A profile has its own rewrites; before rows run from All apps to the narrowest profile and after rows the other way. Written only when there are rows.",
              examples: SettingExamples.rewrites),
        .init(key: "script", kind: .script,
              doc: "All apps' script: JavaScript that defines before(line, ctx) and/or after(src, dst, ctx) and returns the new text, run on this Mac in a service with no network or files, \(Int(RewriteLimits.lineBudgetMs)) ms a line (over that the script is turned off: on: false). ctx has app, profile, source and target. A fresh global object per call: nothing is kept between lines, and there is no Date and no Math.random. A throw, or a return that is not text, leaves that line as it was. Up to \(RewriteLimits.maxScript) characters. A profile has its own script. Written only when set.",
              examples: SettingExamples.scripts),
        .init(key: "appProfiles", kind: .appProfiles,
              doc: "Read, never written: the per-app profiles of Mwoyeo 1.1.4. A file that has this key and no profiles is converted to profiles on the next save, and the old file is kept beside it as settings-1.1.4.json.",
              deprecated: true),
        .init(key: "paragraphReader", kind: .choice(ParagraphReader.allCases.map(\.rawValue)),
              doc: "How text is cut into paragraphs: automatic, documentLayout (the macOS document model) or lineGrouping (the app's own line rules)."),
        .init(key: "appleUsesPinnedTerms", kind: .bool,
              doc: "Read, never written: the switch of Mwoyeo 1.1.4. On, it becomes apply: both on every name in profiles and glossaryApply: both, which also puts those names into the text for engines other than Apple Translation.",
              deprecated: true),
        .init(key: "agentConnection", kind: .bool,
              doc: "Lets an agent connected with `Mwoyeo --mcp` use the app: read the translation log, read and write each app's memory, and read and change settings. Off by default, so a connected agent is refused until the person turns it on in Settings > General. An agent cannot change this key. Written to the file only when true; write false to turn it off."),
    ]

    static func spec(for key: String) -> SettingSpec? { all.first { $0.key == key } }

    /// `value` as this setting with the bad parts left out, or nil when it cannot stand (the setting then keeps its current
    /// value). What is wrong goes to `problems`, each with its path.
    func read(_ value: Any, problems: inout [FieldProblem]) -> Any? {
        kind.read(value, at: FieldPath(steps: [.key(key)]), fallout: .keep, problems: &problems)
    }

    // MARK: value helpers

    static func isBool(_ v: Any) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
    static func number(_ v: Any) -> Double? { isBool(v) ? nil : (v as? NSNumber)?.doubleValue }
    static func shown(_ d: Double) -> String { d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d) }

    static func name(of v: Any) -> String {
        if v is NSNull { return "null" }
        if v is String { return "a string" }
        if isBool(v) { return "a boolean" }
        if v is NSNumber { return "a number" }
        if v is [Any] { return "an array" }
        return "an object"
    }
}

// MARK: the trees of the nested settings

/// The nested settings, each one a `FieldKind` tree. To add a nested field, add a `FieldSpec` here; the schema, the check
/// and its line numbers follow. Keep a field's JSON key equal to what its Codable type encodes.
extension FieldKind {
    /// Action name → key combo. An action left out has no shortcut.
    static let shortcuts: FieldKind = .map(
        .object([
            FieldSpec("keyCode", .integer(0...4_294_967_295), "Carbon virtual key code.", required: true, example: 37),
            FieldSpec("modifiers", .integer(0...4_294_967_295),
                      "Carbon modifier mask: cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096, added together.", required: true, example: 6144),
            FieldSpec("display", .string, "How the shortcut is shown, such as ⌃⌥L.", required: true, example: "⌃⌥L"),
        ]),
        keys: HotKeyAction.allCases.map(\.rawValue), keyNoun: "action")

    private static func baseURL(required: Bool) -> FieldSpec {
        FieldSpec("baseURL", .url,
                  "Where the engine's server answers, an http or https address such as http://localhost:8765/v1. An Anthropic engine without one uses https://api.anthropic.com.",
                  required: required, example: "http://localhost:8765/v1")
    }
    private static let model = FieldSpec("model", .string, "The model name the server expects, such as qwen3:8b. Left out, it is empty.", example: "qwen3:8b")
    private static let thinking = FieldSpec("thinking", .choice(["off", "provider"]),
                                            "off asks the server not to reason (faster, cleaner translations); provider sends nothing extra and lets a reasoning model think.",
                                            default: "off")
    private static let headers = FieldKind.map(.string)

    /// `engines[].allow`: the keys and defaults are those of `EngineAllow`, never a copy.
    private static let engineAllow: FieldKind = .object([
        FieldSpec("lines", .bool,
                  "The lines around the text on screen (and the earlier lines) may be sent to this engine when the amount asks for them. Off: this engine gets only the line, whatever a profile asks, and the memory.",
                  example: true, default: EngineAllow.default.lines),
        FieldSpec("title", .bool,
                  "The window title may be sent. Off by default, because the title can hold text from elsewhere and leaves this Mac when the engine is a cloud service; a server on this Mac gets it whenever lines go.",
                  example: false, default: EngineAllow.default.title),
        FieldSpec("deepLInstructions", .bool,
                  "DeepL only. Send custom_instructions and a formality that come from the memory of the profiles in use. Other engine kinds ignore it.",
                  example: false, default: EngineAllow.default.deepLInstructions),
    ])

    /// `engines[].context` (1.1.4, read and converted): the keys, defaults and limits are those of `EngineContext` and `AppContextOverride`, never a copy.
    /// A field this object lacks would be dropped at the app's next save, and `SettingsFileChecks` fails when the two differ.
    private static let engineContext: FieldKind = .object([
        FieldSpec("enabled", .bool,
                  "Turn context on for this engine. Off, nothing below has an effect and requests are unchanged. On, each request also carries the app's name and kind, the lines around the text on screen, the earlier lines (previousLines) and the memory written for that app.",
                  example: true, default: false),
        FieldSpec("previousLines", .integer(0...AppContextOverride.maxPreviousLines),
                  "How many earlier lines go along with each line, 0 to \(AppContextOverride.maxPreviousLines). Counts only while enabled is true.",
                  example: 3, default: AppContextOverride.defaultPreviousLines),
        FieldSpec("includeTitle", .bool,
                  "Also send the title of the window. Off by default, because the title leaves this Mac when the engine is a cloud service; a server on this Mac gets it whenever enabled is true.",
                  example: false, default: false),
        FieldSpec("useLearned", .bool,
                  "Also send the names and terms the app picked up while translating, and record the terms the engine's reply names. Learned terms stay in memory and are never saved to this file.",
                  example: false, default: false),
        FieldSpec("deepLInstructions", .bool,
                  "DeepL only. Send custom_instructions and a formality that come from the memory written for the app. Other engine kinds ignore it.",
                  example: false, default: false),
    ])

    /// The engines you added. `kind` picks the shape: what the other fields are depends on it.
    static let engines: FieldKind = .list(.tagged(
        tag: "kind",
        tagDoc: "What the engine speaks: openAICompatible (Ollama, LM Studio and the like), anthropic, deepL, httpTemplate (any HTTP service you describe) or command (a program of your own). The other fields depend on it.",
        common: [
            FieldSpec("id", .uuid, "Identifies the engine; customEngineID and the profiles refer to it.", example: exampleUUID),
            FieldSpec("name", .string, "The name shown in Settings.", required: true, example: "Local Qwen"),
            FieldSpec("allow", engineAllow,
                      "What this engine may be sent: the lines around the text (lines, on by default), the window title (title, off by default) and, for DeepL, the memory as its instructions (deepLInstructions, off by default). What a request carries is the amount (context, a profile's context) cut to what the engine allows and takes. Written only when it differs from the default."),
            FieldSpec("context", engineContext,
                      "Read, never written: the context of Mwoyeo 1.1.4. A file that has it and no profiles is converted: the amount becomes context, learning becomes useLearned, and the title and DeepL switches become allow."),
        ],
        variants: [
            FieldVariant(tag: "openAICompatible", fields: [
                baseURL(required: true), model, thinking,
                FieldSpec("extraHeaders", headers,
                          "Extra HTTP headers, name to value. Never put a key here: a header that must carry it holds {{key}}, which the app fills in from the Keychain.",
                          example: ["X-Org": "team-a"]),
            ]),
            FieldVariant(tag: "anthropic", fields: [baseURL(required: false), model, thinking]),
            FieldVariant(tag: "deepL", fields: [
                baseURL(required: true),
                FieldSpec("formality", .string, "DeepL's formality: default, more, less, prefer_more or prefer_less. Left out, DeepL decides.", example: "prefer_more"),
            ]),
            FieldVariant(tag: "httpTemplate", fields: [
                FieldSpec("template", .object([
                    FieldSpec("method", .string, "GET, POST, PUT or PATCH.", default: "POST"),
                    FieldSpec("url", .string, "The request address. {{text}}, {{source}}, {{target}} and {{key}} are filled in.", required: true,
                              example: "http://localhost:5000/translate"),
                    FieldSpec("headers", headers, "HTTP headers, name to value; the same placeholders work in the values."),
                    FieldSpec("body", .string, "The request body, with the same placeholders. {{lines}} sends all lines as a JSON array (batching jsonArray).", default: ""),
                    FieldSpec("resultPath", .string,
                              "Where the translations are in the JSON reply: dot keys and [n] indexes, [*] maps over an array, such as translatedText or data.translations[0].translatedText.",
                              required: true, example: "translatedText"),
                    FieldSpec("batching", .choice(["perLine", "jsonArray"]),
                              "perLine sends one request per line ({{text}}); jsonArray sends all lines in one ({{lines}}).", default: "perLine"),
                ]), "How to call an HTTP service that is none of the built-in kinds (LibreTranslate, DeepLX, Papago, a server of your own).", required: true),
            ]),
            FieldVariant(tag: "command", fields: [
                FieldSpec("command", .object([
                    FieldSpec("executable", .string, "Path of the program to run.", required: true, example: "/usr/local/bin/translate-me"),
                    FieldSpec("arguments", .list(.string), "Arguments passed to the program.", example: ["--fast"]),
                ]), "A program of your own: the app writes one JSON line {source, target, lines} to its stdin and reads {translations} from its stdout.", required: true),
            ]),
        ]))

    /// One name or term of an app's memory. The keys, enums and limits are those of `MemoryEntry` and `Addressing`: a field
    /// this row lacks would be dropped at the app's next save, and `SettingsFileChecks` fails when the two differ.
    private static let appEntries: FieldKind = .list(.object([
        FieldSpec("src", .text(maxLength: MemoryEntry.maxName, minLength: 1), "The name or term as it is written in the text.", required: true, example: "田中"),
        FieldSpec("dst", .text(maxLength: MemoryEntry.maxName, minLength: 1), "How it is translated.", required: true, example: "Tanaka"),
        FieldSpec("kind", .choice(EntryKind.allCases.map(\.rawValue)), "What it is. Left out, term.", example: "person"),
        FieldSpec("gender", .choice(Gender.allCases.map(\.rawValue)), "For a person: f, m or n (neutral), so pronouns and agreement come out right.", example: "m"),
        FieldSpec("note", .text(maxLength: MemoryEntry.maxEntryNote), "A short hint about it, up to \(MemoryEntry.maxEntryNote) characters.", example: "the speaker's older colleague"),
        FieldSpec("reading", .text(maxLength: MemoryEntry.maxName), "How src is pronounced, such as the kana of a kanji name.", example: "たなか"),
        FieldSpec("apply", .choice(EntryApply.allCases.map(\.rawValue)),
                  "How the row is used: hint (told to the translator where it appears; costs tokens), replace (written into the text before translating; free, and the only way Apple Translation takes a name) or both. Left out, hint.",
                  example: "both"),
        FieldSpec("addressing", .list(.object([
            FieldSpec("to", .text(maxLength: MemoryEntry.maxName, minLength: 1), "Who is being spoken to, as written in that entry's src.", required: true, example: "Hana"),
            FieldSpec("register", .choice(Register.allCases.map(\.rawValue)), "How this person speaks to them.", required: true, example: "polite"),
        ]), maxItems: MemoryEntry.maxAddressing, dropsBad: true),
                  "How this person speaks to others: one row per listener, up to \(MemoryEntry.maxAddressing)."),
    ]), maxItems: AppProfile.maxEntries, dropsBad: true)

    /// An amount of context: `context` of the file and of a profile. The modes and limits are those of `AppContextOverride`.
    static let amount: FieldKind = .object([
        FieldSpec("mode", .choice(AppContextOverride.Mode.allCases.map(\.rawValue)),
                  "How much goes along with each line: off (only the line; a profile's note and names are not sent either), memory (the app's name and category, the note and the names that occur in the text), nearby (also the two lines above it and the two below it on screen) or conversation (also the lines read before).",
                  required: true, example: "nearby"),
        FieldSpec("previousLines", .integer(0...AppContextOverride.maxPreviousLines),
                  "How many earlier lines go along in conversation mode, 0 to \(AppContextOverride.maxPreviousLines).",
                  example: 3, default: AppContextOverride.defaultPreviousLines),
    ])

    /// One condition of `when` (design §1.2): an app, a window-title phrase, or both.
    private static let condition: FieldKind = .object([
        FieldSpec("app", .text(minLength: 1), "Bundle identifier of the app whose window the profile is for.", example: "com.example.emu"),
        FieldSpec("titleContains", .text(maxLength: ProfileCondition.maxTitleLength, minLength: 1),
                  "A phrase the window's title must contain (case, accents and width ignored). Keep the part that stays the same, like a game's name. The title only picks the profile on this Mac; it is never sent because of it.",
                  example: "月涙譚"),
    ], needsOneOf: ["app", "titleContains"])

    /// The profiles (design §5.1, §5.3). The limits are the constants of the Core types that keep them (`AppProfile`, `MemoryEntry`,
    /// `AppContextOverride`, `ProfileCondition`), never a second copy. Each field of an item is optional but `id`, `source` and `target`.
    static let profiles: FieldKind = .list(.object([
        FieldSpec("id", .identifier, "Identifies the profile: unique, 1 to 255 letters, digits, dots, hyphens and underscores, never all. An app's profile uses its bundle ID, so its learned names keep their file name.",
                  required: true, example: "com.example.chat"),
        FieldSpec("name", .text(maxLength: AppProfile.maxNameLength, minLength: 1), "The name shown in Settings and the lens menu. Left out, the id.", example: "Example Chat"),
        FieldSpec("when", .list(condition, maxItems: AppProfile.maxConditions, dropsBad: true),
                  "Where the profile is used, up to \(AppProfile.maxConditions) conditions; a window that matches any of them uses it. Left out or empty, a preset: used only when it is picked.",
                  example: [["app": "com.example.chat"]]),
        FieldSpec("source", .choice(Languages.sources), "Source language code, or auto.", required: true, example: "ja"),
        FieldSpec("target", .choice(Languages.targets), "Target language code.", required: true, example: "en"),
        FieldSpec("customEngineID", .engineRef, "Engine for this profile: an id from engines, apple for Apple's own translation, or null / left out to follow All apps."),
        FieldSpec("paragraphReader", .choice(ParagraphReader.allCases.map(\.rawValue)), "Paragraph reader for this profile; left out follows the default."),
        FieldSpec("note", .text(maxLength: AppProfile.maxNoteLength),
                  "A note for the translator: who is talking, the setting, the register. Up to \(AppProfile.maxNoteLength) characters. The notes of the profiles in use go together, broad to narrow, and over \(AppProfile.maxNoteLength) characters the broadest are dropped whole.",
                  example: "Casual chat between two friends. Keep it informal and short."),
        FieldSpec("entries", appEntries,
                  "Names and terms with their translations, up to \(AppProfile.maxEntries) rows. A bad row is reported and dropped; the rest apply. A second row with the same src is left out; of two profiles in use, the narrower one's row wins."),
        FieldSpec("context", amount, "The amount of context for this profile; left out follows the top-level context."),
        FieldSpec("useLearned", .bool, "Learn names and terms for this profile (they are kept under the first profile in use); left out follows the top-level useLearned.", example: true),
        FieldSpec("rewrites", rewrites,
                  "Changes to the text on this Mac at no token cost, applied in order: a row changes the source line before the engine (before) or its answer after it (after). Up to \(RewriteLimits.maxRows) rows; a bad row is reported and dropped. Of two profiles in use, the broader one's before rows run first and its after rows last."),
        FieldSpec("script", script,
                  "A JavaScript that defines before(line, ctx) and/or after(src, dst, ctx), run on this Mac in a service with no network or files; it has \(Int(RewriteLimits.lineBudgetMs)) ms a line. A script that takes longer is turned off (on: false)."),
    ]), maxItems: AppProfile.maxProfiles, dropsBad: true, uniqueBy: "id")

    /// The rules table, top level and in a profile (rewrite-rules §2): at most `RewriteLimits.maxRows` rows, a bad row dropped.
    static let rewrites: FieldKind = .list(rewriteRow, maxItems: RewriteLimits.maxRows, dropsBad: true)

    /// One row of `rewrites` (rewrite-rules §2).
    private static let rewriteRow: FieldKind = .object([
        FieldSpec("stage", .choice(RewriteStage.allCases.map(\.rawValue)), "before changes the source line the engine is sent; after changes the engine's answer.", required: true, example: "before"),
        FieldSpec("find", .text(maxLength: RewriteLimits.findLength.upperBound, minLength: 1), "The text to find: every occurrence, case-sensitive; with regex, a JavaScript regular expression (flags gu).", required: true, example: "▼"),
        FieldSpec("replace", .text(maxLength: RewriteLimits.maxReplace), "What to put there; left out, nothing (the text is deleted). With regex, $1 and the like work.", dropsItem: true, example: ""),
        FieldSpec("regex", .bool, "Treat find as a regular expression. Left out, false.", dropsItem: true, default: false),
        FieldSpec("on", .bool, "Left out, true. The app writes false when a row took longer than \(Int(RewriteLimits.lineBudgetMs)) ms on a line.", dropsItem: true, default: true),
    ])

    /// The script, top level and in a profile (rewrite-rules §3).
    static let script: FieldKind = .object([
        FieldSpec("source", .text(maxLength: RewriteLimits.maxScript), "The JavaScript source, up to \(RewriteLimits.maxScript) characters.", required: true),
        FieldSpec("on", .bool, "Left out, true. The app writes false when the script took longer than \(Int(RewriteLimits.lineBudgetMs)) ms on a line.", dropsItem: true, default: true),
    ])

    /// What the app remembers per app, as 1.1.4 wrote it (read and converted to `profiles`). The memory fields (note, entries, context) are
    /// all optional; their limits are the constants of the Core types that keep them, never a second copy.
    static let appProfiles: FieldKind = .list(.object([
        FieldSpec("bundleID", .string, "Bundle identifier of the app.", required: true, example: "com.example.chat"),
        FieldSpec("appName", .string, "The app's name, for display.", example: "Example Chat"),
        FieldSpec("source", .choice(Languages.sources), "Source language code, or auto.", required: true, example: "ja"),
        FieldSpec("target", .choice(Languages.targets), "Target language code.", required: true, example: "en"),
        FieldSpec("customEngineID", .idOrNull, "Engine for this app; null keeps the base choice."),
        FieldSpec("paragraphReader", .choice(ParagraphReader.allCases.map(\.rawValue)), "Paragraph reader for this app; left out follows the default."),
        FieldSpec("note", .text(maxLength: AppProfile.maxNoteLength), "A note for the translator about this app. Up to \(AppProfile.maxNoteLength) characters.",
                  example: "Casual chat between two friends. Keep it informal and short."),
        FieldSpec("entries", appEntries, "Names and terms of this app, up to \(AppProfile.maxEntries) rows. A bad row is reported and dropped; the rest apply."),
        FieldSpec("context", amount, "Context for this app's translations."),
    ]))
}

/// Realistic values for the schema's `examples`. check-logic reads each through the check, so they stay valid.
enum SettingExamples {
    static let engines: [Any] = [
        [["id": FieldKind.exampleUUID, "kind": "openAICompatible", "name": "Local Qwen", "baseURL": "http://localhost:8765/v1",
          "model": "qwen3:8b", "thinking": "off"] as [String: Any]],
        [["kind": "deepL", "name": "DeepL", "baseURL": "https://api.deepl.com", "formality": "prefer_more"] as [String: Any]],
        [["kind": "openAICompatible", "name": "Cloud chat that may see the window title", "baseURL": "https://api.example.com/v1", "model": "gpt-example",
          "allow": ["lines": true, "title": true, "deepLInstructions": false] as [String: Any]] as [String: Any]],
    ]

    /// An app's profile with a note, two entries that carry addressing (one both ways), a context override and a learn switch; and a
    /// preset with no conditions.
    static let profiles: [Any] = [
        [[
            "id": "com.example.chat", "name": "Example Chat", "when": [["app": "com.example.chat"]], "source": "ja", "target": "en",
            "paragraphReader": "lineGrouping", "note": "Casual chat between two friends. Keep it informal and short.",
            "entries": [
                ["src": "田中", "dst": "Tanaka", "kind": "person", "gender": "m", "note": "the speaker's older colleague", "reading": "たなか", "apply": "both",
                 "addressing": [["to": "Hana", "register": "polite"]]] as [String: Any],
                ["src": "花", "dst": "Hana", "kind": "person", "gender": "f",
                 "addressing": [["to": "Tanaka", "register": "casual"]]] as [String: Any],
            ],
            "context": ["mode": "nearby", "previousLines": 3] as [String: Any], "useLearned": true,
        ] as [String: Any],
        ["id": "anime", "name": "Anime", "source": "ja", "target": "ko", "customEngineID": "apple"] as [String: Any],
        ["id": "game-1", "name": "月涙譚", "when": [["app": "com.example.emu", "titleContains": "月涙譚"]], "source": "ja", "target": "ko"] as [String: Any]],
    ]

    /// A page mark taken out before translating, and the three dots made one character after (rewrite-rules §2).
    static let rewrites: [Any] = [
        [["stage": "before", "find": "▼", "replace": ""] as [String: Any], ["stage": "before", "find": "（[ぁ-ゖ]+）", "regex": true] as [String: Any],
         ["stage": "after", "find": "...", "replace": "…"] as [String: Any]],
    ]

    /// The two examples of rewrite-rules §3.
    static let scripts: [Any] = [
        ["source": "function before(line, ctx) { return line.replace(/（[ぁ-ゖ]+）/gu, \"\") }\nfunction after(src, dst, ctx) { return ctx.target === \"ko\" ? dst.replace(/\\.\\.\\./g, \"…\") : dst }"] as [String: Any],
    ]

    /// The 1.1.4 shape of one profile, for the key that is read and never written.
    static let appProfiles: [Any] = [
        [[
            "bundleID": "com.example.chat", "appName": "Example Chat", "source": "ja", "target": "en", "paragraphReader": "lineGrouping",
            "note": "Casual chat between two friends. Keep it informal and short.",
            "entries": [
                ["src": "田中", "dst": "Tanaka", "kind": "person", "gender": "m", "note": "the speaker's older colleague", "reading": "たなか",
                 "addressing": [["to": "Hana", "register": "polite"]]] as [String: Any],
                ["src": "花", "dst": "Hana", "kind": "person", "gender": "f",
                 "addressing": [["to": "Tanaka", "register": "casual"]]] as [String: Any],
            ],
            "context": ["mode": "nearby", "previousLines": 3] as [String: Any],
        ] as [String: Any]],
    ]
}

/// What reading settings.json gives: the settings to apply and the issues found.
struct SettingsFileResult {
    var settings: AppSettings
    var issues: [SettingsFileIssue]
    /// The file is in 1.1.4's shape and was converted (design §5.2): the next save writes the new shape, after copying this file to
    /// `settings-1.1.4.json`. Not an issue: nothing in the file is wrong.
    var convertedFromOldShape = false
    /// False when the text is not JSON at all (nothing in it was applied).
    var parsed = true
    /// The keys whose value differs from `current`.
    var changed: [String] = []
}

enum SettingsFileCheck {
    /// Settings kept in UserDefaults instead (run-time state, not a choice), so never in the file.
    static let notInFile: Set<String> = ["engineRejections", "hasCompletedOnboarding", "exportBookmark", "enginePermissions", "shortcutsOffered"]

    /// The file's own view of the settings: what AppSettings encodes, without the run-time state, plus an explicit null id.
    static func fileValues(_ s: AppSettings, omittingUnset: Bool = true) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(s),
              var d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        for k in notInFile { d[k] = nil }
        if omittingUnset { for (k, v) in writtenOnlyWhenSet where (d[k] as? NSObject)?.isEqual(v) == true { d[k] = nil } }
        if d["customEngineID"] == nil { d["customEngineID"] = NSNull() }
        if !omittingUnset { for k in nullWhenUnset where d[k] == nil { d[k] = NSNull() } }
        return d
    }

    /// Keys that hold nothing while unset and are not written then (`encodeIfPresent`): a read of every setting (`get_settings`) shows them
    /// as null, the way it shows `customEngineID`, so the list of keys is the table's.
    static let nullWhenUnset = ["context", "profilePin", "script"]

    /// Keys added after 1.1.2 whose default is not written: the file holds one only while it differs, so a file from before the key
    /// re-saves byte for byte. The schema still lists it, with its default. A switch is written only while it is true, `glossaryApply`
    /// only while it is not hint, `recentLineCount` only while it is not 3.
    static let writtenOnlyWhenSet: [String: NSObject] = ["useLearned": false as NSNumber, "agentConnection": false as NSNumber, "fastFirstPaint": false as NSNumber, "glossaryApply": "hint" as NSString, "rewrites": [] as NSArray,
                                                         "lensSnap": true as NSNumber, "lensAutoFit": false as NSNumber,
                                                         "recentLineCount": RecentLines.standard as NSNumber]

    /// Keys AppSettings writes to the file that `SettingSpec.all` does not describe (the schema would lack them). Every
    /// switch counts, also one the file leaves out while it is off.
    static func uncoveredKeys() -> [String] {
        fileValues(AppSettings(), omittingUnset: false).keys.filter { SettingSpec.spec(for: $0) == nil }.sorted()
    }

    /// Reads the file's `data` over `current`. A key the file lacks keeps its current value; so does a key that is
    /// wrong, which is reported. Text that is not JSON changes nothing.
    static func read(_ data: Data, over current: AppSettings) -> SettingsFileResult {
        let text = String(decoding: data, as: UTF8.self)
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            let desc = ((error as NSError).userInfo["NSDebugDescription"] as? String) ?? error.localizedDescription
            let line = position(in: desc)?.line ?? 1
            return SettingsFileResult(settings: current, issues: [.init(line: line, message: "invalid JSON: \(desc) Nothing was applied; a change made in Settings would keep this file as settings.json.broken.")],
                                      parsed: false)
        }
        guard let object = root as? [String: Any] else {
            return SettingsFileResult(settings: current, issues: [.init(line: 1, message: "invalid settings: the file must hold one JSON object. Nothing was applied.")], parsed: false)
        }
        var issues: [SettingsFileIssue] = []
        var accepted: [String: Any] = [:]
        let lines = JSONLines.index(text)
        for (key, value) in object.sorted(by: { $0.key < $1.key }) {
            let path = FieldPath(steps: [.key(key)])
            if key == "$schema" {
                var problems: [FieldProblem] = []
                _ = FieldKind.string.read(value, at: path, fallout: .ignore, problems: &problems)
                issues += problems.map { SettingsFileIssue(line: lines.line(of: $0.path), message: $0.message) }
                continue
            }
            guard let spec = SettingSpec.spec(for: key) else {
                let hint = closest(to: key, in: SettingSpec.all.map(\.key)).map { " (did you mean \($0)?)" } ?? ""
                issues.append(.init(line: lines.line(of: path), message: "unknown key \(key)\(hint)"))
                continue
            }
            var problems: [FieldProblem] = []
            let kept = spec.read(value, problems: &problems)
            issues += problems.map { SettingsFileIssue(line: lines.line(of: $0.path), message: $0.message) }
            if let kept { accepted[key] = kept }
        }
        // The pin names a profile that the file (or, when the file has none, the app) has, or `all` (design §5.3).
        if let pin = accepted["profilePin"] as? String, pin != AppProfile.allAppsID {
            let ids = Set(((accepted["profiles"] as? [[String: Any]]) ?? current.appProfiles.map { ["id": $0.id] }).compactMap { $0["id"] as? String })
            if !ids.contains(pin) {
                let path = FieldPath(steps: [.key("profilePin")])
                issues.append(.init(line: lines.line(of: path), message: "profilePin: no profile has the id \"\(pin)\"; keeping the current value"))
                accepted["profilePin"] = nil
            }
        }
        let converted = convertingOldShape(&accepted)
        for line in lines.trailingCommas {
            issues.append(.init(line: line, message: "trailing comma: JSON does not allow a comma before } or ]; the app reads it, other tools will not"))
        }
        issues.sort { ($0.line ?? .max, $0.message) < ($1.line ?? .max, $1.message) }

        var merged = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(current))) as? [String: Any] ?? [:]
        for (k, v) in accepted {
            if v is NSNull { merged[k] = nil } else { merged[k] = v }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return SettingsFileResult(settings: current, issues: issues + [.init(line: 1, message: "the settings could not be applied")])
        }
        return SettingsFileResult(settings: settings, issues: issues, convertedFromOldShape: converted, parsed: true, changed: changedKeys(current, settings))
    }

    // MARK: the file of 1.1.4 (design §5.2)

    /// The keys the new shape has and 1.1.4 did not: a file in 1.1.4's shape has none of them, so what `current` holds under them is
    /// replaced, not kept, when the file is converted.
    private static let newShapeKeys = ["profiles", "context", "useLearned", "profilePin", "glossaryApply"]

    /// Converts the old keys of `accepted` (the validated values of the file) into the new shape, in place: one Core function
    /// (`ProfileMigration.convert`), the file's own `engines` and `appProfiles` and Apple switch in, `profiles`, `context`, `useLearned`
    /// and `glossaryApply` and the engines' `allow` out. A key the conversion leaves out is cleared (null), so the settings the app holds
    /// do not stand in for it. True when the file was in 1.1.4's shape.
    private static func convertingOldShape(_ accepted: inout [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: accepted),
              let old = try? JSONDecoder().decode(LegacySettings.self, from: data), old.isOldShape,
              let encoded = try? JSONEncoder().encode(ProfileMigration.convert(old).value),
              let new = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else { return false }
        accepted["appProfiles"] = nil
        accepted["appleUsesPinnedTerms"] = nil
        for key in newShapeKeys { accepted[key] = new[key] ?? NSNull() }
        if accepted["engines"] != nil { accepted["engines"] = new["engines"] ?? [] }
        return true
    }

    /// Whether `data` is a settings file in 1.1.4's shape (design §5.2): the store keeps a copy of it before the first save in the new shape.
    static func isOldShape(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(LegacySettings.self, from: data))?.isOldShape ?? false
    }

    static func changedKeys(_ a: AppSettings, _ b: AppSettings) -> [String] {
        let x = fileValues(a), y = fileValues(b)
        return Set(x.keys).union(y.keys).filter { k in
            guard let p = x[k] as? NSObject, let q = y[k] as? NSObject else { return true }
            return !p.isEqual(q)
        }.sorted()
    }

    // MARK: positions and suggestions (the line of every value is `JSONLines`)

    /// The "around line 3, column 7" of Foundation's JSON error.
    private static func position(in description: String) -> (line: Int, column: Int)? {
        guard let m = description.firstMatch(of: /line (\d+), column (\d+)/),
              let l = Int(m.1), let c = Int(m.2) else { return nil }
        return (l, c)
    }

    /// The known key nearest to `key` (ignoring case), if it is near enough to be a typo of it.
    static func closest(to key: String, in known: [String]) -> String? {
        let k = key.lowercased()
        let scored = known.map { ($0, distance(k, $0.lowercased())) }.min { $0.1 < $1.1 }
        guard let (name, d) = scored, d <= max(2, key.count / 3) else { return nil }
        return name
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let t = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = t
            }
        }
        return row[b.count]
    }
}

/// How the file is written: sorted keys, two-space indent, `"key": value`, a trailing newline.
enum SettingsFileFormat {
    static let schemaName = "settings.schema.json"

    static func render(_ s: AppSettings) -> Data {
        var d = SettingsFileCheck.fileValues(s)
        d["$schema"] = schemaName
        return Data((pretty(d) + "\n").utf8)
    }

    /// `$schema` sorts first, so an editor finds the schema before it reads a key.
    static func pretty(_ v: Any, depth: Int = 0) -> String {
        let pad = String(repeating: "  ", count: depth + 1), end = String(repeating: "  ", count: depth)
        if let d = v as? [String: Any] {
            if d.isEmpty { return "{}" }
            return "{\n" + d.keys.sorted().map { "\(pad)\(leaf($0)): \(pretty(d[$0]!, depth: depth + 1))" }.joined(separator: ",\n") + "\n\(end)}"
        }
        if let a = v as? [Any] {
            if a.isEmpty { return "[]" }
            return "[\n" + a.map { pad + pretty($0, depth: depth + 1) }.joined(separator: ",\n") + "\n\(end)]"
        }
        return leaf(v)
    }

    private static func leaf(_ v: Any) -> String {
        if v is NSNull { return "null" }
        // Foundation prints a double with 17 digits (0.94 as 0.93999999999999995); Swift's description is the shortest that reads back.
        if let n = v as? NSNumber, !SettingSpec.isBool(v) {
            if CFNumberIsFloatType(n) { return SettingSpec.shown(n.doubleValue) }
            return String(n.int64Value)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// settings.schema.json (JSON Schema 2020-12), generated from `SettingSpec.all` and AppSettings' defaults. Nested objects come
/// from the same `FieldKind` trees the check walks, so the schema says exactly what `--check-settings` accepts.
enum SettingsSchema {
    static func data() -> Data {
        let defaults = SettingsFileCheck.fileValues(AppSettings(), omittingUnset: false)
        var props: [String: Any] = ["$schema": ["type": "string", "description": "This schema, next to the file. Keep it as it is."]]
        for spec in SettingSpec.all {
            var p = spec.kind.schema()
            p["description"] = spec.doc
            if spec.deprecated { p["deprecated"] = true }
            if let d = defaults[spec.key] { p["default"] = d }
            if !spec.examples.isEmpty { p["examples"] = spec.examples }
            props[spec.key] = p
        }
        let schema: [String: Any] = [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "title": "Mwoyeo settings",
            "description": "Mwoyeo's settings. The app watches this file and applies a saved change within a second. Keys left out keep their value.",
            "type": "object",
            "properties": props,
            "additionalProperties": false,
        ]
        return Data((SettingsFileFormat.pretty(schema) + "\n").utf8)
    }
}

/// The three commands an agent or a script uses; none starts the app:
///   `Mwoyeo --settings-path`            prints where settings.json is.
///   `Mwoyeo --settings-schema`          prints the schema (the settings.schema.json next to the file) to stdout.
///   `Mwoyeo --check-settings [path]`    prints `settings.json:<line>: <message>` per issue, or `ok`; exit 1 when there are issues.
enum SettingsFileCommand {
    static func run(_ args: [String]) -> Never {
        if args.first == "--settings-path" {
            print(SettingsFileStore.defaultURL.path)
            exit(0)
        }
        if args.first == "--settings-schema" {
            FileHandle.standardOutput.write(SettingsSchema.data())
            exit(0)
        }
        let url = args.dropFirst().first.map { URL(fileURLWithPath: $0) } ?? SettingsFileStore.defaultURL
        let (lines, code) = check(url)
        lines.forEach { print($0) }
        exit(code)
    }

    static func check(_ url: URL) -> (lines: [String], code: Int32) {
        guard let data = try? Data(contentsOf: url) else { return (["\(url.lastPathComponent):1: cannot read \(url.path)"], 1) }
        let result = SettingsFileCheck.read(data, over: AppSettings())
        // A file of 1.1.4 is not wrong: the note says what the next save does, and the exit code is the issues'.
        let note = result.convertedFromOldShape
            ? ["\(url.lastPathComponent):1: in the shape of Mwoyeo 1.1.4: converted on the next save (appProfiles to profiles, engines[].context to context and allow); the old file is kept as \(SettingsFileStore.oldShapeName)"]
            : []
        return result.issues.isEmpty ? (note + ["ok"], 0) : (note + result.issues.map { $0.described(file: url.lastPathComponent) }, 1)
    }
}
