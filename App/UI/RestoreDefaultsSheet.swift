import MwoyeoCore
import Observation
import SwiftUI

/// The words of Restore Defaults (design names-and-context §9): the title of a key as its tab says it, and a value as the sheet's rows say it.
/// Pure over the file's values (`RestorePlan` hands them as JSON objects) and the settings, so a check can read every row without a window.
enum RestoreWords {
    static func tabTitle(_ tab: SettingSpec.Tab) -> String {
        switch tab {
        case .general: String(localized: "General")
        case .translation: String(localized: "Translation")
        case .appearance: String(localized: "Appearance")
        case .shortcuts: String(localized: "Shortcuts")
        case .about: String(localized: "About")
        case .none: ""
        }
    }

    /// The key as its control is named in Settings (an unknown key says itself).
    static func title(_ key: String) -> String {
        switch key {
        case "sourceLanguage": String(localized: "Translate from")
        case "targetLanguage": String(localized: "Translate to")
        case "renderMode": String(localized: "Style")
        case "settleDelay": String(localized: "Rewrite after stillness")
        case "framesPerSecond": String(localized: "Screen checks")
        case "transcriptFormats": String(localized: "Transcript files")
        case "savesTranscripts": String(localized: "Save transcripts")
        case "exportFolder": String(localized: "Folder")
        case "agentConnection": String(localized: "Connect an agent (MCP)")
        case "engine": String(localized: "Apple Translation")
        case "customEngineID": String(localized: "Translation engine")
        case "cacheSize": String(localized: "Recent translations")
        case "paragraphReader": String(localized: "Paragraphs")
        case "profilePin": String(localized: "Profile")
        case "context": String(localized: "Context")
        case "useLearned": String(localized: "Learn names and terms")
        case "engines": String(localized: "Engines")
        case "glossary": String(localized: "Glossary")
        case "glossaryApply": String(localized: "Use them")
        case "profiles": String(localized: "Profiles")
        case "rewrites": String(localized: "Rewrites")
        case "script": String(localized: "Script")
        case "useInpaintingModel": String(localized: "Erase from textured backgrounds with AI")
        case "fontStyle": String(localized: "Font")
        case "boxOpacity": String(localized: "Opacity")
        case "lensStyle": String(localized: "Lens style")
        case "lensTint": String(localized: "Color")
        case "lensTabVisibility": String(localized: "Name tag")
        case "lensTabPosition": String(localized: "Name tag position")
        case "shortcuts": String(localized: "Shortcuts")
        case "checksForUpdates": String(localized: "Check for updates")
        default: key
        }
    }

