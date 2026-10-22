#if !MAS
import Foundation
import MwoyeoCore

/// The checks of `RestorePlan` (design names-and-context §9, A1; round agents, 2026-10-21), run by `--capture-ui … check-logic` through
/// `MCPChecks` (the one tool that restores besides Settings) and so by `mcp-checks`. The table of §9 is written out here a second time, from
/// the design document, so a key moved between natures in `SettingSpec.columns` shows as a failure. Every check was seen to FAIL on a
/// deliberately broken `RestorePlan` first (the lines are in the round's report).
@MainActor
enum RestorePlanChecks {
    /// §9, preference rows: what "Restore Defaults…" of a tab sets back.
    private static let preferences: [SettingSpec.Tab: Set<String>] = [
        .general: ["sourceLanguage", "targetLanguage", "renderMode", "settleDelay", "framesPerSecond", "transcriptFormats"],
        .translation: ["engine", "fastFirstPaint", "customEngineID", "cacheSize", "paragraphReader", "profilePin"],
        .appearance: ["useInpaintingModel", "fontStyle", "boxOpacity", "lensStyle", "lensTint", "lensTabVisibility", "lensTabPosition", "lensSnap", "lensAutoFit"],
        .shortcuts: ["shortcuts"],
        .about: [],
    ]
    /// §9, consent and data rows: kept by every tab, never written. (`rewrites` and `script` join `translation` when the file holds them.)
    private static let keptByTab: [SettingSpec.Tab: Set<String>] = [
        .general: ["savesTranscripts", "exportFolder", "agentConnection"],
        .translation: ["context", "useLearned", "engines", "glossary", "glossaryApply", "profiles"],
        .appearance: [],
        .shortcuts: [],
        .about: ["checksForUpdates"],
    ]

    /// Settings that differ from the defaults in every key of §9: each preference, each consent and each datum.
    static func everythingChanged() -> AppSettings {
        var s = AppSettings()
        s.sourceLanguage = "ja"
        s.targetLanguage = Languages.targets.first { $0 != Languages.preferredTarget } ?? "ko"
        s.renderMode = .fast
        s.settleDelay = 1.0
        s.framesPerSecond = 15
        s.transcriptFormats = [.jsonl]
        s.engine = .customModel
        s.fastFirstPaint = true
        let engine = EngineConfig(name: "Local", kind: .openAICompatible(baseURL: URL(string: "http://localhost:11434/v1") ?? URL(fileURLWithPath: "/"),
                                                                         model: "m", thinking: .off, extraHeaders: [:]))
        s.engines = [engine]
        s.customEngineID = engine.id
        s.cacheSize = 200
        s.paragraphReader = .lineGrouping
        s.useInpaintingModel = false
        s.fontStyle = .serif
        s.boxOpacity = 0.8
        s.lensStyle = .subtle
        s.lensTint = .ocean
        s.lensTabVisibility = .always
        s.lensTabPosition = .bottomTrailing
        s.lensSnap = false
        s.lensAutoFit = true
        s.shortcuts = [:]
        s.savesTranscripts = true
        s.exportFolder = "/tmp/restore-checks-export"
        s.agentConnection = true
        s.context = AppContextOverride(mode: .nearby)
        s.useLearned = true
        s.glossary = "勇者 = Hero"
        s.glossaryApply = .both
        s.appProfiles = [AppProfile(bundleID: "com.example.chat", appName: "Example Chat", source: "ja", target: "en", note: "Casual.")]
        s.profilePin = "com.example.chat"
        s.checksForUpdates = false
        return s
    }

    private static func values(_ s: AppSettings) -> [String: NSObject] {
        SettingsFileCheck.fileValues(s, omittingUnset: false).mapValues { ($0 as? NSObject) ?? NSNull() }
    }

    /// The keys whose file value differs between two settings (a key one side lacks counts as `NSNull`).
    private static func differing(_ a: AppSettings, _ b: AppSettings) -> Set<String> {
        let x = values(a), y = values(b)
        return Set(x.keys).union(y.keys).filter { !(x[$0] ?? NSNull()).isEqual(y[$0] ?? NSNull()) }
    }

