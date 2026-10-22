import AppKit
import MwoyeoCore
import Observation
import SwiftUI

/// "Translate Text…": a text typed or pasted, translated the way a lens translates (docs/design/text-translation.md). The state of the window
/// (the profile and the languages and engine picked over it, the text) is the window's own, not a setting.
@MainActor
@Observable
final class TextTranslationModel {
    /// What the window says. `typing`: a pause will translate (Apple engines). `edited`: the text changed and an added engine waits to be
    /// asked, so the translation shown, if any, is of the text before. `needsPack` and `unsupported` are the image window's: the translation waits
    /// for a language pack (what became of its download is `PackDownload.ledger`'s), or the pair has none.
    enum Phase: Equatable {
        case empty, typing, edited
        case working(done: Int, total: Int)
        case done(engine: String?)
        case needsPack(PackPair), unsupported(PackPair), failed(String), tooLong(Int)
    }

    var source = "" { didSet { if source != oldValue { sourceChanged() } } }
    private(set) var translation = ""
    private(set) var phase = Phase.empty

    /// The profile picked by hand (a profile's id, or `AppProfile.allAppsID`); nil is Auto, the profile of the app that was in front when the window
    /// was asked for. A new pick takes the languages and the engine back to the profile's.
    var profile: String? { didSet { if profile != oldValue { profilePicked() } } }
    /// Languages and the engine picked over the profile's: the codes of `Languages`, and "apple" or an engine's id.
    var sourceLanguage: String? { didSet { if sourceLanguage != oldValue, !picking { pickChanged() } } }
    var targetLanguage: String? { didSet { if targetLanguage != oldValue, !picking { pickChanged() } } }
    var engineChoice: String? { didSet { if engineChoice != oldValue, !picking { pickChanged() } } }
    /// Bumped when the window is asked for, so the source field takes the keyboard.
    private(set) var focusRequests = 0

    @ObservationIgnored private let translator: TextTranslator
    @ObservationIgnored private let appSettings: @MainActor () -> AppSettings
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private var pause: TypingPause
    @ObservationIgnored private var anchor: String?
    @ObservationIgnored private var picking = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var waiting: Task<Void, Never>?
    /// Called once a translation has settled (or failed), with this model: the debug launch and the checks wait on it.
    @ObservationIgnored var onSettled: (() -> Void)?

    init(translator: TextTranslator = .shared, settings: @escaping @MainActor () -> AppSettings = { AppModel.shared.settings },
         pause: TypingPause = TypingPause(), clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.translator = translator
        appSettings = settings
        self.pause = pause
        self.clock = clock
    }

    // MARK: What is translated under

    /// The app whose profile Auto follows: the one in front when the window was asked for (`AppModel.frontmostBundleID` is never Mwoyeo).
    func anchor(to app: String?) {
        focusRequests += 1
        guard app != anchor else { return }
        anchor = app
        pickChanged()
    }

    var anchorApp: String? { anchor }

    /// The pick, when it still names something: a profile or an engine deleted meanwhile is no pick.
    private var request: TextTranslation.Request {
        let s = appSettings()
        let profile = profile.flatMap { id in id == AppProfile.allAppsID || s.appProfiles.contains { $0.id == id } ? id : nil }
        let engine = engineChoice.flatMap { id in id == "apple" || s.engines.contains { $0.id.uuidString == id } ? id : nil }
        return TextTranslation.Request(app: anchor, profile: profile, engine: engine, source: sourceLanguage, target: targetLanguage)
    }

    /// The languages, the engine and the profile the window translates under now; nil when the pick was refused.
    var resolved: TextTranslation.Resolved? { try? translator.resolve(request) }

    var trigger: TextTrigger { TextTrigger.forEngine(added: resolved?.engine != nil) }

    // MARK: Text in, translation out

    private func sourceChanged() {
        generation += 1
        running?.cancel()
        guard !isBlank else {
            waiting?.cancel()
            pause.cancel()
            translation = ""
            phase = .empty
            return
        }
        retrigger()
    }

    private func profilePicked() {
        picking = true
        sourceLanguage = nil
        targetLanguage = nil
        engineChoice = nil
        picking = false
        pickChanged()
    }

    /// What the text is translated under changed: it is translated again, as an edit would have it.
    private func pickChanged() {
        guard !isBlank else { return }
        generation += 1
        running?.cancel()
        retrigger()
    }

    private var isBlank: Bool { source.allSatisfy(\.isWhitespace) }

    /// The text (or what it is translated under) changed: a pause translates it with Apple, an added engine waits to be asked.
    private func retrigger() {
        switch trigger {
        case .onPause:
            phase = .typing
            pause.edited(at: clock())
            waiting?.cancel()
            waiting = Task { [weak self] in
                while let self {
                    switch self.pause.step(at: self.clock()) {
                    case .idle: return
                    case .fire:
                        self.translateNow()
                        return
                    case let .wait(seconds):
                        try? await Task.sleep(for: .seconds(seconds))
                        if Task.isCancelled { return }
                    }
                }
            }
        case .onRequest:
            waiting?.cancel()
            pause.cancel()
            phase = .edited
        }
    }

