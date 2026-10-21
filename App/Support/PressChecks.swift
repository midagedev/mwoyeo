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
    /// How long a Test may take to show its lines or its error: a service that starts waits for launchd (`ScriptConnection.startBudget`, 10 s) and runs two
    /// calls of at most `RewriteLimits.lineBudgetMs` each.
    private static let testBound = 25.0
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

        // MARK: Test, the button under the Script's editor (D12: it answered AXPress and showed nothing)
        let function = "function before(line, ctx) { return line + \"<\" }\nfunction after(src, dst, ctx) { return dst + \">\" }"
        let lens = MemoryTarget(id: bundle, name: "Example Press", kind: .profile, lensSource: "Controls and noise.", lensTranslation: "제어 및 소음.")
        model.settings.appProfiles = [profile]
        let prefilled = await pressTest("test-prefilled", target: lens, typed: nil, script: function, model: model)
        check("Test, with the sample the sheet prefilled from the lens and a script set through the accessibility server, answers AXPress and shows Before and After",
              prefilled.answer == .success && prefilled.rows(before: "Controls and noise.<", after: "제어 및 소음.>"), prefilled.note)
        // The sheet as the lens menu opens it for an app with no profile yet (film3): the script's first edit makes the profile from the draft.
        model.settings.appProfiles = []
        let fresh = MemoryTarget(id: bundle, name: "Example Press", lensBundleID: bundle, lensAppName: "Example Press", lensSource: "Controls and noise.", lensTranslation: "제어 및 소음.")
        let draft = await pressTest("test-draft", target: fresh, typed: nil, script: function, turnsOn: true, model: model)
        check("Test, in the sheet of an app that has no profile yet (its first edit makes it), answers AXPress and shows Before and After",
              draft.answer == .success && draft.rows(before: "Controls and noise.<", after: "제어 및 소음.>"), draft.note)
        // No line from a lens and none typed: the Test says so to assistive technology (disabled), instead of answering a press with nothing.
        model.settings.appProfiles = [profile]
        let empty = await pressTest("test-empty", target: MemoryTarget(id: bundle, name: "Example Press", kind: .profile), typed: nil, script: function, expectsRows: false, model: model)
        check("Test, with no line to test, is disabled for the accessibility server and shows nothing",
              empty.items.contains { $0.role == "AXButton" && $0.label == String(localized: "Test") && !$0.enabled } && !empty.rows(before: "", after: ""), empty.note)

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

    /// What pressing Test did, for `pressTest`.
    private struct Tested {
        var answer: AXError?
        var items: Items
        /// What was in the way: an element that was not found, or the tree the press left.
        var note: String
        /// Both lines the Test makes, as the sheet words them, are on screen.
        func rows(before: String, after: String) -> Bool {
            items.contains { $0.value == String(localized: "Before → \(before)") } && items.contains { $0.value == String(localized: "After → \(after)") }
        }
    }

    /// The Memory sheet of `target` with its Script editor open, `script` put in the editor and `typed` (when not nil) in the sample line through the
    /// accessibility server as an agent writes a field, then Test pressed the way `press` presses: what the tree holds when its two lines or the
    /// service's error come, or after `testBound`.
    private static func pressTest(_ name: String, target: MemoryTarget, typed: String?, script: String, turnsOn: Bool = false, expectsRows: Bool = true, model: AppModel) async -> Tested {
        let sheet = AppMemorySheet(target: target, model: model, height: 1100, customize: true, scriptOpen: true)
        let w = AccessibilityChecks.window(sheet, size: CGSize(width: 520, height: 1100), model: model, name: "press-\(name)")
        defer { w.orderOut(nil) }
        let title = w.title
        let editor = String(localized: "Script text"), sample = String(localized: "A line to test"), test = String(localized: "Test")
        let ready = await until(title) { $0.contains { $0.role == "AXTextArea" && $0.label == editor } && $0.contains { $0.role == "AXButton" && $0.label == test } }
        /// Writes the field's value as an agent does, then confirms it (`AXConfirm`: a text field takes what was written into its binding only then; the
        /// script's editor takes it as it is written).
        func set(_ role: String, _ label: String, _ text: String) -> Bool {
            guard let element = AccessibilityChecks.element(inWindowTitled: title, role: role, label: label) else { return false }
            let wrote = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success
            if role == "AXTextField" { AXUIElementPerformAction(element, kAXConfirmAction as CFString) }
            return wrote
        }
        let wrote = set("AXTextArea", editor, script)
        let typedIn = typed.map { set("AXTextField", sample, $0) } ?? true
        if turnsOn, let toggle = AccessibilityChecks.element(inWindowTitled: title, role: "AXCheckBox", label: String(localized: "Run this script")) {
            AXUIElementPerformAction(toggle, kAXPressAction as CFString)
        }
        let enabled = await until(title) { $0.contains { $0.role == "AXButton" && $0.label == test && $0.enabled } }
        var answer: AXError?
        if let button = AccessibilityChecks.element(inWindowTitled: title, role: "AXButton", label: test) {
            answer = AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
        let shown = await until(title, within: expectsRows ? testBound : 0) { items in items.contains { $0.value.hasPrefix(String(localized: "Before → \("")")) } }
        let after = await AccessibilityChecks.tree(ofWindowTitled: title)
        let appeared = shown.contains { $0.value.hasPrefix(String(localized: "Before → \("")")) }
        let held = after.first { $0.role == "AXTextArea" && $0.label == editor }?.value.count ?? 0
        print("check-logic: note press: \(name): script written \(wrote) (\(held) characters), sample written \(typedIn), on \(turnsOn), Test \(enabled.contains { $0.label == test && $0.enabled } ? "enabled" : "disabled") answer \(answer.map { "\($0.rawValue)" } ?? "none")")
        let lines = after.filter { $0.value.contains("→") || $0.value.contains("Line ") }.map { $0.line.trimmingCharacters(in: .whitespaces) }
        return Tested(answer: answer, items: after, note: "in \(ready.count) elements: script written \(wrote), sample written \(typedIn), answer \(answer.map { "\($0.rawValue)" } ?? "none"), appeared \(appeared), lines \(lines)")
    }

    /// The window's tree, read again until `done` holds for it (or `within` seconds).
    private static func until(_ title: String, within: Double = bound, _ done: (Items) -> Bool) async -> Items {
        var items = await AccessibilityChecks.tree(ofWindowTitled: title)
        for _ in 0..<Int(within * 10) where !done(items) {
            try? await Task.sleep(for: .milliseconds(100))
            items = await AccessibilityChecks.tree(ofWindowTitled: title)
        }
        return items
    }
}
#endif
