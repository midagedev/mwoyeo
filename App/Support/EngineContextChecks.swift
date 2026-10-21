#if !MAS
import AppKit
import MwoyeoCore
import SwiftUI

/// The checks of the engine sheet's Context section, run by `--capture-ui … check-logic` (PASS/FAIL lines) or alone as
/// `engine-context-checks`: which engines get the section (chat, Anthropic and DeepL; never a template or a command), what a control
/// writes to settings.json and what the Sent line says before and after, that Off is still today's request after the controls were
/// turned both ways, that the disclosure holds still under Reduce Motion, and (when this process may ask the accessibility server) the
/// section as the sheet really shows it: its place between the sample result and Advanced, the order of its controls, a name on each.
/// No check waits a time out: the tree of a hosted window is read until it stops changing (`shown`), and the rest is pure.
@MainActor
enum EngineContextChecks {
    private static let cloud = EngineKind.openAICompatible(baseURL: URL(string: "https://api.example.invalid/v1")!, model: "m1", thinking: .off, extraHeaders: [:])
    private static let local = EngineKind.openAICompatible(baseURL: URL(string: "http://localhost:11434/v1")!, model: "m1", thinking: .off, extraHeaders: [:])
    private static let anthropic = EngineKind.anthropic(baseURL: URL(string: "https://anthropic.example.invalid")!, model: "m1", thinking: .off)
    private static let deepL = EngineKind.deepL(baseURL: URL(string: "https://api-free.deepl.invalid/")!, formality: nil)
    private static let template = EngineKind.httpTemplate(HTTPTemplate(url: "https://service.example.invalid/translate", resultPath: "text"))
    private static let command = EngineKind.command(CommandSpec(executable: "/usr/bin/true"))

