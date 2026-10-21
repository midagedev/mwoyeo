#if !MAS
import AppKit
import MwoyeoCore
import SwiftUI

/// The checks of Restore Defaults per tab on the UI side (design names-and-context §9, round ui-all R6), run by `--capture-ui … check-logic` and
/// alone as `restore-checks`. The plan, its apply and its undo are `RestorePlan`'s (the agents round checks those); these pin what the tabs and the
/// sheet make of it: the button is hidden at defaults and shown after one preference changes, on its own tab only; consent and data never bring the
/// button; every key the sheet lists has its words; and the flow keeps what it must keep.
///
/// Each check was shown FAIL on a mutation of the code it guards (the round report lists them). No setting is printed.
@MainActor
enum RestoreChecks {
    /// The tabs that carry the button (About has none).
    static let tabs: [SettingSpec.Tab] = [.general, .translation, .appearance, .shortcuts]

    static func run(_ model: AppModel) async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") restore defaults: \(what)" + (ok ? "" : note().isEmpty ? "" : " [\(note())]"))
            if !ok { failed += 1 }
        }
        let defaults = AppSettings()

        // MARK: the button's rule, on values (no window)
        check("at defaults no tab shows Restore Defaults…", tabs.allSatisfy { !RestoreDefaultsFoot.shows($0, in: defaults) },
              "\(tabs.filter { RestoreDefaultsFoot.shows($0, in: defaults) })")
        let changed = Self.changedPerTab(defaults)
        for tab in tabs {
            let shown = tabs.filter { RestoreDefaultsFoot.shows($0, in: changed[tab]!) }
            check("after one preference of \(tab.rawValue) changes, Restore Defaults… shows on \(tab.rawValue) and on no other tab", shown == [tab],
                  "\(shown.map(\.rawValue))")
        }
        var kept = defaults
        kept.savesTranscripts = true
        kept.agentConnection = true
        kept.useLearned = true
        kept.context = AppContextOverride(mode: .nearby)
        kept.glossary = "勇者 = Hero"
        kept.glossaryApply = .both
        kept.engines = [EngineConfig(name: "Restore check", kind: .deepL(baseURL: URL(string: "https://api-free.deepl.invalid/")!, formality: nil))]
        kept.appProfiles = [AppProfile(bundleID: "com.example.restore", appName: "Restore", source: "ja", target: "ko")]
        check("a consent or a data key that differs never brings the button: it is listed as kept",
              tabs.allSatisfy { !RestoreDefaultsFoot.shows($0, in: kept) }
              && RestorePlan.make(tab: .translation, now: kept).kept.contains("useLearned")
              && RestorePlan.make(tab: .general, now: kept).kept.contains("agentConnection")
              && !RestoreWords.keptLines(RestorePlan.make(tab: .translation, now: kept), in: kept).isEmpty
              && !RestoreWords.keptLines(RestorePlan.make(tab: .general, now: kept), in: kept).isEmpty,
              "\(tabs.filter { RestoreDefaultsFoot.shows($0, in: kept) })")

        // MARK: the words: every row of the sheet has its own
        let preferenceKeys = SettingSpec.all.filter { $0.nature == .preference && tabs.contains($0.tab ?? .none) }.map(\.key)
        let untitled = preferenceKeys.filter { RestoreWords.title($0) == $0 }
        check("every preference key of the four tabs has a title in the sheet (none says its settings.json key)", untitled.isEmpty && !preferenceKeys.isEmpty,
              "\(untitled)")
        var lines: [String] = []
        for tab in tabs { lines += RestorePlan.make(tab: tab, now: changed[tab]!).changes.map { RestoreWords.changeLine($0, in: changed[tab]!) } }
        check("each change reads \"<title>: <now> → <default>\", and its two values differ in words",
              lines.count == tabs.count && lines.allSatisfy { line in
                  let parts = line.components(separatedBy: " → ")
                  return parts.count == 2 && parts[0].contains(": ") && parts[0].components(separatedBy: ": ").last != parts[1]
              }, "\(lines)")

        // MARK: the flow: restores the preferences of the tab and nothing else, copies the file first, and Undo writes those keys back
        let savedSettings = model.settings
        defer { model.settings = savedSettings }
        let savedFile = try? Data(contentsOf: model.settingsFile.url)
        defer {
            if let savedFile { try? savedFile.write(to: model.settingsFile.url) } else { try? FileManager.default.removeItem(at: model.settingsFile.url) }
            try? FileManager.default.removeItem(at: RestorePlan.backupURL(for: model.settingsFile.url))
        }
        model.settings = defaults
        model.settings.cacheSize = defaults.cacheSize == 20000 ? 1000 : 20000
        model.settings.useLearned = true
        model.settings.glossary = "勇者 = Hero"
        model.settings.targetLanguage = Languages.targets.first { $0 != defaults.targetLanguage } ?? "ja"
        let target = model.settings.targetLanguage
        let flow = RestoreDefaultsFlow(tab: .translation, model: model)
        flow.restore()
        var restored = 0
        if case .restored(let plan) = flow.phase { restored = plan.changes.count }
        check("Restore on Translation sets its preferences to their defaults and keeps what is consent, data or on another tab",
              model.settings.cacheSize == defaults.cacheSize && model.settings.useLearned && model.settings.glossary == "勇者 = Hero"
              && model.settings.targetLanguage == target && restored == 1, "cache \(model.settings.cacheSize), restored \(restored)")
        let backup = (try? JSONSerialization.jsonObject(with: Data(contentsOf: RestorePlan.backupURL(for: model.settingsFile.url)))) as? [String: Any]
        check("settings.json is copied to settings.json.before-restore first: the copy holds the value that was restored away",
              (backup?["cacheSize"] as? Int).map { $0 != defaults.cacheSize } == true, "\(String(describing: backup?["cacheSize"]))")
        flow.undo()
        check("Undo writes back only the restored keys, and the sheet says so",
              model.settings.cacheSize != defaults.cacheSize && model.settings.targetLanguage == target && { if case .undone = flow.phase { true } else { false } }())

        // MARK: the tabs as the window draws them (the accessibility tree is the instrument)
        guard AccessibilityChecks.canAsk else {
            print("check-logic: SKIP restore defaults: the tabs as the window draws them (this process may not ask the accessibility server)")
            return failed
        }
        let button = String(localized: "Restore Defaults…")
        let views: [(SettingSpec.Tab, AnyView, CGFloat)] = [(.general, AnyView(GeneralSettings()), 1400), (.translation, AnyView(TranslationSettings()), 1500),
                                                          (.appearance, AnyView(AppearanceSettings()), 900), (.shortcuts, AnyView(ShortcutSettings()), 700)]
        for (tab, view, height) in views {
            model.settings = defaults
            let atDefaults = await AccessibilityChecks.hostedTree(view, size: CGSize(width: 560, height: height), model: model, name: "restore-\(tab.rawValue)-default")
            model.settings = changed[tab]!
            let after = await AccessibilityChecks.hostedTree(view, size: CGSize(width: 560, height: height), model: model, name: "restore-\(tab.rawValue)-changed")
            check("\(tab.rawValue): no Restore Defaults… button at defaults, one at the foot after a change (\(atDefaults.count), \(after.count) elements)",
                  !atDefaults.contains { $0.label == button } && after.contains { $0.label == button && $0.role == "AXButton" } && after.count > 2,
                  "default \(atDefaults.contains { $0.label == button }), changed \(after.contains { $0.label == button })")
            let unnamed = AccessibilityChecks.unlabeled(after)
            check("\(tab.rawValue): with the button shown every control still has a name", unnamed.isEmpty, unnamed.map(\.line).joined(separator: "; "))
        }
        return failed
    }

    /// For each tab, the defaults with one preference of that tab changed.
    static func changedPerTab(_ defaults: AppSettings) -> [SettingSpec.Tab: AppSettings] {
        var general = defaults, translation = defaults, appearance = defaults, shortcuts = defaults
        general.targetLanguage = Languages.targets.first { $0 != defaults.targetLanguage } ?? "ja"
        translation.cacheSize = defaults.cacheSize == 20000 ? 1000 : 20000
        appearance.boxOpacity = defaults.boxOpacity == 0.7 ? 0.8 : 0.7
        shortcuts.shortcuts = [:]
        return [.general: general, .translation: translation, .appearance: appearance, .shortcuts: shortcuts]
    }
}
#endif
