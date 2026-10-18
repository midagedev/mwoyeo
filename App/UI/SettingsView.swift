import Carbon.HIToolbox
import MwoyeoCore
import ServiceManagement
import SwiftUI
import Translation

/// The tabs of Settings; the app can open it on one (`AppModel.settingsTab`).
enum SettingsTab: Hashable {
    case general, translation, appearance, shortcuts, about
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) { GeneralSettings() }
            Tab("Translation", systemImage: "character.bubble", value: SettingsTab.translation) { TranslationSettings() }
            Tab("Appearance", systemImage: "textformat", value: SettingsTab.appearance) { AppearanceSettings() }
            Tab("Shortcuts", systemImage: "command", value: SettingsTab.shortcuts) { ShortcutSettings() }
            Tab("About", systemImage: "info.circle", value: SettingsTab.about) { AboutView() }
        }
        .frame(width: 560, height: 520)
        // A lens's "Download <language>" (`AppModel.downloadPack`): the system's sheet comes up over this window.
        .packDownload(in: .settings)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Languages") {
                Picker("Translate from", selection: $model.settings.sourceLanguage) {
                    ForEach(Languages.sources, id: \.self) { Text(Languages.name($0)).tag($0) }
                }
                Picker("Translate to", selection: $model.settings.targetLanguage) {
                    ForEach(Languages.targets, id: \.self) { Text(Languages.name($0)).tag($0) }
                }
            }
            Section {
                Picker("Display", selection: $model.settings.renderMode) {
                    ForEach(RenderMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(model.settings.renderMode.detail).font(.caption).foregroundStyle(.secondary)
                if model.settings.renderMode == .adaptive {
                    LabeledContent("Rewrite after stillness") {
                        Slider(value: $model.settings.settleDelay, in: 0.2...2, step: 0.1) {
                            EmptyView()
                        } minimumValueLabel: { Text("Sooner").font(.caption) } maximumValueLabel: { Text("Later").font(.caption) }
                    }
                }
            } header: {
                Text("Rendering")
            }
            Section {
                LabeledContent("Screen checks") {
                    Picker("", selection: $model.settings.framesPerSecond) {
                        Text("Saver (4 fps)").tag(4.0)
                        Text("Normal (8 fps)").tag(8.0)
                        Text("Fast (15 fps)").tag(15.0)
                    }
                    .labelsHidden()
                }
                Text("Text is read again only when the screen changes. A still screen uses almost no power.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            } header: {
                Text("Performance")
            }
            Section {
                Toggle("Save transcripts", isOn: $model.settings.savesTranscripts)
                Text("Each lens writes what it reads and its translation to Markdown and SRT files.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Folder") {
                    Text((model.settings.exportFolder as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Choose…", action: chooseFolder)
                    Button("Show in Finder", action: showFolder)
                }
            } header: {
                Text("Saving")
            }
            Section {
                LabeledContent("Settings file") {
                    Button("Open") { model.openSettingsFile() }
                    Button("Show in Finder") { model.showSettingsFile() }
                }
                .buttonStyle(.borderless)
                // A borderless button in a form row is drawn grey, like a disabled label; the accent says it is a button.
                .foregroundStyle(.tint)
                if let note = issueNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The first problem found in settings.json, and how many more there are; nil while there is none.
    private var issueNote: String? {
        guard let first = model.settingsIssues.first else { return nil }
        let text = first.line.map { String(localized: "Line \($0): \(first.message)") } ?? first.message
        let more = model.settingsIssues.count - 1
        return more > 0 ? String(localized: "\(text) · \(more) more") : text
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.settings.exportFolder)
        if panel.runModal() == .OK, let url = panel.url { model.settings.exportFolder = url.path }
    }

    /// The folder itself once something was saved there, else the nearest folder above it that exists.
    private func showFolder() {
        var url = URL(fileURLWithPath: model.settings.exportFolder)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        NSWorkspace.shared.open(url)
    }
}

struct TranslationSettings: View {
    @Environment(AppModel.self) private var model
    @State private var cached = 0
    @State private var sheet: EngineSheetTarget?
    @State private var removing: EngineConfig?
    /// The active added engine's speed, polled; nil (no row at all) until it has enough batches.
    @State private var speed: SpeedSummary?
    private let intelligence = IntelligenceTranslator()

    /// The radio in use: an Apple choice, or an added engine.
    private var selection: Binding<EngineSelection> {
        Binding(get: { EngineSelection(model.settings) }, set: { model.select($0) })
    }

    /// The paragraph reader remembered for one app; nil follows the default (Automatic).
    private func readerChoice(for p: AppProfile) -> Binding<ParagraphReader?> {
        Binding(get: { model.profile(for: p.bundleID)?.paragraphReader },
                set: { choice in
                    guard var updated = model.profile(for: p.bundleID) else { return }
                    updated.paragraphReader = choice
                    model.remember(updated)
                })
    }

    /// The languages, and the paragraph reader only when it is not the automatic one.
    private func profileDetail(_ p: AppProfile) -> String {
        let pair = "\(Languages.name(p.source)) → \(Languages.name(p.target))"
        guard let reader = p.paragraphReader, reader != .automatic else { return pair }
        return "\(pair) · \(reader.title)"
    }

    /// Languages remembered per app (from a lens's menu); the group exists only once there is one.
    private var appProfiles: some View {
        Section {
            ForEach(model.settings.appProfiles) { p in
                LabeledContent {
                    // The rarely needed choices stay behind ⋯, as on the added engine rows.
                    Menu {
                        Picker("Paragraphs", selection: readerChoice(for: p)) {
                            Text("Automatic").tag(ParagraphReader?.none)
                            ForEach(ParagraphReader.allCases.filter { $0 != .automatic }, id: \.self) { Text($0.title).tag(ParagraphReader?.some($0)) }
                        }
                        Divider()
                        Button("Forget This App", role: .destructive) { model.forgetProfile(p.bundleID) }
                    } label: { Image(nsImage: .moreActions) }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More actions for \(p.appName)")
                        .accessibilityLabel("More actions for \(p.appName)")
                } label: {
                    VStack(alignment: .leading) {
                        Text(p.appName)
                        Text(profileDetail(p)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("App profiles")
        } footer: {
            Text("The app in front picks the languages, one pair at a time.").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// One added engine's actions: the ⋯ button on its row and the right-click menu.
    @ViewBuilder private func engineActions(_ engine: EngineConfig) -> some View {
        Button("Edit…") { sheet = .edit(engine) }
        Button("Duplicate") { model.duplicateEngine(engine.id) }
        Button("Copy Setup") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(EngineShare.encode(engine), forType: .string)
        }
        Divider()
        Button("Remove…", role: .destructive) { removing = engine }
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Translation engine") {
                Picker("Engine", selection: selection) {
                    ForEach(TranslationEngineChoice.offered) { choice in
                        VStack(alignment: .leading) {
                            Text(choice.title)
                            Text(choice.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(EngineSelection.builtIn(choice))
                    }
                    ForEach(model.settings.engines) { engine in
                        AddedEngineLabel(engine: engine) { engineActions(engine) }.tag(EngineSelection.added(engine.id))
                    }
                }
                .pickerStyle(.radioGroup)
                .contextMenu {
                    ForEach(model.settings.engines) { engine in
                        Section(engine.name) { engineActions(engine) }
                    }
                }
                Button { sheet = .add } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").foregroundStyle(.secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Add another engine…")
                            Text("Gemini, DeepSeek, Ollama, your own server").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let speed { SpeedLine(summary: speed) }
                LabeledContent("Apple Intelligence") {
                    if let why = intelligence.unavailableReason {
                        Label(why, systemImage: "xmark.circle").foregroundStyle(.secondary)
                    } else {
                        Label("Available · on device", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                }
            }
            .task(id: model.settings.activeEngineConfig?.id) {
                while !Task.isCancelled {
                    speed = model.settings.activeEngineConfig.flatMap { model.translator.speedSummary(for: $0.id) }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            .sheet(item: $sheet) { target in
                switch target {
                case .add: EngineSheet().environment(model)
                case let .edit(engine): EngineSheet(editing: engine).environment(model)
                }
            }
            .confirmationDialog("Remove this engine?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                presenting: removing) { engine in
                Button("Remove \(engine.name)", role: .destructive) { model.removeEngine(engine.id) }
            } message: { _ in
                Text("Its saved key is deleted from the Keychain.")
            }
            Section {
                LanguagePacksView(source: model.settings.sourceLanguage, target: model.settings.targetLanguage) {
                    Task { await model.languagePacksChanged() }
                }
            } header: {
                Text("Apple Translation language packs")
            } footer: {
                Text("Language packs are stored on this Mac and translate quickly, even offline.").font(.caption).foregroundStyle(.secondary)
            }
            if !model.settings.appProfiles.isEmpty { appProfiles }
            Section {
                Picker("Keep up to", selection: $model.settings.cacheSize) {
                    ForEach([1000, 5000, 20000], id: \.self) { n in
                        Text("\(n.formatted()) translations").tag(n)
                    }
                }
                LabeledContent("Held now") {
                    HStack {
                        Text(cached.formatted()).monospacedDigit()
                        Button("Clear") {
                            model.translator.clearCache()
                            cached = model.translator.cachedCount
                        }
                        .disabled(cached == 0)
                    }
                }
            } header: {
                Text("Translation memory")
            } footer: {
                Text("Text seen again is shown from memory instead of being translated again. It is kept only while Mwoyeo runs and is never written to disk.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { cached = model.translator.cachedCount }
            Section {
                TextEditor(text: $model.settings.glossary)
                    .font(.body.monospaced())
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if model.settings.glossary.isEmpty {
                            Text("勇者 = Hero\nポーション = Potion").foregroundStyle(.tertiary).font(.body.monospaced())
                                .padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
            } header: {
                Text("Glossary")
            } footer: {
                Text("One \"original = translation\" per line. Apple Intelligence uses these exactly, and text recognition uses them as hints.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The pack the lenses use now (the chosen pair; none while the source is automatic) and "All Languages" with the installed
/// count, holding every pair: the section is one or two rows, not one per language.
struct LanguagePacksView: View {
    let source: String
    let target: String
    var onChange: () -> Void
    @State private var status: [String: LanguageAvailability.Status] = [:]
    @State private var downloading: TranslationSession.Configuration?
    @State private var showsAll = false

    private var sources: [String] { Languages.sources.dropFirst().filter { $0 != target } }
    private var shown: [String] { source == "auto" || source == target ? [] : [source] }
    private var installed: Int { sources.filter { status[$0] == .installed }.count }

    var body: some View {
        ForEach(shown, id: \.self) { row($0) }
        DisclosureGroup(isExpanded: $showsAll) {
            ForEach(sources, id: \.self) { row($0) }
        } label: {
            LabeledContent("All Languages") {
                if !status.isEmpty { Text("\(installed) installed").foregroundStyle(.secondary) }
            }
        }
        .task(id: target) { await reload() }
        .onChange(of: PackDownload.shared.ended) { Task { await reload() } }
        .translationTask(downloading) { session in
            // Shows the system download sheet; returns once the pack is installed or the user declines.
            try? await session.prepareTranslation()
            await MainActor.run { downloading = nil }
            await reload()
            await MainActor.run { onChange() }
        }
    }

    private func row(_ source: String) -> some View {
        LabeledContent {
            switch status[source] {
            case .installed?:
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            case .supported?:
                Button("Download") {
                    downloading = TranslationSession.Configuration(source: Locale.Language(identifier: source),
                                                                   target: Locale.Language(identifier: target))
                }
                .disabled(downloading != nil)
            case nil:
                ProgressView().controlSize(.small)
            default:
                Text("Not supported").foregroundStyle(.secondary)
            }
        } label: {
            Text(verbatim: "\(Languages.name(source)) → \(Languages.name(target))")
        }
    }

    private func reload() async {
        let availability = LanguageAvailability()
        var next: [String: LanguageAvailability.Status] = [:]
        for s in sources {
            next[s] = await availability.status(from: Locale.Language(identifier: s), to: Locale.Language(identifier: target))
        }
        await MainActor.run { status = next }
    }
}

struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Lens") {
                HStack(spacing: 8) {
                    ForEach(LensStyle.allCases) { style in
                        LensStyleCard(style: style, tint: model.settings.lensTint, selected: model.settings.lensStyle == style) { model.settings.lensStyle = style }
                    }
                }
                .frame(maxWidth: .infinity)
                Picker("Colour", selection: $model.settings.lensTint) {
                    ForEach(LensTint.allCases) { tint in
                        Label { Text(tint.title) } icon: { Image(nsImage: Self.swatch(tint)) }.tag(tint)
                    }
                }
                Picker("Name tag", selection: $model.settings.lensTabVisibility) {
                    ForEach(LensTabVisibility.allCases) { Text($0.title).tag($0) }
                }
                Picker("Name tag position", selection: $model.settings.lensTabPosition) {
                    ForEach(LensTabPosition.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Text") {
                Picker("Font", selection: $model.settings.fontStyle) {
                    ForEach(FontStyleChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Colour, weight and size are matched to the original text.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Quick boxes") {
                LabeledContent("Opacity") {
                    Slider(value: $model.settings.boxOpacity, in: 0.6...1)
                }
            }
            Section {
                Toggle("Erase from textured backgrounds with AI", isOn: $model.settings.useInpaintingModel)
                    .disabled(!model.inpaintingAvailable)
                LabeledContent("Inpainting model") {
                    if model.inpaintingAvailable {
                        Label("MI-GAN · Core ML (GPU)", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        Label("Not installed", systemImage: "xmark.circle").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Erasing the original")
            } footer: {
                Text("Flat and gradient backgrounds are filled from their surroundings. On photos and artwork, an on-device inpainting model redraws the background.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// A small round sample of a tint's colours (not a template image, so a menu keeps its colours).
    private static func swatch(_ tint: LensTint) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSGradient(colors: Array(tint.colors.prefix(4)))?.draw(in: NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)), angle: -45)
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// A lens in miniature, drawn in one style, to pick from.
private struct LensStyleCard: View {
    let style: LensStyle
    let tint: LensTint
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.13))
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach([0.9, 0.7, 0.8, 0.45], id: \.self) { f in
                            Capsule().fill(.white.opacity(0.75)).frame(width: 52 * f, height: 3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 18)
                    ring.padding(10)
                }
                .frame(width: 100, height: 64)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5)
                        .padding(-4)
                }
                Text(style.title).font(.callout.weight(selected ? .semibold : .regular))
            }
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var ring: some View {
        switch style {
        case .glow: LensRing(cornerRadius: 7, lineWidth: 1.3, glow: 3, tint: tint)
        case .subtle: LensRing(cornerRadius: 7, lineWidth: 0.9, glow: 0, tint: tint)
        case .corners:
            CornerBrackets(cornerRadius: 7, arm: 7)
                .stroke(Brand.ring(.degrees(45), tint: tint), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        case .minimal: RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.white.opacity(0.4), lineWidth: 0.9)
        }
    }
}

private struct ShortcutSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action.title) { ShortcutRecorder(action: action) }
                }
            } footer: {
                Text("These work in any app. If a shortcut also does something in another app, record a different one: macOS can’t tell Mwoyeo when two apps want the same keys.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Restore Defaults") { model.settings.shortcuts = HotKeyAction.defaults }
                    .disabled(model.settings.shortcuts == HotKeyAction.defaults)
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then press the new shortcut. Esc cancels; ⌫ removes the shortcut.
private struct ShortcutRecorder: View {
    @Environment(AppModel.self) private var model
    let action: HotKeyAction
    @State private var monitor: Any?

    private var combo: KeyCombo? { model.settings.shortcuts[action.rawValue] }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                monitor == nil ? start() : stop()
            } label: {
                Text(monitor != nil ? String(localized: "Type a shortcut…") : combo?.display ?? String(localized: "Record Shortcut"))
                    .font(combo != nil && monitor == nil ? .body.weight(.medium) : .body)
                    .frame(width: 130)
            }
            .buttonStyle(.bordered)
            .tint(monitor != nil ? .accentColor : nil)
            Button { model.settings.shortcuts[action.rawValue] = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.tertiary)
                .help("Remove Shortcut")
                .opacity(combo != nil && monitor == nil ? 1 : 0)
                .disabled(combo == nil || monitor != nil)
        }
        .onDisappear { stop() }
    }

    private func start() {
        // Unregistered while recording, so pressing a current shortcut records it instead of firing it.
        HotKeys.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch Int(e.keyCode) {
            case kVK_Escape: stop()
            case kVK_Delete, kVK_ForwardDelete:
                model.settings.shortcuts[action.rawValue] = nil
                stop()
            default:
                guard let c = KeyCombo(event: e) else { NSSound.beep(); return nil }
                var all = model.settings.shortcuts
                for (k, v) in all where v.keyCode == c.keyCode && v.modifiers == c.modifiers { all[k] = nil } // one action per combo
                all[action.rawValue] = c
                model.settings.shortcuts = all
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        HotKeys.shared.apply(model.settings.shortcuts)
    }
}

private struct AboutView: View {
    @Environment(AppModel.self) private var model
    private let updates = Updates.shared

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 10) {
            AppGlyph(size: 80)
            Text("Mwoyeo").font(.largeTitle.weight(.semibold))
            Text("Translates the screen in place, wherever you put a lens.")
                .foregroundStyle(.secondary)
            Text("Version \(Updates.version) (\(Updates.build))")
                .font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)

            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Button("Check for Updates") { Task { await updates.check() } }
                        .disabled(updates.state == .checking)
                    updateStatus.font(.callout)
                }
                Toggle("Check automatically once a day", isOn: $model.settings.checksForUpdates)
                    .toggleStyle(.checkbox).font(.callout)
            }
            .padding(.top, 6)

            HStack(spacing: 18) {
                Link(destination: Updates.repository) { Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                Link(destination: Updates.releases) { Label("Release Notes", systemImage: "doc.text") }
                Link(destination: Updates.issues) { Label("Report a Problem", systemImage: "exclamationmark.bubble") }
            }
            .font(.callout)
            .padding(.top, 4)
            HStack(spacing: 18) {
                Link(destination: URL(string: "mailto:midagedev@gmail.com")!) {
                    Label { Text(verbatim: "midagedev@gmail.com") } icon: { Image(systemName: "envelope") }
                }
                Link(destination: URL(string: "https://x.com/midagedev")!) {
                    Label { Text(verbatim: "@midagedev") } icon: { Image(systemName: "at") }
                }
            }
            .font(.callout)

            Divider().frame(width: 300).padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 6) {
                Label("Screen text is read, erased and translated on this Mac and never leaves it", systemImage: "lock.shield")
                Label("Update checks ask GitHub for the latest version and count installs without any identifier", systemImage: "arrow.down.circle")
                Label("Vision · Translation · Apple Intelligence · Core ML", systemImage: "apple.intelligence")
                Label("Inpainting: MI-GAN (Picsart AI Research, MIT)", systemImage: "paintbrush")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Text(verbatim: "© 2026 midagedev · MIT License").font(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var updateStatus: some View {
        switch updates.state {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Label("Mwoyeo is up to date", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Label("Couldn’t reach GitHub", systemImage: "wifi.exclamationmark").foregroundStyle(.secondary)
        case .available(let version, let page):
            HStack(spacing: 6) {
                Text("Version \(version) is available").foregroundStyle(Color.accentColor)
                Button(Updates.viaHomebrew ? String(localized: "What’s New") : String(localized: "Download")) { NSWorkspace.shared.open(page) }
                    .controlSize(.small)
            }
        }
    }
}

enum EngineSheetTarget: Identifiable {
    case add
    case edit(EngineConfig)
    var id: String {
        switch self {
        case .add: "add"
        case let .edit(e): e.id.uuidString
        }
    }
}

/// An added engine's radio label, laid out like the Apple choices: its name, then where it runs and its measured time.
private struct AddedEngineLabel<Actions: View>: View {
    @Environment(AppModel.self) private var model
    let engine: EngineConfig
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading) {
                Text(engine.name).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                TimelineView(.periodic(from: .now, by: 2)) { _ in
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            Menu { actions } label: { Image(nsImage: .moreActions) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions for \(engine.name)")
                .accessibilityLabel("More actions for \(engine.name)")
        }
    }

    private var detail: String {
        engine.subtitle + (model.translator.measuredSeconds(for: engine.id).map { String(format: " · ~%.1f s", $0) } ?? "")
    }
}

/// "First result 0.3 s · 62% from memory", for the engine in use once it has run a few batches.
private struct SpeedLine: View {
    let summary: SpeedSummary

    var body: some View {
        Text("First result \(String(format: "%.1f", summary.seconds)) s · \(Int((summary.fromMemory * 100).rounded()))% from memory")
            .font(.caption).foregroundStyle(.secondary)
    }
}

extension ParagraphReader {
    var title: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .documentLayout: String(localized: "Document layout")
        case .lineGrouping: String(localized: "Line grouping")
        }
    }
}

extension NSImage {
    /// The ⋯ of a row's menu in the secondary label colour: a borderless menu button draws a template image in the primary
    /// colour whatever the SwiftUI style says, so the colour is in the image (vision verdict, 2026-10-18).
    static let moreActions: NSImage = {
        let symbol = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil) ?? NSImage()
        return symbol.withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor])) ?? symbol
    }()
}

/// Four corner brackets: a quarter arc with an arm along each side, as the lens draws them.
private struct CornerBrackets: Shape {
    var cornerRadius: CGFloat
    var arm: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = cornerRadius, a = arm
        // y down: top-left, top-right, bottom-right, bottom-left.
        p.move(to: CGPoint(x: r.minX, y: r.minY + c + a))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + c, y: r.minY), radius: c)
        p.addLine(to: CGPoint(x: r.minX + c + a, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - c - a, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + c), radius: c)
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + c + a))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - c - a))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - c, y: r.maxY), radius: c)
        p.addLine(to: CGPoint(x: r.maxX - c - a, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + c + a, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - c), radius: c)
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - c - a))
        return p
    }
}