    /// Translates the text as it stands: ⌘↩, the button, a pause with Apple, the Services entry.
    func translateNow() {
        waiting?.cancel()
        pause.cancel()
        guard !isBlank else { return }
        guard source.count <= TextParagraphs.maxCharacters else {
            running?.cancel()
            phase = .tooLong(source.count)
            return
        }
        generation += 1
        let mine = generation
        running?.cancel()
        let text = source, asked = request
        phase = .working(done: 0, total: TextParagraphs.units(TextParagraphs.split(text)).count)
        running = Task { [weak self, translator] in
            do {
                // The service's callbacks reach the main actor in any order, and a late one after the answer: only a step forward is shown, and none once settled.
                var shown = 0, settled = false
                let result = try await translator.translate(text, asked) { done, total, partial in
                    guard let self, mine == self.generation, !settled, done > shown else { return }
                    shown = done
                    self.translation = partial
                    self.phase = .working(done: done, total: total)
                }
                guard let self, mine == self.generation else { return }
                settled = true
                self.settle(result)
                self.onSettled?()
            } catch {
                guard let self, mine == self.generation else { return }
                self.translation = ""
                self.phase = .failed(String(localized: "Mwoyeo can’t use the profile or the engine picked here any more. Pick another."))
                self.onSettled?()
            }
        }
    }

    private func settle(_ result: TextTranslator.Result) {
        translation = result.translated ? result.text : ""
        switch result.issue {
        case let .languagePackMissing(from, to)? where !result.translated: phase = .needsPack(PackPair(source: from, target: to))
        case let .unsupportedPair(from, to)? where !result.translated: phase = .unsupported(PackPair(source: from, target: to))
        case let issue? where !result.translated || result.translatedUnits < result.units: phase = .failed(issue.message)
        case nil where !result.translated: phase = .failed(String(localized: "No engine answered."))
        default: phase = .done(engine: result.engine)
        }
    }

    // MARK: Actions

    func copyTranslation() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(translation, forType: .string)
    }

    /// "Download <language> (once)": the system's sheet over this window (`packDownload(in: .text)`).
    func downloadPack(_ pair: PackPair) { PackDownload.shared.request(pair, in: .text) }

    /// The text again, once the pack it waited for is installed.
    func retry() { translateNow() }

    /// What the text pane says while it is empty: a text and a way to ask are all it needs.
    var emptyHint: String {
        trigger == .onPause ? String(localized: "The translation appears here as you type.")
            : String(localized: "Press Translate to send the text to your engine.")
    }
}

