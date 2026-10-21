#if !MAS
import AppKit
import MwoyeoCore
import SwiftUI

/// The accessibility checks of `--capture-ui … check-logic` (PASS/FAIL lines), and the probe behind them (`a11y-tree`: the accessibility
/// tree of each audited window as a screen reader gets it, one line per element, into `a11y-<view>.txt`).
///
/// What is checked: Reduce Motion holds the lens glow and the SwiftUI motion still; the lens is one element a screen reader can name,
/// read and act on; the picker can place a lens without a pointer; and no control or image of Settings, Onboarding, the menu panel and
/// the engine sheet is without a name a screen reader can say.
///
/// macOS has no programmatic audit like iOS's `performAccessibilityAudit`, so the audit walks the tree itself, through the accessibility
/// API an assistive app uses (VoiceOver, Accessibility Inspector): every view is hosted in a window as the app hosts it. What it cannot
/// say is whether a label is a good one, or the order the elements are read in: that is the checklist for a person with VoiceOver on.
@MainActor
enum AccessibilityChecks {
    /// PASS/FAIL lines and their count of failures.
    private final class Report {
        var failed = 0
        func check(_ what: String, _ ok: Bool, detail: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") accessibility: \(what)")
            if !ok {
                failed += 1
                let d = detail()
                if !d.isEmpty { print("check-logic: note accessibility: \(d)") }
            }
        }
    }

    /// One element of the tree.
    struct Item: Sendable {
        var depth: Int
        var role: String
        var subrole: String
        var label: String
        var value: String
        var help: String
        var enabled: Bool
        var actions: [String] = []
        /// The element's hit area, as an assistive app reads it (zero when it says none).
        var size = CGSize.zero

        var line: String {
            let text = [label.isEmpty ? "" : "label=\"\(label)\"", value.isEmpty ? "" : "value=\"\(value.prefix(60))\"",
                        help.isEmpty ? "" : "help=\"\(help.prefix(40))\"", enabled ? "" : "disabled"].filter { !$0.isEmpty }.joined(separator: " ")
            return String(repeating: "  ", count: depth) + role + (subrole.isEmpty ? "" : "/" + subrole) + (text.isEmpty ? "" : "  " + text)
        }
    }

    /// Roles a person operates: each needs a name a screen reader can say.
    private static let controlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXTextField", "AXTextArea", "AXComboBox",
        "AXDisclosureTriangle", "AXIncrementor", "AXSwitch",
    ]
    /// The scroll bar's own parts: the system names them.
    private static let systemSubroles: Set<String> = ["AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage"]
    /// The roles that are one button (the probe writes their sizes), and the window's own buttons (the system draws those, at its own size).
    private static let buttonRoles: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton"]
    private static let windowButtonSubroles: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]
    /// The smallest hit area of a control on macOS (HIG, Accessibility: "macOS | 28x28 pt | 20x20 pt"; ui-audit-1-1-5 X1).
    static let minimumHit: CGFloat = 20

    // MARK: - Walking the tree

    /// One attribute of `element` as an accessibility client reads it.
    private nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private nonisolated static func string(_ element: AXUIElement, _ name: String) -> String {
        let value = attribute(element, name)
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    private nonisolated static func size(of element: AXUIElement) -> CGSize {
        var size = CGSize.zero
        if let v = attribute(element, kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() { AXValueGetValue(v as! AXValue, .cgSize, &size) }
        return size
    }

    /// The name a screen reader says for `element`: its description, else its title, else the text of the element that titles it.
    private nonisolated static func name(of element: AXUIElement) -> String {
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute] {
            let s = string(element, attribute).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
        }
        if let titled = attribute(element, kAXTitleUIElementAttribute), CFGetTypeID(titled) == AXUIElementGetTypeID() {
            return string(titled as! AXUIElement, kAXValueAttribute)
        }
        return ""
    }

    /// Whether this process may ask the accessibility server about itself, as VoiceOver and Accessibility Inspector do.
    /// (A process started from a terminal that has the permission has it too.)
    static var canAsk: Bool { AXIsProcessTrusted() }

    /// The tree of the window titled `title` in this process, read through the accessibility API an assistive app uses: the real tree, SwiftUI's
    /// included, which a call on the hosting view does not give. The asking runs ON the main thread: for its own process the API answers in
    /// process, on the calling thread, so a walk from another thread ran SwiftUI's graph there and deadlocked with a layout pass on main (each
    /// held the lock the other waited for; check-logic hung 53 min under load, 2026-10-21).
    @MainActor
    static func tree(ofWindowTitled title: String) async -> [Item] {
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(app, 10)
        var items: [Item] = []
        func walk(_ element: AXUIElement, _ depth: Int) {
            guard depth < 40, items.count < 4000 else { return }
            var names: CFArray?
            AXUIElementCopyActionNames(element, &names)
            items.append(Item(depth: depth, role: string(element, kAXRoleAttribute), subrole: string(element, kAXSubroleAttribute),
                              label: name(of: element), value: string(element, kAXValueAttribute), help: string(element, kAXHelpAttribute),
                              enabled: (attribute(element, kAXEnabledAttribute) as? Bool) ?? true,
                              actions: ((names as? [String]) ?? []).map { raw in
                                  // A custom action comes as "Name:<name>\nTarget:…\nSelector:…".
                                  let first = raw.split(separator: "\n").first.map(String.init) ?? raw
                                  return first.hasPrefix("Name:") ? String(first.dropFirst(5)) : first
                              },
                              size: size(of: element)))
            for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth + 1) }
        }
        for window in (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] where string(window, kAXTitleAttribute) == title {
            walk(window, 0)
        }
        return items
    }

    /// The controls and images of `items` that a screen reader could not name.
    static func unlabeled(_ items: [Item]) -> [Item] {
        items.filter { ($0.role == "AXImage" || controlRoles.contains($0.role)) && $0.label.isEmpty && !systemSubroles.contains($0.subrole) }
    }

    /// Controls that say the same thing as another of the view and nothing to tell them apart (no value, no help): "Record Shortcut" five
    /// times says nothing about which row. Radio buttons (tabs, segments) are told apart by their own state.
    static func ambiguous(_ items: [Item]) -> [String] {
        var seen: [String: Int] = [:]
        for item in items where controlRoles.contains(item.role) && item.role != "AXRadioButton" && !item.label.isEmpty
            && item.value.isEmpty && item.help.isEmpty && !systemSubroles.contains(item.subrole) {
            seen["\(item.role) \"\(item.label)\"", default: 0] += 1
        }
        return seen.filter { $0.value > 1 }.map { "\($0.key) ×\($0.value)" }.sorted()
    }

    /// The icon buttons of `items` (ui-audit-1-1-5 X1). The tree does not say what a button draws (SwiftUI gives a text button its words as
    /// the description, as it gives an icon one), so an icon is told by what it leaves out: a button no wider than 1.3 times its height (text
    /// is wider; the borderless text buttons are 16 pt high by design and are not this audit's), and a menu with no value (a picker says its
    /// choice; a menu with only a glyph, the ⋯, says nothing).
    static func iconButtons(_ items: [Item]) -> [Item] {
        items.filter { item in
            guard item.size != .zero, !windowButtonSubroles.contains(item.subrole), !systemSubroles.contains(item.subrole) else { return false }
            switch item.role {
            case "AXButton": return item.size.width <= 1.3 * item.size.height
            case "AXMenuButton", "AXPopUpButton": return item.value.isEmpty
            default: return false
            }
        }
    }

    /// Those under the macOS minimum hit area (20 × 20 pt) in either direction.
    static func smallIconButtons(_ items: [Item]) -> [Item] {
        iconButtons(items).filter { $0.size.width < minimumHit || $0.size.height < minimumHit }
    }

    private static func sizes(_ items: [Item]) -> String {
        items.map { "\($0.label.isEmpty ? $0.role : $0.label) \(Int($0.size.width.rounded()))×\(Int($0.size.height.rounded()))" }.joined(separator: ", ")
    }

    // MARK: - Hosting

    /// A view shown in a window as the app shows it, and the tree it gives after `settle` seconds.
    static func hostedTree<V: View>(_ view: V, size: CGSize, model: AppModel, name: String, settle: Double = 1.0) async -> [Item] {
        let title = "mwoyeo-a11y-\(name)"
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        w.title = title
        w.contentView = NSHostingView(rootView: view.environment(model))
        w.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.frame.height ?? 900) - 60))
        w.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(settle))
        // SwiftUI builds its tree as it is asked and keeps filling it for a moment: the tree counts once two reads in a row agree.
        var items = await tree(ofWindowTitled: title)
        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(400))
            let next = await tree(ofWindowTitled: title)
            // 2026-10-19 (t3m1): two empty reads in a row are not agreement. Under load the window is not in the assistive tree yet, and
            // a view then reported "0 elements" (settings-general, engine-sheet-form, engine-sheet: 3 of 6 check-logic runs, never twice the
            // same view). Not reproducible on demand, so there is no FAIL-first line for this one.
            let same = !next.isEmpty && next.map(\.line) == items.map(\.line)
            items = next
            if same { break }
        }
        w.orderOut(nil)
        return items
    }

    /// The views the audit covers: Settings (every tab), Onboarding, the menu panel (empty, a lens row), the engine sheet (the list, a form),
    /// and the image window.
    static func audited(_ model: AppModel) async -> [(name: String, items: [Item])] {
        var out: [(String, [Item])] = []
        let savedTab = model.settingsTab
        for (name, tab) in [("settings-general", SettingsTab.general), ("settings-translation", .translation), ("settings-appearance", .appearance),
                            ("settings-shortcuts", .shortcuts), ("settings-about", .about)] {
            model.settingsTab = tab
            out.append((name, await hostedTree(SettingsView(), size: CGSize(width: 560, height: 520), model: model, name: name, settle: 2)))
        }
        model.settingsTab = savedTab
        out.append(("onboarding", await hostedTree(OnboardingView(close: {}), size: CGSize(width: 600, height: 760), model: model, name: "onboarding")))
        out.append(("menu", await hostedTree(MenuPanel(), size: CGSize(width: 340, height: 400), model: model, name: "menu")))
        var lens = RegionConfig(name: "Safari", rect: CGRect(x: 100, y: 100, width: 400, height: 200))
        lens.follow(nil)
        out.append(("menu-lens-row", await hostedTree(RegionRow(region: lens), size: CGSize(width: 340, height: 80), model: model, name: "menu-lens-row")))
        // The row's trash button is drawn under the pointer only; this is the row with the pointer on it.
        out.append(("menu-lens-row-hover", await hostedTree(RegionRow(region: lens, hovering: true), size: CGSize(width: 340, height: 80), model: model, name: "menu-lens-row-hover")))
        out.append(("menu-engine-notice", await hostedTree(EngineNotice(headline: "Gemini unavailable · using Apple", reason: "The engine did not accept the key.",
                                                                        useApple: {}, dismiss: {}),
                                                           size: CGSize(width: 340, height: 80), model: model, name: "menu-engine-notice")))
        // Settings › Translation with an added engine and an app profile: their ⋯ menus are on screen only then.
        let savedEngines = model.settings.engines, savedApps = model.settings.appProfiles
        model.settings.engines = [EngineConfig(name: "Gemini", kind: .openAICompatible(baseURL: URL(string: "https://gemini.example.invalid/v1beta/openai/")!,
                                                                                       model: "gemini-3.1-flash-lite", thinking: .off, extraHeaders: [:]))]
        model.settings.appProfiles = [AppProfile(bundleID: "com.example.a11y", appName: "Example Chat", source: "en", target: "ko")]
        out.append(("settings-translation-rows", await hostedTree(TranslationSettings(), size: CGSize(width: 560, height: 900), model: model, name: "settings-translation-rows", settle: 2)))
        model.settings.engines = savedEngines
        model.settings.appProfiles = savedApps
        out.append(("engine-sheet", await hostedTree(EngineSheet(), size: CGSize(width: 480, height: 560), model: model, name: "engine-sheet")))
        let form = EngineConfig(name: "Gemini", kind: .openAICompatible(baseURL: URL(string: "https://gemini.example.invalid/v1beta/openai/")!,
                                                                         model: "gemini-3.1-flash-lite", thinking: .off, extraHeaders: [:]))
        out.append(("engine-sheet-form", await hostedTree(EngineSheet(autopilot: .init(setup: EngineShare.encode(form), key: "sk-test-a11y", allow: true)),
                                                          size: CGSize(width: 480, height: 560), model: model, name: "engine-sheet-form", settle: 4)))
        // The Memory sheet of an app with a note, a name (its details open) and a learned-free profile: every control of it is named.
        let savedProfiles = model.settings.appProfiles
        model.settings.appProfiles = [AppProfile(bundleID: "com.example.a11y", appName: "Example Chat", source: "en", target: "ko", note: "casual",
                                                 entries: [MemoryEntry(src: "Alice", dst: "앨리스", addressing: [Addressing(to: "Bob", register: .polite)])],
                                                 context: AppContextOverride(mode: .conversation))]
        out.append(("memory-sheet", await hostedTree(AppMemorySheet(bundleID: "com.example.a11y", model: model, openDetails: [0]),
                                                     size: CGSize(width: 520, height: 640), model: model, name: "memory-sheet", settle: 2)))
        model.settings.appProfiles = savedProfiles
        out.append(("image-window", await hostedTree(ImageTranslationView(model: ImageTranslationModel(), onDrop: { _ in false }),
                                                    size: CGSize(width: 640, height: 480), model: model, name: "image-window")))
        return out
    }

    /// The titles, roles and sizes of every window of this process as an assistive app lists them.
    static func windowList() async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let app = AXUIElementCreateApplication(getpid())
                AXUIElementSetMessagingTimeout(app, 10)
                let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
                continuation.resume(returning: windows.map { w in
                    let extent = size(of: w)
                    return "\(string(w, kAXRoleAttribute))/\(string(w, kAXSubroleAttribute)) title=\"\(string(w, kAXTitleAttribute))\" \(Int(extent.width))×\(Int(extent.height))"
                })
            }
        }
    }

    // MARK: - The probe

    /// `a11y-tree`: writes `a11y-<view>.txt` for each audited view and prints what the audit finds.
    static func dump(_ model: AppModel, into dir: URL) async {
        guard canAsk else { print("a11y: this process may not ask the accessibility server (System Settings › Privacy & Security › Accessibility)"); return }
        // The windows a lens puts on the screen, as the window list of a screen reader has them.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let lensRect = NSRect(x: screen.frame.maxX - 520, y: screen.frame.minY + 60, width: 400, height: 160)
        let lens = RegionFrameWindow(region: lensRect, name: "Safari")
        let overlay = OverlayPanel(frame: lensRect)
        lens.orderFrontRegardless()
        overlay.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(0.6))
        let listed = await windowList()
        lens.orderOut(nil)
        overlay.orderOut(nil)
        try? listed.joined(separator: "\n").write(to: dir.appendingPathComponent("a11y-windows.txt"), atomically: true, encoding: .utf8)
        print("a11y windows:\n  " + listed.joined(separator: "\n  "))
        for (name, items) in await audited(model) {
            let path = dir.appendingPathComponent("a11y-\(name).txt")
            // A button's hit area is on its line here (not in `Item.line`, which the settle loop compares): the probe is what shows a size.
            try? items.map { $0.line + (buttonRoles.contains($0.role) ? "  [\(Int($0.size.width.rounded()))×\(Int($0.size.height.rounded()))]" : "") }
                .joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
            let bad = unlabeled(items), same = ambiguous(items)
            print("a11y \(name): \(items.count) elements, \(bad.count) unlabeled, \(same.count) ambiguous -> \(path.path)")
            for b in bad { print("  unlabeled \(b.role)/\(b.subrole) at depth \(b.depth)") }
            for s in same { print("  ambiguous \(s)") }
        }
    }

    // MARK: - The checks

    /// The accessibility checks of check-logic; returns the failures.
    static func run(_ model: AppModel) async -> Int {
        let report = Report()
        defer { Motion.shared.force(nil) }
        await reduceMotionChecks(model, report)
        await lensChecks(model, report)
        if canAsk { await lensSeenByAssistiveApp(report) }
        keyboardPlacementChecks(report)
        guard canAsk else {
            print("check-logic: SKIP accessibility: audit of Settings, Onboarding, the menu and the engine sheet (this process may not ask the accessibility server)")
            return report.failed
        }
        let views = await audited(model)
        for (name, items) in views {
            let bad = unlabeled(items), same = ambiguous(items)
            report.check("\(name): \(items.count) elements, \(bad.count) unlabeled controls or images, \(same.count) indistinguishable controls"
                         + (same.isEmpty ? "" : " (\(same.joined(separator: ", ")))"), items.count > 2 && bad.isEmpty && same.isEmpty)
            // ui-audit-1-1-5 X1; the rebuilt profile sheet (its minus buttons are 22 pt) is in it.
            let small = smallIconButtons(items)
            report.check("\(name): \(iconButtons(items).count) icon buttons, \(small.count) under \(Int(minimumHit)) × \(Int(minimumHit)) pt"
                         + (small.isEmpty ? "" : " (\(sizes(small)))"), small.isEmpty, detail: "every icon button needs a hit area of at least 20 × 20 pt (HIG, Accessibility)")
        }
        // The instrument must see the buttons it is about: a tree with no sizes would pass the check above for nothing.
        let seen = views.reduce(0) { $0 + iconButtons($1.items).count }
        report.check("the audit read the hit area of \(seen) icon buttons across the views (the menu footer, the ⋯ menu, the shortcut ✕, the notice ✕, the trash)", seen >= 8)
        await menuChecks(model, views.first { $0.name == "menu" }?.items ?? [], report)
        return report.failed
    }

    // MARK: The menu panel

    /// The panel's footer: Show Original only where it can act (ui-audit-1-1-5 1.1: with no lens it flips a switch the first lens would
    /// inherit, so the lens would open showing the original), and the shortcuts the Settings and Quit buttons answer to (1.2).
    private static func menuChecks(_ model: AppModel, _ menu: [Item], _ r: Report) async {
        func button(_ items: [Item], _ label: String) -> Item? { items.first { $0.role == "AXButton" && $0.label == label } }
        if model.regions.isEmpty, model.translationsVisible {
            let original = button(menu, String(localized: "Show Original"))
            r.check("the menu panel with no lens shows Show Original dimmed", original?.enabled == false,
                    detail: original == nil ? "there is no Show Original button in the panel" : "Show Original is enabled with 0 lenses")
            model.toggleTranslations()
            let hidden = await hostedTree(MenuPanel(), size: CGSize(width: 340, height: 400), model: model, name: "menu-hidden")
            model.toggleTranslations()
            let back = button(hidden, String(localized: "Show Translation"))
            r.check("with no lens and the translations hidden, Show Translation is enabled (the way back is never dimmed)", back?.enabled == true,
                    detail: back == nil ? "there is no Show Translation button in the panel" : "Show Translation is dimmed")
        }
        r.check("the table: Show Original acts with a lens, or while the translations are hidden",
                MenuPanel.canToggleOriginal(lenses: 0, translationsVisible: true) == false && MenuPanel.canToggleOriginal(lenses: 0, translationsVisible: false)
                && MenuPanel.canToggleOriginal(lenses: 1, translationsVisible: true) && MenuPanel.canToggleOriginal(lenses: 1, translationsVisible: false))
        let settings = button(menu, String(localized: "Settings")), quit = button(menu, String(localized: "Quit Mwoyeo"))
        r.check("the panel's Settings button names ⌘, and its Quit button ⌘Q in their help", settings?.help.hasSuffix("(⌘,)") == true && quit?.help.hasSuffix("(⌘Q)") == true,
                detail: "Settings help \"\(settings?.help ?? "—")\", Quit help \"\(quit?.help ?? "—")\"")
    }

    // MARK: Reduce Motion

    /// The animations of `layer` and everything below it that repeat.
    private static func repeating(_ layer: CALayer) -> [String] {
        let own = (layer.animationKeys() ?? []).filter { key in
            guard let a = layer.animation(forKey: key) else { return false }
            return a.repeatCount > 1 || a.repeatDuration > 0
        }
        return own + (layer.sublayers ?? []).flatMap(repeating)
    }

    /// The keys of every animation on `layer` and below.
    private static func animations(_ layer: CALayer) -> [String] {
        (layer.animationKeys() ?? []) + (layer.sublayers ?? []).flatMap(animations)
    }

    private static func stopAnimations(_ layer: CALayer) {
        layer.removeAllAnimations()
        layer.sublayers?.forEach(stopAnimations)
    }

    /// A window's pixels as the screen has them (the way the captures are taken).
    private static func pixels(of window: NSWindow) -> Data? {
        let path = NSTemporaryDirectory() + "mwoyeo-a11y-\(getpid())-\(window.windowNumber).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
        try? p.run()
        p.waitUntilExit()
        return FileManager.default.contents(atPath: path)
    }

    /// Pictures taken one after the other, compared in pairs until two in a row are the same or `count` pairs have been compared:
    /// one entry per pair, whether it was the same picture. `shoot` takes the next picture (nil: none was taken, and a shot that was
    /// not taken is no picture and makes no pair). A window that has only just opened is still settling under load (its first layout,
    /// the title bar turning active, the material behind it), so the first pairs of a view that holds still can differ for that
    /// alone: what a view does is read from the run of pairs, never from one pair. It has settled when a pair is the same, and it
    /// moves when every pair differs.
    private static func pairs(count: Int, shoot: () async -> Data?) async -> [Bool] {
        var same: [Bool] = []
        var before: Data?
        for _ in 0..<(count * 3) where same.count < count {          // the bound is on shots, so a screen that never answers ends the run
            let shot = await shoot()
            if let before, let shot {
                same.append(before == shot)
                if before == shot { break }
            }
            before = shot
        }
        return same
    }

    /// A view on the screen, shot `gap` seconds apart (`pairs`).
    private static func pairs<V: View>(_ view: V, size: CGSize, model: AppModel, count: Int, gap: Double = 0.5) async -> [Bool] {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: view.environment(model))
        w.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.frame.height ?? 900) - 60))
        w.orderFrontRegardless()
        defer { w.orderOut(nil) }
        // The first layout pass and the first commit happen before the first shot, not on the clock of the shots.
        w.contentView?.layoutSubtreeIfNeeded()
        w.displayIfNeeded()
        CATransaction.flush()
        var first = true
        return await pairs(count: count) {
            if !first { try? await Task.sleep(for: .seconds(gap)) }
            first = false
            return pixels(of: w)
        }
    }

    /// The view settled: two shots in a row were the same.
    private static func holdsStill(_ same: [Bool]) -> Bool { same.contains(true) }
    /// The view kept moving: every one of `count` pairs of shots differed.
    private static func keepsMoving(_ same: [Bool], count: Int) -> Bool { same.count == count && !same.contains(true) }

    private static func moves<V: View>(_ view: V, size: CGSize, model: AppModel) async -> Bool {
        keepsMoving(await pairs(view, size: size, model: model, count: movePairs), count: movePairs)
    }

    /// How many pairs of shots a view that holds still has to settle in (the first ones may be a window settling). A view that
    /// settles stops at the first pair that is the same, so the budget costs time only when a view does not hold still.
    private static let settleBudget = 6
    /// How many pairs of shots must all differ for a view to count as moving.
    private static let movePairs = 3

    /// The shots instrument on scripted pictures (no window, no clock): what a settling window, a moving one and a screen that
    /// gives no picture each read as. `shots` run out on their last entry.
    private static func shotsChecks(_ r: Report) async {
        func run(_ shots: [Data?], count: Int) async -> [Bool] {
            var next = 0
            return await pairs(count: count) { defer { next += 1 }; return shots[min(next, shots.count - 1)] }
        }
        let a = Data([1]), b = Data([2]), c = Data([3])
        let settling = await run([a, b, c, c], count: settleBudget), moving = await run([a, b, a, b, a, b], count: movePairs)
        let blank = await run([nil], count: settleBudget), late = await run([nil, a, nil, b, b], count: settleBudget)
        r.check("Reduce Motion shots: a window that changes while it settles and stops is still; one that changes in every pair is moving",
                holdsStill(settling) && !keepsMoving(settling, count: settleBudget) && keepsMoving(moving, count: movePairs) && !holdsStill(moving))
        r.check("Reduce Motion shots: a screen that gives no picture is neither still nor moving, and a pair needs two shots taken in a row",
                !holdsStill(blank) && !keepsMoving(blank, count: movePairs) && late == [true])
    }

    private static func reduceMotionChecks(_ model: AppModel, _ r: Report) async {
        let lens = RegionFrameWindow(region: NSRect(x: 200, y: 400, width: 360, height: 200), name: "Safari")
        lens.setAppearance(style: .glow, tint: .spectrum, tabVisibility: .automatic, tabPosition: .topLeading)
        guard let layer = lens.contentView?.layer else { r.check("the lens has a layer", false); return }

        // The glow breathes while the lens reads, unless Reduce Motion is on.
        Motion.shared.force(false)
        lens.setBusy(true)
        r.check("Reduce Motion off: a reading lens breathes (the instrument sees a repeating animation)", repeating(layer).count == 1)
        Motion.shared.force(true)
        r.check("Reduce Motion on, switched while the lens reads: the glow stops breathing", repeating(layer).isEmpty)
        lens.setBusy(false)
        lens.setBusy(true)
        r.check("Reduce Motion on: a lens that starts reading has no repeating animation", repeating(layer).isEmpty)
        Motion.shared.force(false)
        r.check("Reduce Motion switched off while the lens reads: the glow breathes again", repeating(layer).count == 1)
        lens.setBusy(false)

        // The sweep that marks a lens coming alive or the original coming back.
        lens.sweep()
        r.check("Reduce Motion off: the sweep runs (the instrument sees it)", animations(layer).contains("sweep"))
        stopAnimations(layer)
        Motion.shared.force(true)
        lens.sweep()
        r.check("Reduce Motion on: the sweep does not run", !animations(layer).contains("sweep"))

        await shotsChecks(r)

        // The SwiftUI motion: a ring that turns, a lens that glides. Shot again and again (`pairs`): off, every pair differs; on, the view settles.
        Motion.shared.force(false)
        let spinningOff = await moves(LensChip(state: .busy), size: CGSize(width: 120, height: 60), model: model)
        let glidingOff = await moves(OnboardingView(close: {}), size: CGSize(width: 600, height: 760), model: model)
        r.check("Reduce Motion off: the reading lens chip and the Onboarding lens move (the instrument sees them)", spinningOff && glidingOff)
        Motion.shared.force(true)
        let spinningOn = await pairs(LensChip(state: .busy), size: CGSize(width: 120, height: 60), model: model, count: Self.settleBudget)
        let glidingOn = await pairs(OnboardingView(close: {}), size: CGSize(width: 600, height: 760), model: model, count: Self.settleBudget)
        r.check("Reduce Motion on: the lens chip's ring and the Onboarding lens hold still", holdsStill(spinningOn) && holdsStill(glidingOn),
                detail: "pairs of shots that were the same, chip \(spinningOn), Onboarding \(glidingOn)")
        if model.regions.isEmpty {
            let emptyOn = await pairs(MenuPanel(), size: CGSize(width: 340, height: 400), model: model, count: Self.settleBudget)
            Motion.shared.force(false)
            let emptyOff = await moves(MenuPanel(), size: CGSize(width: 340, height: 400), model: model)
            r.check("the menu panel's empty state glides with Reduce Motion off and holds still with it on", emptyOff && holdsStill(emptyOn),
                    detail: "pairs of shots that were the same, Reduce Motion on \(emptyOn)")
        }
        Motion.shared.force(nil)
    }

    // MARK: The lens

    private static func lensChecks(_ model: AppModel, _ r: Report) async {
        var config = RegionConfig(name: "Safari", rect: CGRect(x: 200, y: 300, width: 360, height: 200))
        config.follow(nil)
        let session = RegionSession(config: config, settings: AppSettings(), translator: model.translator, inpainter: nil)
        guard let window = session.lensWindow as? RegionFrameWindow, let view = window.contentView else {
            r.check("the session has a lens window", false)
            return
        }
        var closed = false
        session.onCloseRequest = { closed = true }
        // What the app wires for a lens: the hotkey, the menu item and this action all call `AppModel.toggleTranslations`.
        let before = model.translationsVisible
        session.onToggleOriginal = { model.toggleTranslations(); session.setTranslationsVisible(model.translationsVisible) }
        func value() -> String { view.accessibilityValue() as? String ?? "" }

        r.check("the lens window is one element: a group named Translation lens",
                view.isAccessibilityElement() && view.accessibilityRole() == .group && view.accessibilityLabel() == String(localized: "Translation lens"))
        r.check("it says it waits for text before anything is read", value() == String(localized: "Waiting for text"))
        window.setBusy(true)
        r.check("it says Reading while the lens reads", value() == String(localized: "Reading"))
        window.setBusy(false)
        window.translationLines = { ["ok who stayed up for the patch notes last night", "guilty."] }
        r.check("it says Translated and gives the start of the translation in reading order",
                value() == "\(String(localized: "Translated")): ok who stayed up for the patch notes last night guilty.")
        window.translationLines = { [String(repeating: "word ", count: 80)] }
        r.check("the summary is the first 200 characters, cut at a word", value().count <= String(localized: "Translated").count + 2 + 201 && value().hasSuffix("…"))
        window.translationLines = { ["ok who stayed up for the patch notes last night", "guilty."] }
        let children = view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement } ?? []
        r.check("inside it: the translation as text, then the pill's mode and close buttons", children.map { $0.accessibilityRole() } == [.staticText, .button, .button])
        r.check("the translation text is complete", (children.first?.accessibilityValue() as? String) == "ok who stayed up for the patch notes last night\nguilty.")
        r.check("the pill's buttons are named and sit inside the lens window",
                children.dropFirst().allSatisfy { ($0.accessibilityLabel() ?? "").isEmpty == false && window.frame.intersects($0.accessibilityFrame()) })
        // ui-audit-1-1-5 2.1: the glyphs are 16 × 16 and 18 × 16 pt, the hit areas the HIG's 20 × 20 pt at least.
        let pill = children.dropFirst().map { (label: $0.accessibilityLabel() ?? "", frame: $0.accessibilityFrame()) }
        r.check("the pill's two buttons have a hit area of at least 20 × 20 pt",
                pill.count == 2 && pill.allSatisfy { $0.frame.width >= minimumHit && $0.frame.height >= minimumHit },
                detail: pill.map { "\($0.label) \(Int($0.frame.width.rounded()))×\(Int($0.frame.height.rounded()))" }.joined(separator: ", "))
        _ = children.last?.accessibilityPerformPress()
        r.check("pressing the close button asks the app to close the lens", closed)
        closed = false

        // The four actions. They are found by name: "Open Lens Menu" pops a menu up and is never run here.
        func action(_ name: String) -> NSAccessibilityCustomAction? { view.accessibilityCustomActions()?.first { $0.name == name } }
        var actions = view.accessibilityCustomActions() ?? []
        r.check("the lens offers Show Original, Pause all, Remove Lens and Open Lens Menu",
                actions.map(\.name) == [String(localized: "Show Original"), String(localized: "Pause all"), String(localized: "Remove Lens"), String(localized: "Open Lens Menu")])
        let ran = actions.first?.handler?() ?? false
        r.check("Show Original, as an action, flips what the hotkey flips (translations hidden) and the lens says so",
                ran && model.translationsVisible == !before && value() == String(localized: "Showing original"))
        actions = view.accessibilityCustomActions() ?? []
        r.check("it then offers Show Translation", actions.first?.name == String(localized: "Show Translation"))
        _ = actions.first?.handler?()
        r.check("Show Translation brings them back", model.translationsVisible == before && value() != String(localized: "Showing original"))
        _ = action(String(localized: "Remove Lens"))?.handler?()
        r.check("Remove Lens, as an action, asks the app to close the lens", closed)
        let paused = model.isPaused
        _ = action(String(localized: "Pause all"))?.handler?()
        try? await Task.sleep(for: .milliseconds(400))
        r.check("Pause all, as an action, pauses every lens as the menu's button does", model.isPaused == !paused)
        if model.isPaused != paused { await model.togglePause() }
        r.check("the lens has a menu to open", window.onContextMenu?()?.items.isEmpty == false)

        // Notices and hints are the state in words, in the pill's order.
        window.flash("Copied", seconds: 0.2)
        r.check("a notice is what the lens says", value() == "Copied")
        window.setHint("Allow screen recording", actionable: true)
        try? await Task.sleep(for: .milliseconds(500))
        r.check("a hint is what it says once the notice is gone", value().hasPrefix("Allow screen recording"))
        let buttons = (view.accessibilityChildren()?.compactMap { $0 as? NSAccessibilityElement } ?? []).filter { $0.accessibilityRole() == .button }
        r.check("a hint to click is a button inside the lens", buttons.contains { ($0.accessibilityLabel() ?? "").hasPrefix("Allow screen recording") })
        window.setHint(nil)
        window.setOriginal(true)
        r.check("showing the original is what it says", value() == String(localized: "Showing original"))
    }

    /// The lens window on the screen, asked through the accessibility API a screen reader uses.
    private static func lensSeenByAssistiveApp(_ r: Report) async {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        // In the corner, away from the places the other captures use.
        let lens = RegionFrameWindow(region: NSRect(x: screen.frame.maxX - 520, y: screen.frame.minY + 60, width: 400, height: 160), name: "A11y check")
        lens.translationLines = { ["Hello there."] }
        // The lens's overlay is up too, as in the app: it draws the translations and says nothing.
        let overlay = OverlayPanel(frame: NSRect(x: screen.frame.maxX - 520, y: screen.frame.minY + 60, width: 400, height: 160))
        lens.orderFrontRegardless()
        overlay.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(0.6))
        let title = "\(String(localized: "Translation lens")), A11y check"
        let listed = await windowList()
        let items = await tree(ofWindowTitled: title)
        lens.orderOut(nil)
        overlay.orderOut(nil)
        r.check("a screen reader's window list names the lens (\"\(title)\") and has no nameless window beside it",
                listed.contains { $0.contains("title=\"\(title)\"") } && !listed.contains { $0.contains("title=\"\"") })
        let group = items.first { $0.role == "AXGroup" && $0.label == String(localized: "Translation lens") }
        r.check("it finds the group inside, with the state as its value", group?.value == "\(String(localized: "Translated")): Hello there.")
        let wanted = [String(localized: "Show Original"), String(localized: "Pause all"), String(localized: "Remove Lens"), String(localized: "Open Lens Menu")]
        r.check("and the four actions on it", wanted.allSatisfy { group?.actions.contains($0) == true })
        let inside = items.filter { $0.depth == (group?.depth ?? -2) + 1 }
        r.check("and inside it the translation and the two buttons of the pill", inside.map(\.role) == ["AXStaticText", "AXButton", "AXButton"] && inside.first?.value == "Hello there.")
        let small = inside.dropFirst().filter { $0.size.width < minimumHit || $0.size.height < minimumHit }
        r.check("and the assistive app reads each button's hit area as 20 × 20 pt at least (\(sizes(Array(inside.dropFirst()))))", inside.count == 3 && small.isEmpty)
    }

    // MARK: The keyboard

    private static func keyboardPlacementChecks(_ r: Report) {
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [], isRepeat: Bool = false) -> PlacementInput? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: "", charactersIgnoringModifiers: "", isARepeat: isRepeat, keyCode: code).flatMap(PlacementInput.init)
        }
        r.check("the arrows are moves, ⇧ makes them resizes and ⌥ makes them fine",
                key(124) == .move(.right, resize: false, fine: false) && key(123, [.shift]) == .move(.left, resize: true, fine: false)
                && key(126, [.option]) == .move(.up, resize: false, fine: true) && key(125, [.shift, .option]) == .move(.down, resize: true, fine: true))
        r.check("Return places, Esc leaves (with anything held), and a key held down does not place twice",
                key(36) == .confirm && key(76) == .confirm && key(36, isRepeat: true) == nil && key(53) == .cancel && key(53, [.command]) == .cancel)
        r.check("keys with ⌘ or ⌃ and letters are not the picker's (nothing else is taken)", key(124, [.command]) == nil && key(123, [.control]) == nil && key(0) == nil)

        let screen = NSScreen.main ?? NSScreen.screens[0]
        var result: RegionPicker.Result??
        let view = PickerView(screen: screen, windows: [], done: { result = .some($0) })
        view.handle(.move(.right, resize: false, fine: false))
        let start = view.placement?.rect
        r.check("the first arrow shows the default lens, centred, without moving it",
                start == KeyboardLens(bounds: view.bounds).rect && start?.midX == view.bounds.midX && start?.size == KeyboardLens.defaultSize)
        view.handle(.move(.right, resize: false, fine: false))
        view.handle(.move(.right, resize: false, fine: false))
        view.handle(.move(.up, resize: false, fine: false))
        view.handle(.move(.down, resize: true, fine: false))
        view.handle(.move(.left, resize: false, fine: true))
        let moved = view.placement?.rect
        r.check("arrows move it by 10 points (⌥: 1), ⇧ + arrow resizes it by 10",
                moved == start.map { CGRect(x: $0.minX + 19, y: $0.minY, width: $0.width, height: $0.height + 10) })
        // Locale-free: the value is localized (ko says "560×330 포인트"), so compare with the same localized phrase.
        let said = (view.accessibilityValue() as? String) ?? ""
        let w = Int(moved?.width ?? 0), h = Int(moved?.height ?? 0)
        r.check("the view says where the lens is", w > 0 && said.hasPrefix(String(localized: "\(w) by \(h) points, \(Int(moved?.minX ?? 0)) from the left, \(Int(view.bounds.height - (moved?.maxY ?? 0))) from the top")))
        view.handle(.confirm)
        let expected = moved.map { ScreenGeometry.quartzRect(fromAppKit: $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)) }
        r.check("Return commits a lens with that rect, the way a drag does", result.flatMap { $0 }?.rect == expected && result.flatMap { $0 }?.window == nil)

        var cancelled: RegionPicker.Result??
        let second = PickerView(screen: screen, windows: [], done: { cancelled = .some($0) })
        second.handle(.confirm)
        second.handle(.move(.left, resize: false, fine: false))
        r.check("a first Return only shows the lens", cancelled == nil && second.placement != nil)
        second.handle(.cancel)
        r.check("Escape leaves no lens", cancelled.map { $0 == nil } == true)
    }
}
#endif
