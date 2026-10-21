#if !MAS
import AppKit
import MwoyeoCore
import SwiftUI

/// The press checks of `--capture-ui … check-logic` (PASS/FAIL lines), or alone as `--capture-ui <dir> press-checks`: a control that opens something
/// (Customize and Script of the Memory sheet, a profile's row in Settings) answers `AXPress`, the one action VoiceOver's
/// "press" and an agent driving the app through Accessibility have, and the press does what a click does.
///
/// Each view is hosted in a window as the app hosts it and asked through the accessibility API from this process (`AXUIElementCreateApplication(getpid())`),
/// as an assistive app asks. D11 (film3, 2026-10-21): `.accessibilityElement(children: .ignore)` on a Button swapped its element for one with no actions,
/// so `perform AXPress` returned success and nothing opened; the label and the value were right, the press was not. A tree check cannot tell it: the
/// element is there, named and an AXButton.
@MainActor
enum PressChecks {
    /// How long a poll waits for SwiftUI to build the tree or to answer a press: a bound for a view that never gets there, not a wait (a poll ends the
    /// moment its condition holds).
    private static let bound = 6.0
    private static let bundle = "com.example.press"

    private typealias Items = [AccessibilityChecks.Item]

    /// What pressing one element said and did.
    private struct Press {
        /// The element as it was asked before the press; nil when the window never had it.
        var item: AccessibilityChecks.Item?
        /// The tree before the press and after the effect (or after the bound).
        var before: Items
        var after: Items
        /// What `AXUIElementPerformAction` answered.
        var answer: AXError?
        /// Whether the effect showed.
        var effected: Bool
        /// The elements of the role that was looked for, for a note when the one named was not there.
        var sameRole: [String]
        var actions: [String] { item?.actions ?? [] }
        var presses: Bool { actions.contains(kAXPressAction) }
    }

    static func run(_ model: AppModel) async -> Int {
        guard AccessibilityChecks.canAsk else {
            print("check-logic: SKIP press: the controls that open something answer AXPress (this process may not ask the accessibility server)")
            return 0
        }
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") press: \(what)" + (ok ? "" : note().isEmpty ? "" : " [\(note())]"))
            if !ok { failed += 1 }
        }
        let savedProfiles = model.settings.appProfiles, savedEngines = model.settings.engines, savedEngine = model.settings.customEngineID
        defer {
            model.settings.appProfiles = savedProfiles
            model.settings.engines = savedEngines
            model.settings.customEngineID = savedEngine
            model.memoryTarget = nil
        }
        let profile = AppProfile(bundleID: bundle, appName: "Example Press", source: "en", target: "ko")
        model.settings.appProfiles = [profile]
        model.settings.engines = []
        model.settings.customEngineID = nil
        model.memoryTarget = nil
        let target = MemoryTarget(id: bundle, name: "Example Press", kind: .profile)
        func has(_ items: Items, _ role: String, _ label: String) -> Bool { items.contains { $0.role == role && $0.label == label } }
        func note(_ p: Press) -> String {
            "actions \(p.actions), answer \(p.answer.map { "\($0.rawValue)" } ?? "none"), element \(p.item?.line.trimmingCharacters(in: .whitespaces) ?? "not found among \(p.sameRole)")"
        }

        // MARK: Customize, the disclosure row of the Memory sheet
        let customize = String(localized: "Customize"), script = String(localized: "Script")
        let summary = AppMemoryEditor(target: target, model: model).customizeSummary
        let c = await press("customize", AppMemorySheet(target: target, model: model, height: 1100, customize: false), size: CGSize(width: 520, height: 1100), model: model,
                            role: "AXButton", label: customize, ready: { has($0, "AXButton", customize) }, effect: { has($0, "AXButton", script) })
        check("Customize is named \"Customize\", says what differs from All apps as its value and hints \"Shows the options\" while shut",
              c.item?.value == summary && c.item?.help == String(localized: "Shows the options") && !has(c.before, "AXButton", script), "\(note(c)) in \(c.before.count) elements")
        check("Customize answers AXPress", c.presses, note(c))
        check("pressing Customize through the accessibility server opens it: the Script row appears and the hint says it collapses",
              c.effected && c.after.first { $0.role == "AXButton" && $0.label == customize }?.help == String(localized: "Collapses the options"), note(c))

        // MARK: Script, the disclosure row inside it
        let off = String(localized: "Off"), editor = String(localized: "Script text")
        let s = await press("script", AppMemorySheet(target: target, model: model, height: 1100, customize: true), size: CGSize(width: 520, height: 1100), model: model,
                            role: "AXButton", label: script, ready: { has($0, "AXButton", script) }, effect: { $0.contains { $0.label == editor } })
        check("Script is named \"Script\", its value the state of the script (Off), and its editor is not drawn while it is shut",
              s.item?.value == off && !s.before.contains { $0.label == editor }, note(s))
        check("Script answers AXPress", s.presses, note(s))
        check("pressing Script through the accessibility server opens its editor", s.effected, note(s))

        // MARK: a profile's row in Settings › Translation (and All apps')
        let settings = TranslationSettings()
        let rows: [(name: String, label: String, id: String)] = [("profile", ProfileWords.cut(profile.name, at: 32), profile.id), ("all-apps", String(localized: "All apps"), AppProfile.allAppsID)]
        for row in rows {
            model.memoryTarget = nil
            let r = await press("row-\(row.name)", settings, size: CGSize(width: 560, height: 900), model: model, role: "AXButton", label: row.label,
                                ready: { has($0, "AXButton", row.label) }, effect: { _ in model.memoryTarget?.id == row.id })
            check("the row \"\(row.label)\" answers AXPress, and pressing it opens that profile's sheet", r.presses && r.effected, note(r))
            check("the row \"\(row.label)\" says where it is used, its languages and what it keeps as its value", r.item?.value.isEmpty == false, note(r))
            model.memoryTarget = nil
        }

        return failed
    }

    /// `view` in a window; once `ready` holds for its tree, the `role` element named `label` is read and pressed through the accessibility server, and
    /// the tree is read until `effect` holds.
    private static func press<V: View>(_ name: String, _ view: V, size: CGSize, model: AppModel, role: String, label: String,
                                       ready: (Items) -> Bool, effect: (Items) -> Bool) async -> Press {
        let w = AccessibilityChecks.window(view, size: size, model: model, name: "press-\(name)")
        defer { w.orderOut(nil) }
        let title = w.title
        let before = await until(title, ready)
        let item = before.first { $0.role == role && $0.label == label }
        var answer: AXError?
        if let element = AccessibilityChecks.element(inWindowTitled: title, role: role, label: label) {
            answer = AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
        let after = await until(title, effect)
        print("check-logic: note press: \(name): \(item?.line.trimmingCharacters(in: .whitespaces) ?? "not found") actions \(item?.actions ?? []) answer \(answer.map { "\($0.rawValue)" } ?? "none")")
        return Press(item: item, before: before, after: after, answer: answer, effected: effect(after),
                     sameRole: before.filter { $0.role == role }.map { "\($0.line.trimmingCharacters(in: .whitespaces)) \($0.actions)" })
    }

    /// The window's tree, read again until `done` holds for it (or `bound` seconds).
    private static func until(_ title: String, _ done: (Items) -> Bool) async -> Items {
        var items = await AccessibilityChecks.tree(ofWindowTitled: title)
        for _ in 0..<Int(bound * 10) where !done(items) {
            try? await Task.sleep(for: .milliseconds(100))
            items = await AccessibilityChecks.tree(ofWindowTitled: title)
        }
        return items
    }
}
#endif