struct TextTranslationView: View {
    @Bindable var model: TextTranslationModel
    @FocusState private var sourceFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            HStack(spacing: 0) {
                sourcePane
                Divider()
                translationPane
            }
            Divider()
            bar
        }
        .onAppear { sourceFocused = true }
        .onChange(of: model.focusRequests) { sourceFocused = true }
        .packDownload(in: .text) { installed in if installed { model.retry() } }
    }

    // MARK: Above the panes

    private var controls: some View {
        let settings = AppModel.shared.settings
        return HStack(spacing: 10) {
            if !settings.appProfiles.isEmpty { profileMenu(settings) }
            LanguageBar(source: Binding(get: { model.sourceLanguage ?? model.resolved?.source ?? "auto" }, set: { model.sourceLanguage = $0 }),
                        target: Binding(get: { model.targetLanguage ?? model.resolved?.target ?? "en" }, set: { model.targetLanguage = $0 }))
                .frame(width: 280)
            if !settings.engines.isEmpty { engineMenu(settings) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func profileMenu(_ settings: AppSettings) -> some View {
        let head = ProfileWords.head(settings, bundleID: model.anchorApp, title: nil, lensPin: model.profile)
        let caption = ProfileWords.caption(head: head, pin: model.profile == AppProfile.allAppsID ? .allAppsOnly : .auto, owner: .lens, limit: 24)
        return Menu {
            Picker("Profile", selection: $model.profile) {
                Text("Auto — the app in front").tag(String?.none)
                Text("All Apps Only").tag(String?.some(AppProfile.allAppsID))
                ForEach(settings.appProfiles) { p in Text(ProfileWords.cut(p.name, at: 24)).tag(String?.some(p.id)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Text(caption).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).accessibilityHidden(true)
            }
            .font(.callout).foregroundStyle(.secondary)
            // A hit area of 22 pt, as the menu footer's icons have (ui-audit-1-1-5 X1): the caption is one line of text high.
            .frame(minHeight: 22)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The profile decides the languages, the engine and the names, as it does for a lens")
        .accessibilityLabel(caption)
    }

    private func engineMenu(_ settings: AppSettings) -> some View {
        let chosen = model.engineChoice ?? model.resolved?.engine?.id.uuidString ?? "apple"
        let current = settings.engines.first { $0.id.uuidString == chosen }
        return Menu {
            Picker("", selection: Binding(get: { chosen }, set: { model.engineChoice = $0 })) {
                Text("Apple").tag("apple")
                ForEach(settings.engines) { Text($0.name).tag($0.id.uuidString) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                if let current { Image(systemName: current.badgeSymbol).font(.caption) }
                Text(current?.name ?? String(localized: "Apple")).font(.callout.weight(.medium)).lineLimit(1).frame(maxWidth: 120)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular, in: Capsule())
        .help("Translation engine")
        .accessibilityLabel("Translation engine")
        .accessibilityValue(current?.name ?? String(localized: "Apple"))
    }

    // MARK: Panes

    private var sourcePane: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $model.source)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($sourceFocused)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .accessibilityLabel("Text to translate")
            if model.source.isEmpty {
                Text("Type or paste text to translate.")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var translationPane: some View {
        ScrollView {
            Group {
                if model.translation.isEmpty {
                    Text(model.emptyHint).foregroundStyle(.tertiary)
                } else {
                    Text(model.translation).textSelection(.enabled).opacity(model.phase == .edited ? 0.6 : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            // The first line sits where the source's does: the editor's own inset and 8 pt, as the source pane has them.
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.4))
        // A named group whose text a screen reader reads as it is (the translation, or what the pane says while it has none).
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Translation")
    }

    // MARK: Below the panes

    private var bar: some View {
        HStack(spacing: 8) {
            status
            Spacer(minLength: 8)
            Button("Copy") { model.copyTranslation() }
                .disabled(model.translation.isEmpty)
            if model.trigger == .onRequest {
                Button("Translate") { model.translateNow() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.source.allSatisfy(\.isWhitespace))
            } else {
                Button("Translate") { model.translateNow() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.source.allSatisfy(\.isWhitespace))
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .empty, .typing, .edited: EmptyView()
        case let .working(done, total):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(total > 1 ? String(localized: "Translating \(done) of \(total)…") : String(localized: "Translating…")).font(.caption).foregroundStyle(.secondary)
            }
        case let .done(engine):
            if let engine { Text("Translated with \(engine)").font(.caption).foregroundStyle(.secondary) }
        case let .needsPack(pair):
            HStack(spacing: 8) {
                switch PackDownload.shared.ledger.phase(of: pair) {
                case .downloading?:
                    ProgressView().controlSize(.small)
                    Text(LensHintText.downloading(pair)).font(.caption).foregroundStyle(.secondary)
                case .notFinished?:
                    Label(LensHintText.notFinishedState(pair), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.secondary)
                    Button("Try again") { model.downloadPack(pair) }.controlSize(.small)
                case nil:
                    Label("Language pack needed", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.secondary)
                    Button(LensHintText.downloadPack(pair)) { model.downloadPack(pair) }.controlSize(.small)
                }
            }
        case let .unsupported(pair):
            HStack(spacing: 8) {
                Label(LensHintText.notSupported(pair), systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.secondary)
                Button("Choose Languages") { AppModel.shared.openSettings(on: .general) }.controlSize(.small)
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.secondary).lineLimit(2)
        case let .tooLong(count):
            Label("The text is too long: \(count) characters. Up to \(TextParagraphs.maxCharacters) at a time.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// Owns the Translate Text window; one at a time. The text and the picks stay while the app runs, whether the window is shown or not.
@MainActor
final class TextTranslationWindow: NSObject, NSWindowDelegate {
    static let shared = TextTranslationWindow()

    let model = TextTranslationModel()
    private var window: NSWindow?

    private override init() { super.init() }

    var isShown: Bool { window?.isVisible == true }

    /// The menu items, the shortcut and the Services entry. `text` replaces what is in the source pane; `translating` translates it at once,
    /// with either kind of engine: the person asked.
    func show(text: String? = nil, translating: Bool = false) {
        model.anchor(to: AppModel.shared.frontmostBundleID)
        if let text { model.source = text }
        let w = window ?? makeWindow()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        if translating { model.translateNow() }
    }

    private func makeWindow() -> NSWindow {
        let host = NSHostingController(rootView: TextTranslationView(model: model))
        let w = NSWindow(contentViewController: host)
        w.title = String(localized: "Translate Text")
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 680, height: 340)
        w.delegate = self
        w.setContentSize(NSSize(width: 840, height: 460))
        w.center()
        window = w
        return w
    }

    func close() { window?.close() }

    /// The window as a screenshot: just this window, by id (`screencapture -l`), shadow off.
    func capture(to url: URL) {
        guard let w = window else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(w.windowNumber), url.path]
        try? p.run()
        p.waitUntilExit()
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}