    static func run(_ model: AppModel, dump: URL? = nil) async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") engine context: \(what)" + (ok ? "" : note().isEmpty ? "" : " [\(note())]"))
            if !ok { failed += 1 }
        }
        let savedEngines = model.settings.engines, savedSelection = model.settings.customEngineID, savedProfiles = model.settings.appProfiles
        let savedContext = model.settings.context, savedLearned = model.settings.useLearned
        model.settings.appProfiles = []
        defer {
            model.settings.engines = savedEngines
            model.settings.customEngineID = savedSelection
            model.settings.appProfiles = savedProfiles
            model.settings.context = savedContext
            model.settings.useLearned = savedLearned
            Motion.shared.force(nil)
        }

        // Who gets the section, and which controls.
        let reached = [cloud, local, anthropic, deepL].allSatisfy(EngineContextRules.shows)
        let owned = [template, command].contains(where: EngineContextRules.shows)
        check("the section is for a chat server, Anthropic and DeepL, and not for an HTTP template or a command", reached && !owned,
              "reached \(reached) owned-by-user \(owned)")
        check("the window title switch is for engines that are not on this Mac: not the local server, yes the cloud ones (DeepL, too)",
              !EngineContextRules.asksTitle(local) && [cloud, anthropic, deepL].allSatisfy(EngineContextRules.asksTitle))
        check("Learn names and terms is for the engines whose answer can carry them (not DeepL); the DeepL notes switch is DeepL's alone",
              [cloud, local, anthropic].allSatisfy(EngineContextRules.asksLearned) && !EngineContextRules.asksLearned(deepL)
              && EngineContextRules.asksDeepLNotes(deepL) && ![cloud, local, anthropic].contains(where: EngineContextRules.asksDeepLNotes))

        // The summary, and what the Sent line and the footnote say (their words are checked in the file that owns them).
        let on3 = EngineContext(enabled: true, previousLines: 3)
        let offKept = EngineContext(enabled: false, previousLines: 5, includeTitle: true, useLearned: true, deepLInstructions: true)
        check("the collapsed line says Off when off (whatever the other switches hold) and the number of lines when on",
              EngineContextRules.summary(nil) == String(localized: "Off") && EngineContextRules.summary(offKept) == String(localized: "Off")
              && EngineContextRules.summary(on3).contains("3") && EngineContextRules.summary(on3) != EngineContextRules.summary(EngineContext(enabled: true, previousLines: 5)))
        EngineContextSent.checks(model) { what, ok, note in check(what, ok, note) }

        // What a control writes: settings.json, live, and the line follows. The Context section of the sheet is still the one of 1.1.4 (round
        // R4 rebuilds it over the new keys; prof-file, 2026-10-21, addendum A3). What these checks pin is what such a control will write: All apps'
        // `context` (the amount), `useLearned`, and the engine's `allow`, set on the model the way the controls will.
        let e = EngineConfig(name: "Context check", kind: cloud)
        model.settings.engines = [e]
        model.settings.customEngineID = e.id
        model.settings.context = nil
        model.settings.useLearned = false
        func fileObject() -> [String: Any]? {
            (try? Data(contentsOf: model.settingsFile.url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        }
        func fileContext() -> [String: Any]? { fileObject()?["context"] as? [String: Any] }
        func fileAllow() -> [String: Any]? { ((fileObject()?["engines"] as? [[String: Any]])?.first)?["allow"] as? [String: Any] }
        let lineOff = EngineContextSent.line(for: model.settings.engines[0], in: model)
        check("an engine with no context starts Off: nothing in the file, no context plan", fileContext() == nil && fileAllow() == nil
              && ContextChecks.plan(model.settings, engine: model.settings.activeEngineConfig) == nil)
        model.settings.context = AppContextOverride(mode: .nearby, previousLines: 0)
        let lineOn = EngineContextSent.line(for: model.settings.engines[0], in: model)
        check("Use context on writes settings.json at once, and the Sent line changes with it",
              fileContext()?["mode"] as? String == "nearby" && lineOn != lineOff && !lineOn.isEmpty, "\(lineOff) → \(lineOn)")
        model.settings.context = AppContextOverride(mode: .conversation, previousLines: 6)
        model.settings.engines[0].allow.title = true
        model.settings.useLearned = true
        let wrote = fileContext(), wroteAllow = fileAllow()
        check("each control writes its own key: the lines (context), the title (the engine's allow), learning (useLearned)",
              wrote?["mode"] as? String == "conversation" && wrote?["previousLines"] as? Int == 6 && wroteAllow?["title"] as? Bool == true
              && fileObject()?["useLearned"] as? Bool == true
              && EngineContextSent.line(for: model.settings.engines[0], in: model).contains(String(localized: "window title")))
        // The amount off with the rest left as it was: the plan is nil, today's path, and the layout's body is the one an Off engine gets.
        model.settings.context = AppContextOverride(mode: .off)
        let afterOff = model.settings.engines[0]
        let request = ContextRequest(items: ["Hello"], before: [ContextLine(source: "Earlier")], after: ["Later"],
                                     card: DocumentCard(appName: "App", domain: "social", title: "T"), target: "ko")
        let offOptions = ContextOptions.requestOptions(engine: afterOff, chain: ContextRoute.merged(settings: model.settings, lens: nil))
        let offBodies = [cloud, anthropic, deepL].map { kind in
            RequestLayout.body(kind: kind, request: request, options: offOptions) == RequestLayout.body(kind: kind, request: request, options: ContextOptions())
        }
        check("the amount off, with the title and learning still set, is Off: the file says so, there is no context plan, and the request is Off's bytes",
              fileContext()?["mode"] as? String == "off" && ContextChecks.plan(model.settings, engine: model.settings.activeEngineConfig) == nil
              && !offBodies.contains(false), "\(offBodies)")
        let beforeGone = model.settings.engines
        EngineContextRules.update(UUID(), in: model) { $0.enabled = true }
        check("a control of an engine that is gone writes nothing", model.settings.engines == beforeGone)

        // Reduce Motion.
        Motion.shared.force(true)
        let held = EngineContextRules.expansion() == nil
        Motion.shared.force(false)
        let moves = EngineContextRules.expansion() != nil
        Motion.shared.force(nil)
        check("the disclosure holds still under Reduce Motion and animates otherwise (Motion owns the setting)", held && moves)

        // The section as the sheet shows it.
        guard AccessibilityChecks.canAsk else {
            print("check-logic: SKIP engine context: the section in the sheet (this process may not ask the accessibility server)")
            return failed
        }
        /// The sheet of `engine` in a window as the app hosts it, its Context section open or shut, and what the accessibility server says
        /// of it: the tree, and the attributes of the Context triangle (empty when the sheet has none). SwiftUI builds its tree as it is
        /// asked, so the tree is read until two reads in a row agree and the last row of the form (Advanced) is in it; `timeout` only
        /// bounds a sheet that never gets there, it is not waited out.
        func shown(_ name: String, _ engine: EngineConfig, expanded: Bool = true, timeout: Double = 10) async
            -> (items: [AccessibilityChecks.Item], triangle: [String]) {
            model.settings.engines = [engine]
            let title = "mwoyeo-a11y-engine-context-\(name)"
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: CGSize(width: 480, height: 560)), styleMask: [.titled], backing: .buffered, defer: false)
            w.title = title
            w.contentView = NSHostingView(rootView: EngineSheet(editing: engine, autopilot: .init(expandContext: expanded)).environment(model))
            w.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.frame.height ?? 900) - 60))
            w.orderFrontRegardless()
            let advanced = String(localized: "Advanced")
            var items: [AccessibilityChecks.Item] = []
            for _ in 0..<Int(timeout * 10) {
                try? await Task.sleep(for: .milliseconds(100))
                let next = await AccessibilityChecks.tree(ofWindowTitled: title)
                let settled = next.map(\.line) == items.map(\.line) && next.contains { $0.label == advanced }
                items = next
                if settled { break }
            }
            let triangle = await triangleAttributes(inWindowTitled: title, named: String(localized: "Context"))
            w.orderOut(nil)
            if let dump {
                let lines = items.map(\.line) + (triangle.isEmpty ? [] : ["", "Context triangle:"] + triangle.map { "  " + $0 })
                try? lines.joined(separator: "\n").write(to: dump.appendingPathComponent("a11y-engine-context-\(name).txt"), atomically: true, encoding: .utf8)
            }
            return (items, triangle)
        }
        func tree(_ name: String, _ engine: EngineConfig, expanded: Bool = true) async -> [AccessibilityChecks.Item] {
            await shown(name, engine, expanded: expanded).items
        }
        func labels(_ items: [AccessibilityChecks.Item]) -> [String] { items.map(\.label) }
        func place(_ items: [AccessibilityChecks.Item], _ label: String) -> Int? { items.firstIndex { $0.label == label } }

        var chat = EngineConfig(name: "Context chat", kind: cloud)
        chat.context = EngineContext(enabled: true, previousLines: 3)
        // The footnote says that lines go along when All apps' amount sends them (round prof-file: the engine's own switch is All apps' `context`).
        // An engine is sent lines when a chain that uses it asks for them, so the chat engine is the one in use.
        model.settings.context = AppContextOverride(mode: .conversation, previousLines: 3)
        model.settings.customEngineID = chat.id
        let chatSheet = await shown("chat", chat)
        let chatItems = chatSheet.items
        let sentLine = EngineContextSent.line(for: chat, in: model)
        // What starts the Sent line in the app's language: the collapsed section is checked for it below, so it has to recognise the line.
        let sentPrefix = String(localized: "Sent: \("")")
        check("the start the checks look for tells the Sent line in the app's language", sentLine.hasPrefix(sentPrefix), sentLine)
        let order = ["Test", "Context", "Use context", "Previous lines", "Include window title", "Learn names and terms"]
            .map { name in place(chatItems, NSLocalizedString(name, comment: "")) }
            + [chatItems.firstIndex { $0.value == sentLine }, place(chatItems, String(localized: "Advanced"))]
        let found = order.compactMap { $0 }
        check("the chat sheet shows Context between the sample result and Advanced: its controls in order, then the Sent line",
              found.count == order.count && zip(found, found.dropFirst()).allSatisfy { $0 < $1 },
              "order \(order) in \(labels(chatItems).filter { !$0.isEmpty })")
        let footnotes = EngineContextSent.footnotes(for: chat, in: model)
        check("the sheet of an engine whose context is on says under the box that allows sending what goes along, in the words the footnote gives",
              !footnotes.isEmpty && footnotes.allSatisfy { note in chatItems.contains { $0.value == note } }, "\(footnotes) in \(chatItems.map(\.value).filter { !$0.isEmpty })")
        check("every control of the open chat sheet has a name a screen reader can say, and none is told from another by nothing",
              AccessibilityChecks.unlabeled(chatItems).isEmpty && AccessibilityChecks.ambiguous(chatItems).isEmpty,
              AccessibilityChecks.unlabeled(chatItems).map(\.line).joined(separator: "; "))
        model.settings.context = nil

        var deepLEngine = EngineConfig(name: "Context DeepL", kind: deepL)
        deepLEngine.context = EngineContext(enabled: true, previousLines: 3)
        let deepLItems = await tree("deepl", deepLEngine)
        check("the DeepL sheet shows the notes switch after the title switch, and no Learn names and terms",
              place(deepLItems, String(localized: "Use my notes with DeepL")) != nil && place(deepLItems, String(localized: "Learn names and terms")) == nil
              && place(deepLItems, String(localized: "Include window title")).map { $0 < (place(deepLItems, String(localized: "Use my notes with DeepL")) ?? 0) } == true)

        var localEngine = EngineConfig(name: "Context local", kind: local)
        localEngine.context = EngineContext(enabled: true, previousLines: 3)
        let localItems = await tree("local", localEngine)
        check("the sheet of a server on this Mac has no window title switch",
              place(localItems, String(localized: "Use context")) != nil && place(localItems, String(localized: "Include window title")) == nil)

        let templateItems = await tree("template", EngineConfig(name: "Context template", kind: template))
        let commandItems = await tree("command", EngineConfig(name: "Context command", kind: command))
        check("an HTTP template and a command have no Context section", place(templateItems, String(localized: "Context")) == nil
              && place(commandItems, String(localized: "Context")) == nil && place(templateItems, String(localized: "Advanced")) != nil
              && place(commandItems, String(localized: "Advanced")) != nil)

        let collapsedSheet = await shown("collapsed", chat, expanded: false)
        let collapsed = collapsedSheet.items
        // The summary is the group's accessibility value (AXValueDescription, what a screen reader says after the name; AXValue stays
        // the open or shut state the system keeps).
        let said = "AXValueDescription=\(EngineContextRules.summary(chat.context))"
        check("collapsed, the section shows its name alone: no controls, no Sent line; its value is the summary",
              place(collapsed, String(localized: "Context")) != nil && place(collapsed, String(localized: "Use context")) == nil
              && !collapsed.contains { $0.value.hasPrefix(sentPrefix) } && collapsedSheet.triangle.contains(said) && collapsedSheet.triangle.contains("AXDisclosing=0"),
              "\(collapsedSheet.triangle) in \(labels(collapsed).filter { !$0.isEmpty }.joined(separator: ", "))")
        check("open, the section keeps the same value, and the system says it is open",
              chatSheet.triangle.contains(said) && chatSheet.triangle.contains("AXDisclosing=1"), "\(chatSheet.triangle)")

        var claude = EngineConfig(name: "Context Anthropic", kind: anthropic)
        claude.context = EngineContext(enabled: true, previousLines: 3)
        let anthropicItems = await tree("anthropic", claude)
        check("the Anthropic sheet has the section, with the title switch and Learn names and terms, and no DeepL notes switch",
              place(anthropicItems, String(localized: "Context")) != nil && place(anthropicItems, String(localized: "Include window title")) != nil
              && place(anthropicItems, String(localized: "Learn names and terms")) != nil && place(anthropicItems, String(localized: "Use my notes with DeepL")) == nil)
        return failed
    }

    /// What the accessibility server says about the disclosure triangle named `name` in the window titled `title`: every attribute with
    /// a value, as "Attribute=value" lines. Asked off the main thread, since the answers come from it.
    nonisolated static func triangleAttributes(inWindowTitled title: String, named name: String) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let app = AXUIElementCreateApplication(getpid())
                AXUIElementSetMessagingTimeout(app, 10)
                func text(_ element: AXUIElement, _ attribute: String) -> String? {
                    var value: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
                    if let s = value as? String { return s }
                    if let n = value as? NSNumber { return n.stringValue }
                    return nil
                }
                var found: [String] = []
                func walk(_ element: AXUIElement, _ depth: Int) {
                    guard depth < 40, found.isEmpty else { return }
                    if text(element, kAXRoleAttribute) == "AXDisclosureTriangle",
                       [kAXDescriptionAttribute, kAXTitleAttribute].contains(where: { text(element, $0) == name }) {
                        var names: CFArray?
                        AXUIElementCopyAttributeNames(element, &names)
                        found = ((names as? [String]) ?? []).sorted().compactMap { a in text(element, a).map { "\(a)=\($0)" } }
                        return
                    }
                    var children: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success {
                        for child in (children as? [AXUIElement]) ?? [] { walk(child, depth + 1) }
                    }
                }
                var windows: CFTypeRef?
                if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success {
                    for window in (windows as? [AXUIElement]) ?? [] where text(window, kAXTitleAttribute) == title { walk(window, 0) }
                }
                continuation.resume(returning: found)
            }
        }
    }
}
#endif