    /// One value as a row says it ("Korean", "on", "Local Qwen"); `v` is what the file holds under `key` (`NSNull` for none).
    static func value(_ key: String, _ v: NSObject, in settings: AppSettings) -> String {
        func choice<T: RawRepresentable>(_ type: T.Type, _ title: (T) -> String) -> String where T.RawValue == String {
            (v as? String).flatMap { T(rawValue: $0) }.map(title) ?? "\(v)"
        }
        if v is NSNull {
            switch key {
            case "customEngineID": return String(localized: "Apple Translation")
            case "profilePin": return String(localized: "Auto")
            case "exportFolder": return String(localized: "None chosen")
            default: return String(localized: "none")
            }
        }
        switch key {
        case "sourceLanguage", "targetLanguage": return Languages.name(v as? String ?? "")
        case "renderMode": return choice(RenderMode.self, \.title)
        case "engine": return choice(TranslationEngineChoice.self, \.title)
        case "paragraphReader": return choice(ParagraphReader.self, \.title)
        case "fontStyle": return choice(FontStyleChoice.self, \.title)
        case "lensStyle": return choice(LensStyle.self, \.title)
        case "lensTint": return choice(LensTint.self, \.title)
        case "lensTabVisibility": return choice(LensTabVisibility.self, \.title)
        case "lensTabPosition": return choice(LensTabPosition.self, \.title)
        case "glossaryApply": return choice(EntryApply.self, applyWords)
        case "savesTranscripts", "agentConnection", "useLearned", "useInpaintingModel":
            return (v as? NSNumber)?.boolValue == true ? String(localized: "on") : String(localized: "off")
        case "settleDelay": return String(localized: "\((v as? NSNumber)?.doubleValue ?? 0, specifier: "%.1f") s")
        case "framesPerSecond":
            switch (v as? NSNumber)?.intValue {
            case 4: return String(localized: "Saver (4 fps)")
            case 8: return String(localized: "Normal (8 fps)")
            case 15: return String(localized: "Fast (15 fps)")
            case let n?: return String(localized: "\(n) fps")
            case nil: return "\(v)"
            }
        case "boxOpacity": return "\(Int((((v as? NSNumber)?.doubleValue ?? 0) * 100).rounded()))%"
        case "cacheSize": return ((v as? NSNumber)?.intValue ?? 0).formatted()
        case "rewrites": return ((v as? [Any])?.count ?? 0).formatted()
        case "script":
            let d = v as? [String: Any]
            let on = !((d?["source"] as? String) ?? "").isEmpty && (d?["on"] as? Bool) != false
            return on ? String(localized: "on") : String(localized: "off")
        case "transcriptFormats": return ((v as? [String]) ?? []).map { $0.uppercased() }.joined(separator: ", ")
        case "customEngineID":
            let id = (v as? String).flatMap { UUID(uuidString: $0) }
            return settings.engines.first { $0.id == id }?.name ?? String(localized: "Apple Translation")
        case "profilePin":
            let id = v as? String
            if id == AppProfile.allAppsID { return String(localized: "All Apps Only") }
            return settings.appProfiles.first { $0.id == id }?.name ?? "\(v)"
        case "exportFolder": return ((v as? String).map { ($0 as NSString).abbreviatingWithTildeInPath }) ?? "\(v)"
        case "engines": return String(localized: "\((v as? [Any])?.count ?? 0) added")
        case "profiles": return String(localized: "\((v as? [Any])?.count ?? 0) profiles")
        case "glossary": return String(localized: "\(settings.glossaryPairs.count) pairs")
        case "context": return ProfileWords.amount(settings.context)
        case "shortcuts": return shortcuts(v)
        default: return "\(v)"
        }
    }

    /// "Tell the translator", "Swap into the text", "Both": the same three words as the glossary's pop-up, without a cost.
    static func applyWords(_ apply: EntryApply) -> String {
        switch apply {
        case .hint: String(localized: "Tell the translator")
        case .replace: String(localized: "Swap into the text")
        case .both: String(localized: "Both")
        }
    }

    /// "Add Lens ⌃⌥L · Show Original ⌃⌥O": the actions that have a shortcut, in the order of Settings › Shortcuts.
    private static func shortcuts(_ v: NSObject) -> String {
        let table = v as? [String: Any] ?? [:]
        let set = HotKeyAction.allCases.compactMap { action in
            ((table[action.rawValue] as? [String: Any])?["display"] as? String).map { "\(action.title) \($0)" }
        }
        return set.isEmpty ? String(localized: "none") : set.joined(separator: " · ")
    }

    /// A row of "Changes": "Translate to: Korean → English".
    static func changeLine(_ change: RestorePlan.Change, in settings: AppSettings) -> String {
        "\(title(change.key)): \(value(change.key, change.now, in: settings)) → \(value(change.key, change.default, in: settings))"
    }

    /// The kept keys that hold something now, each as a row of "Kept": "Connect an agent (MCP): on — kept; turn it off by hand". A consent is
    /// turned off by hand; data is deleted item by item.
    static func keptLines(_ plan: RestorePlan, in settings: AppSettings, defaults: AppSettings = AppSettings()) -> [String] {
        plan.kept.compactMap { key in
            let now = RestorePlan.value(of: key, in: settings)
            guard !now.isEqual(RestorePlan.value(of: key, in: defaults)) else { return nil }
            let tail = SettingSpec.columns[key]?.nature == .consent ? String(localized: "kept; turn it off by hand") : String(localized: "kept")
            return "\(title(key)): \(value(key, now, in: settings)) — \(tail)"
        }
    }
}

/// "Restore Defaults…" at the foot of a tab (design §9), drawn only while a preference of the tab differs from its default: hidden, not disabled,
/// so a tab at its defaults is today's. The sheet is the tab's (`restoreDefaultsSheet`), not this view's: the button leaves when the restore is done,
/// and the sheet has still to say so.
struct RestoreDefaultsFoot: View {
    @Environment(AppModel.self) private var model
    let tab: SettingSpec.Tab
    let present: () -> Void