    static func run() -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") restore: \(what)" + (ok || detail().isEmpty ? "" : " [\(detail())]"))
            if !ok { failed += 1 }
        }
        let tabs = SettingSpec.Tab.allCases.filter { $0 != .none }
        let changed = everythingChanged()
        let consentAndData = Set(keptByTab.values.flatMap { $0 })

        // A file at its defaults has nothing to restore.
        check("a default settings value has an empty plan on every tab (the button is hidden)",
              tabs.allSatisfy { RestorePlan.make(tab: $0, now: AppSettings()).isEmpty })
        let writtenDefault = SettingsFileCheck.read(SettingsFileFormat.render(AppSettings()), over: AppSettings()).settings
        check("a default file, written and read back, has an empty plan on every tab", tabs.allSatisfy { RestorePlan.make(tab: $0, now: writtenDefault).isEmpty })

        // §9's table, from the document.
        let plans = Dictionary(uniqueKeysWithValues: tabs.map { ($0, RestorePlan.make(tab: $0, now: changed)) })
        check("with every setting changed, each tab's changes are exactly the preferences §9 lists for it",
              tabs.allSatisfy { Set(plans[$0]?.changes.map(\.key) ?? ["?"]) == preferences[$0] }, "\(tabs.map { "\($0.rawValue): \(plans[$0]?.changes.map(\.key) ?? [])" })")
        check("each tab keeps the consent and data §9 lists for it, and those keys are never in a change, on any tab",
              tabs.allSatisfy { keptByTab[$0]?.isSubset(of: plans[$0]?.kept ?? []) == true }
              && plans.values.allSatisfy { Set($0.changes.map(\.key)).isDisjoint(with: consentAndData) && Set($0.kept).isDisjoint(with: $0.changes.map(\.key)) },
              "\(plans.values.map { "\($0.tab.rawValue) changes \($0.changes.map(\.key)) kept \($0.kept)" })")
        check("a change carries the value now and the default, as the file holds them (a null id for Apple)",
              plans[.translation]?.changes.first { $0.key == "customEngineID" }.map { ($0.now as? String) != nil && $0.default is NSNull } == true
              && plans[.general]?.changes.first { $0.key == "sourceLanguage" }.map { ($0.now as? String) == "ja" && ($0.default as? String) == "auto" } == true)

        // apply: only the changed keys, to their defaults; the file is kept first
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mwoyeo-restore-checks-\(getpid())")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        let original = SettingsFileFormat.render(changed)
        try? original.write(to: file)
        var onlyPreferences = true, defaultsWritten = true
        for tab in tabs {
            guard let plan = plans[tab] else { continue }
            var s = changed
            try? plan.apply(to: &s, file: file)
            let touched = differing(changed, s)
            onlyPreferences = onlyPreferences && touched == Set(plan.changes.map(\.key)) && touched.isDisjoint(with: consentAndData)
            defaultsWritten = defaultsWritten && RestorePlan.make(tab: tab, now: s).isEmpty
        }
        check("apply changes the keys of the plan and no other: no consent or data key moves, and no other tab's preference", onlyPreferences)
        check("after apply the tab is at its defaults (a plan for it is empty), the other tabs' preferences stay", defaultsWritten)
        var general = changed
        try? plans[.general]?.apply(to: &general, file: file)
        check("apply on General sets the language pair back and leaves a lens's look and an engine as they were",
              general.sourceLanguage == "auto" && general.targetLanguage == Languages.preferredTarget && general.lensStyle == .subtle
              && general.customEngineID == changed.customEngineID && general.engines == changed.engines && general.agentConnection && general.savesTranscripts)
        var translation = changed
        try? plans[.translation]?.apply(to: &translation, file: file)
        check("apply on Translation sends the engine back to Apple but keeps the engines, the glossary, the profiles and the amount of context",
              translation.customEngineID == nil && translation.engine == .auto && translation.profilePin == nil && translation.engines == changed.engines
              && translation.glossary == changed.glossary && translation.appProfiles == changed.appProfiles && translation.context == changed.context && translation.useLearned)

        // The file is kept: byte for byte, first, and an older copy is replaced
        let backup = RestorePlan.backupURL(for: file)
        check("apply copies settings.json to settings.json.before-restore, byte for byte", backup.lastPathComponent == "settings.json.before-restore" && (try? Data(contentsOf: backup)) == original)
        try? Data("older".utf8).write(to: backup)
        var again = changed
        try? plans[.appearance]?.apply(to: &again, file: file)
        check("an older settings.json.before-restore is replaced by the new copy", (try? Data(contentsOf: backup)) == original)
        let noFile = dir.appendingPathComponent("none/settings.json")
        var fromNothing = changed
        let missing: Error? = { do { try plans[.shortcuts]?.apply(to: &fromNothing, file: noFile); return nil } catch { return error } }()
        check("apply with no settings.json copies nothing and still restores", missing == nil && !FileManager.default.fileExists(atPath: RestorePlan.backupURL(for: noFile).path)
              && fromNothing.shortcuts == HotKeyAction.defaults)
        let blocked = dir.appendingPathComponent("blocked")
        try? FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let blockedFile = blocked.appendingPathComponent("settings.json")
        try? original.write(to: blockedFile)
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blocked.path)
        var stopped = changed
        let refused: Bool = { do { try plans[.general]?.apply(to: &stopped, file: blockedFile); return false } catch { return true } }()
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
        check("a copy that cannot be made stops the restore: the settings are not changed", refused && stopped == changed)

        // undo: the values of the plan, back; what changed since stays
        var restored = changed
        try? plans[.general]?.apply(to: &restored, file: file)
        restored.fontStyle = .rounded
        plans[.general]?.undo(&restored)
        check("undo writes back the values from before and only those keys: a setting changed since (the font) stays",
              restored.sourceLanguage == "ja" && restored.targetLanguage == changed.targetLanguage && restored.renderMode == .fast && restored.transcriptFormats == [.jsonl]
              && restored.fontStyle == .rounded && differing(restored, changed) == ["fontStyle"])
        var untouched = changed
        let empty = RestorePlan.make(tab: .appearance, now: AppSettings())
        try? empty.apply(to: &untouched, file: dir.appendingPathComponent("none/settings.json"))
        check("an empty plan applies to a value that is equal (the JSON round trip loses nothing)", empty.isEmpty && untouched == changed)
        check("a kept row can show its value: the file's value of the key", RestorePlan.value(of: "agentConnection", in: changed) == NSNumber(value: true)
              && RestorePlan.value(of: "profilePin", in: AppSettings()) == NSNull())
        return failed
    }
}
#endif