    /// Whether the button shows: the plan of the tab has a change.
    static func shows(_ tab: SettingSpec.Tab, in settings: AppSettings) -> Bool {
        !RestorePlan.make(tab: tab, now: settings).isEmpty
    }

    var body: some View {
        if Self.shows(tab, in: model.settings) {
            Section { Button("Restore Defaults…", action: present) }
        }
    }
}

extension View {
    /// The sheet of "Restore Defaults…" for `tab`, kept on a view that stays while the button comes and goes.
    func restoreDefaultsSheet(tab: SettingSpec.Tab, isPresented: Binding<Bool>) -> some View {
        modifier(RestoreDefaultsSheetModifier(tab: tab, isPresented: isPresented))
    }
}

private struct RestoreDefaultsSheetModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    let tab: SettingSpec.Tab
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) { RestoreDefaultsSheet(tab: tab, model: model) }
    }
}

/// What the Restore sheet does, apart from drawing it (design §9): the plan the person read, applied once they say so, and undone if they ask.
/// `check-logic` drives these same calls on a scratch settings file.
@MainActor @Observable
final class RestoreDefaultsFlow {
    enum Phase {
        /// The sheet lists the plan and waits for Cancel or Restore.
        case asking(RestorePlan)
        /// The plan was applied (settings.json copied first): "Restored n settings." with Undo.
        case restored(RestorePlan)
        /// Undo wrote the old values back.
        case undone
        /// The copy of settings.json could not be made: nothing was changed.
        case failed
    }

    private(set) var phase: Phase
    @ObservationIgnored private let model: AppModel

    init(tab: SettingSpec.Tab, model: AppModel) {
        self.model = model
        phase = .asking(RestorePlan.make(tab: tab, now: model.settings))
    }

    func restore() {
        guard case .asking(let plan) = phase else { return }
        do {
            try plan.apply(to: &model.settings, file: model.settingsFile.url)
            phase = .restored(plan)
        } catch {
            phase = .failed
        }
    }

    func undo() {
        guard case .restored(let plan) = phase else { return }
        plan.undo(&model.settings)
        phase = .undone
    }
}

/// The sheet (design §9, 420 pt): "Changes" rows "<title>: <now> → <default>", "Kept" rows for the tab's consent and data, Cancel and Restore.
/// settings.json is copied to `settings.json.before-restore` first; then "Restored n settings." with Undo (writes back only those keys) and Done.
/// The plan is `RestorePlan`'s (apply and undo are its own); this view only reads it out and asks.
struct RestoreDefaultsSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let model: AppModel
    private let tab: SettingSpec.Tab
    @State private var flow: RestoreDefaultsFlow

    /// - `restoring`: for the capture harness, the sheet as it is after Restore was pressed.
    init(tab: SettingSpec.Tab, model: AppModel, restoring: Bool = false) {
        self.tab = tab
        self.model = model
        let flow = RestoreDefaultsFlow(tab: tab, model: model)
        if restoring { flow.restore() }
        _flow = State(initialValue: flow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore Defaults for \(RestoreWords.tabTitle(tab))").font(.headline)
            switch flow.phase {
            case .asking(let plan): asking(plan)
            case .restored(let plan):
                done(String(localized: "Restored \(plan.changes.count) settings."),
                     detail: String(localized: "The file as it was is kept as settings.json.before-restore."), canUndo: true)
            case .undone: done(String(localized: "Back as it was."), detail: nil, canUndo: false)
            case .failed:
                done(String(localized: "Nothing was changed."),
                     detail: String(localized: "A copy of settings.json could not be made, so the settings stay as they are."), canUndo: false)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func asking(_ plan: RestorePlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Changes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(plan.changes, id: \.key) { change in
                    Text(verbatim: RestoreWords.changeLine(change, in: model.settings)).fixedSize(horizontal: false, vertical: true)
                }
            }
            let kept = RestoreWords.keptLines(plan, in: model.settings)
            if !kept.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Kept").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(kept, id: \.self) { line in
                        Text(verbatim: line).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Restore") { flow.restore() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func done(_ line: String, detail: String?, canUndo: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: line)
                if let detail { Text(verbatim: detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            HStack {
                Spacer()
                if canUndo { Button("Undo") { flow.undo() } }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
