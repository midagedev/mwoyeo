import Carbon.HIToolbox
import MwoyeoCore
import ServiceManagement
import SwiftUI

/// The tabs of Settings; the app can open it on one (`AppModel.settingsTab`).
enum SettingsTab: Hashable {
    case general, translation, appearance, shortcuts, about

    /// The pane's height; the window follows the pane (HIG, Settings: "a settings window accommodates the size of the current pane";
    /// ui-audit-1-1-5 7.2). General, Translation and Appearance are as tall as their content up to 640 pt, then scroll. About is not a scrolling form, so
    /// it keeps room for a line that wraps in another language.
    var height: CGFloat {
        switch self {
        case .general, .translation: 640
        case .appearance: 640   // "Erasing the original" needs ~170 pt below Quick boxes (vision ui-fixes 7.2)
        case .about: 520
        case .shortcuts: 480
        }
    }
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
        .frame(width: 560, height: model.settingsTab.height)
        // A lens's "Download <language>" (`AppModel.downloadPack`): the system's sheet comes up over this window.
        .packDownload(in: .settings)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var restoring = false

    var body: some View {
        @Bindable var model = model
        Form {
            // Open at login is not about speed: it heads the pane, with no header of its own (ui-audit-1-1-5 3.3).
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
            Section("Languages") {
                Picker("Translate from", selection: $model.settings.sourceLanguage) {
                    ForEach(Languages.sources, id: \.self) { Text(Languages.name($0)).tag($0) }
                }
                Picker("Translate to", selection: $model.settings.targetLanguage) {
                    ForEach(Languages.targets, id: \.self) { Text(Languages.name($0)).tag($0) }
                }
            }
            // A caption is the second Text of its control's label: the grouped form draws it as the row's subtitle, not as a row of its own
            // (ui-audit-1-1-5 3.1).
            Section {
                Picker(selection: $model.settings.renderMode) {
                    ForEach(RenderMode.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Style")
                    Text(model.settings.renderMode.detail)
                }
                .pickerStyle(.segmented)
                if model.settings.renderMode == .adaptive {
                    LabeledContent("Rewrite after stillness") {
                        Slider(value: $model.settings.settleDelay, in: 0.2...2, step: 0.1) {
                            EmptyView()
                        } minimumValueLabel: { Text("Sooner").font(.caption) } maximumValueLabel: { Text("Later").font(.caption) }
                    }
                }
            } header: {
                Text("Display")
            }
            Section {
                Picker(selection: $model.settings.framesPerSecond) {
                    Text("Saver (4 fps)").tag(4.0)
                    Text("Normal (8 fps)").tag(8.0)
                    Text("Fast (15 fps)").tag(15.0)
                } label: {
                    Text("Screen checks")
                    Text("Text is read again only when the screen changes. A still screen uses almost no power.")
                }
            } header: {
                Text("Performance")
            }
            Section {
                Toggle(isOn: savesTranscripts) {
                    Text("Save transcripts")
                    Text("Each lens writes what it reads and its translation to Markdown and SRT files, with the names and terms an engine learns.")
                }
                // Turning saving on already asks for a folder, so the row is for a person who has one (ui-audit-1-1-5 3.5).
                if model.settings.savesTranscripts {
                    LabeledContent("Folder") {
                        Text(ExportFolder.shownPath(model.settings).map { ($0 as NSString).abbreviatingWithTildeInPath } ?? String(localized: "None chosen"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                            .accessibilityLabel(Text(verbatim: "\(String(localized: "Choose…")), \(String(localized: "Folder"))"))
                        Button("Show in Finder", action: showFolder).disabled(ExportFolder.shownPath(model.settings) == nil)
                            .accessibilityLabel(Text(verbatim: "\(String(localized: "Show in Finder")), \(String(localized: "Folder"))"))
                    }
                }
            } header: {
                Text("Saving")
            }
            Section {
                LabeledContent("Settings file") {
                    // The accent says these are buttons (a borderless one is drawn grey in a form row); it goes on the buttons, not on the label.
                    HStack {
                        Button("Open") { model.openSettingsFile() }
                            .accessibilityLabel(Text(verbatim: "\(String(localized: "Open")), \(String(localized: "Settings file"))"))
                        Button("Show in Finder") { model.showSettingsFile() }
                            .accessibilityLabel(Text(verbatim: "\(String(localized: "Show in Finder")), \(String(localized: "Settings file"))"))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tint)
                }
                if let note = issueNote {
                    Label { Text(note).foregroundStyle(.secondary) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
                        .font(.caption)
                }
                if Distribution.isAppStore { ImportSettingsRow() }
                Toggle(isOn: $model.settings.agentConnection) {
                    Text("Connect an agent (MCP)")
                    Text("Lets an agent such as Claude Code read the translation log, change settings and write each app’s memory.")
                }
                if model.settings.agentConnection {
                    LabeledContent("Run in a terminal") {
                        Button("Copy") { LensText.copy([MCPServer.addCommand()]) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tint)
                            .accessibilityLabel(Text(verbatim: "\(String(localized: "Copy")), \(String(localized: "Connect an agent (MCP)"))"))
                    }
                    Text(MCPServer.addCommand()).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } header: {
                Text("Advanced")
            }
            RestoreDefaultsFoot(tab: .general) { restoring = true }
        }
        .formStyle(.grouped)
        .restoreDefaultsSheet(tab: .general, isPresented: $restoring)
    }

    /// The first problem found in settings.json, and how many more there are; nil while there is none.
    private var issueNote: String? {
        guard let first = model.settingsIssues.first else { return nil }
        let text = first.line.map { String(localized: "Line \($0): \(first.message)") } ?? first.message
        let more = model.settingsIssues.count - 1
        return more > 0 ? String(localized: "\(text) · \(more) more") : text
    }

    /// Turning saving on with no folder asks for one first; cancelling leaves it off.
    private var savesTranscripts: Binding<Bool> {
        Binding(get: { model.settings.savesTranscripts },
                set: { on in
                    if on, ExportFolder.shownPath(model.settings) == nil, !chooseFolder() { return }
                    model.settings.savesTranscripts = on
                })
    }

    @discardableResult
    private func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        if let shown = ExportFolder.shownPath(model.settings) { panel.directoryURL = URL(fileURLWithPath: shown) }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        if let bookmark = ExportFolder.makeBookmark(for: url) {
            model.chooseExportFolder(url, bookmark: bookmark)
        } else if !Distribution.isAppStore {
            // Not sandboxed: the path alone still works.
            model.settings.exportFolder = url.path
            model.settings.exportBookmark = nil
        } else {
            return false
        }
        ExportFolderGate.shared.reset()
        return true
    }

    /// The folder itself once something was saved there, else the nearest folder above it that exists.
    private func showFolder() {
        guard let shown = ExportFolder.shownPath(model.settings) else { return }
        var url = URL(fileURLWithPath: shown)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        NSWorkspace.shared.open(url)
    }
}

struct TranslationSettings: View {
    @Environment(AppModel.self) private var model
    @State private var cached = 0
    @State private var sheet: EngineSheetTarget?
    @State private var removing: EngineConfig?
    @State private var removingProfile: AppProfile?
    @State private var showAllProfiles = false
    @State private var restoring = false
    private let routes = ProfileRoutes.shared
    /// The active added engine's speed, polled; nil (no row at all) until it has enough batches.
    @State private var speed: SpeedSummary?
    private let intelligence = IntelligenceTranslator()

    /// The radio in use: an Apple choice, or an added engine.
    private var selection: Binding<EngineSelection> {
        Binding(get: { EngineSelection(model.settings) }, set: { model.select($0) })
    }

    // MARK: Profiles (design names-and-context §6.2)

    /// The first rows the list shows; "Show All n Profiles" opens the rest in place (≤ 50).
    private static let shownProfiles = 6

    /// All apps' row: "Everywhere else · Japanese → Korean · glossary 2".
    private var allAppsSubtitle: String {
        let s = model.settings
        return "\(String(localized: "Everywhere else")) · \(ProfileWords.pair(s.sourceLanguage, s.targetLanguage)) · \(String(localized: "glossary \(s.glossaryPairs.count)"))"
    }

    /// A profile's row: the name (cut in the middle at 32), and one line under it, the first part cut being the memory, then the pair, never where.
    private func profileSubtitle(_ p: AppProfile) -> some View {
        HStack(spacing: 0) {
            Text(ProfileWords.whereLine(p, in: model.settings.appProfiles)).lineLimit(1).layoutPriority(2)
            Text(verbatim: " · \(ProfileWords.pair(p.source, p.target))").lineLimit(1).layoutPriority(1)
            if let memory = ProfileWords.memoryLine(p) { Text(verbatim: " · \(memory)").lineLimit(1).truncationMode(.tail) }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    /// The subtitle as one line, for a screen reader and the tooltip.
    private func profileSubtitleLine(_ p: AppProfile) -> String {
        [ProfileWords.whereLine(p, in: model.settings.appProfiles), ProfileWords.pair(p.source, p.target), ProfileWords.memoryLine(p)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Profiles made or converted (from a lens's menu, or here); the section exists only once there is one.
    private var profilesSection: some View {
        let all = model.settings.appProfiles
        let shown = showAllProfiles ? all : Array(all.prefix(Self.shownProfiles))
        return Section {
            profileRow(title: String(localized: "All apps"), subtitle: Text(allAppsSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1),
                       spoken: allAppsSubtitle, pinned: model.settings.profilePin == AppProfile.allAppsID, open: { model.memoryTarget = .allApps }) {
                Button("Edit…") { model.memoryTarget = .allApps }
            }
            ForEach(shown) { p in
                profileRow(title: ProfileWords.cut(p.name, at: 32), subtitle: profileSubtitle(p), spoken: profileSubtitleLine(p), pinned: model.settings.profilePin == p.id,
                           open: { model.memoryTarget = MemoryTarget(id: p.id, name: p.name, kind: .profile) }) {
                    Button("Edit…") { model.memoryTarget = MemoryTarget(id: p.id, name: p.name, kind: .profile) }
                    Button("Duplicate") { duplicate(p) }
                    if model.settings.profilePin == p.id {
                        Button("Back to Auto") { model.pinEveryLens(nil) }
                    } else {
                        Button("Use for Every Lens") { model.pinEveryLens(p.id) }
                    }
                    Divider()
                    Button("Remove…", role: .destructive) { removingProfile = p }
                }
            }
            if all.count > Self.shownProfiles, !showAllProfiles {
                Button { withAnimation(Motion.shared.animation(.snappy)) { showAllProfiles = true } } label: {
                    Label("Show All \(all.count) Profiles", systemImage: "chevron.down")
                }
                .labelStyle(ListActionLabelStyle())
                .buttonStyle(.borderless).foregroundStyle(.tint)
            }
            Button { newProfile() } label: { Label("New Profile…", systemImage: "plus") }
                .labelStyle(ListActionLabelStyle())
                .buttonStyle(.borderless).foregroundStyle(.tint)
                .disabled(all.count >= AppProfile.maxProfiles)
        } header: {
            Text("Profiles")
        } footer: {
            Text("Each lens uses the closest match: a window title, then an app, then All apps. To choose by hand, use a lens’s menu or the menu bar.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The two actions at the foot of the list start their words at one edge: a glyph in a column of its own (ui-all A4: "Show All 8 Profiles" began 26 pt left of "New Profile…").
    private struct ListActionLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 8) {
                configuration.icon.frame(width: 18)
                configuration.title
            }
        }
    }

    /// One row: a click opens the sheet; "Pinned" while every lens is pinned to it; ⋯ (≥ 20 pt) holds the rest.
    private func profileRow<Actions: View>(title: String, subtitle: some View, spoken: String, pinned: Bool, open: @escaping () -> Void,
                                           @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).lineLimit(1)
                        subtitle
                    }
                    Spacer(minLength: 4)
                    if pinned { Text("Pinned").font(.caption).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // One element: the name, and where it is used, its languages and what it keeps as its value ("Pinned" is told too).
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(pinned ? "\(spoken) · \(String(localized: "Pinned"))" : spoken)
            .accessibilityAddTraits(.isButton)
            Menu { actions() } label: { Image(nsImage: .moreActions) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 22, height: 22).contentShape(Rectangle())   // ui-audit-1-1-5 X1
                .help("More actions for \(title)")
                .accessibilityLabel("More actions for \(title)")
        }
    }

    private func duplicate(_ p: AppProfile) {
        var copy = p
        copy.name = ContextText.truncated(String(localized: "\(p.name) copy"), toCharacters: AppProfile.maxNameLength)
        copy.id = ProfileIDs.fresh(named: copy.name, in: model.settings.appProfiles)
        guard model.settings.appProfiles.count < AppProfile.maxProfiles, let i = model.settings.appProfiles.firstIndex(where: { $0.id == p.id }) else { return }
        model.settings.appProfiles.insert(copy, at: i + 1)
    }

    /// "New Profile…": a preset made by hand; the sheet opens on Customize with the name ready, and stores nothing until the first edit.
    private func newProfile() {
        let s = model.settings
        let name = String(localized: "New Profile")
        let draft = AppProfile(bundleID: "", appName: name, source: s.sourceLanguage, target: s.targetLanguage,
                               id: ProfileIDs.fresh(named: name, in: s.appProfiles), name: name, when: [])
        model.memoryTarget = MemoryTarget(id: draft.id, name: name, kind: .new, draft: draft)
    }

    /// "Tell the translator · ≈ 9 tokens a pair", "Swap into the text · free": the glossary's one mode, with what a pair costs (the budget's own count).
    private func glossaryItem(_ apply: EntryApply) -> String {
        let pairs = model.settings.glossaryPairs
        let tokens = pairs.isEmpty ? 0 : pairs.map { ContextMemory.hintCost(MemoryEntry(src: $0.0, dst: $0.1, kind: .term)) }.reduce(0, +) / pairs.count
        switch apply {
        case .hint: return String(localized: "Tell the translator · ≈ \(tokens) tokens a pair")
        case .replace: return String(localized: "Swap into the text · free")
        case .both: return String(localized: "Both · ≈ \(tokens) tokens a pair")
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
                        AddedEngineLabel(engine: engine, allow: { sheet = .allow(engine) }) { engineActions(engine) }.tag(EngineSelection.added(engine.id))
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()   // the section header says it (ui-audit-1-1-5 4.3); a screen reader still gets "Engine"
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
                case let .allow(engine): EngineSheet(editing: engine, focusConsent: true).environment(model)
                case let .context(engine): EngineSheet(editing: engine, autopilot: .init(expandContext: true)).environment(model)
                }
            }
            .confirmationDialog("Remove this engine?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                presenting: removing) { engine in
                Button("Remove \(engine.name)", role: .destructive) { model.removeEngine(engine.id) }
            } message: { _ in
                Text("Its saved key is deleted from the Keychain.")
            }
            Section {
                LanguagePacksView(source: model.settings.sourceLanguage, target: model.settings.targetLanguage)
            } header: {
                Text("Apple Translation language packs")
            } footer: {
                Text("Language packs are stored on this Mac and translate quickly, even offline.").font(.caption).foregroundStyle(.secondary)
            }
            if !model.settings.appProfiles.isEmpty { profilesSection }
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
                Text("Recent translations")
            } footer: {
                Text("Text seen again is shown from this list instead of being translated again. The list is kept only while Mwoyeo runs and is never written to disk.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { cached = model.translator.cachedCount }
            Section {
                TextEditor(text: $model.settings.glossary)
                    .accessibilityLabel("Glossary")
                    .font(.body.monospaced())
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if model.settings.glossary.isEmpty {
                            Text("勇者 = Hero\nポーション = Potion").foregroundStyle(.tertiary).font(.body.monospaced())
                                .padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                // L1, once the glossary holds a pair (design §6.2): how the pairs are used, with the cost of each way.
                if !model.settings.glossaryPairs.isEmpty {
                    Picker("Use them", selection: $model.settings.glossaryApply) {
                        ForEach(EntryApply.allCases, id: \.self) { Text(glossaryItem($0)).tag($0) }
                    }
                }
            } header: {
                Text("Glossary")
            } footer: {
                Text("One “original = translation” per line. Apple Intelligence uses these exactly, and text recognition uses them as hints.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            RestoreDefaultsFoot(tab: .translation) { restoring = true }
        }
        .formStyle(.grouped)
        .restoreDefaultsSheet(tab: .translation, isPresented: $restoring)
        // The sheet is the model's (a lens's "Memory for <App>…" sets it), so it comes up for an app without a profile too, where the
        // "App profiles" section is not on screen.
        .sheet(item: $model.memoryTarget) { target in
            AppMemorySheet(target: target, model: model)
        }
        .confirmationDialog(removingProfile.map { String(localized: "Remove \(ProfileWords.cut($0.name, at: 24))?") } ?? "",
                            isPresented: Binding(get: { removingProfile != nil }, set: { if !$0 { removingProfile = nil } }),
                            presenting: removingProfile) { p in
            Button("Remove", role: .destructive) { model.removeProfile(id: p.id) }
        } message: { p in
            if let detail = ProfileWords.removeDetail(names: p.entries.count, hasNote: !p.note.isEmpty) { Text(detail) }
        }
        // "Change…" in the profile sheet: the sheet closes first, then the engine's sheet comes up with its Context open.
        .onChange(of: routes.engineToEdit) { _, id in
            guard let id, let engine = model.settings.engines.first(where: { $0.id == id }) else { return }
            routes.engineToEdit = nil
            Task { try? await Task.sleep(for: .milliseconds(400)); sheet = .context(engine) }
        }
    }
}

/// The pack the lenses use now (the chosen pair; none while the source is automatic) and "All Languages" with the installed
/// count, holding every pair: the section is one or two rows, not one per language. A row asks `PackDownload` for its pack like a
/// lens does, so there is one sheet, one record of what became of it, and the lens says the same as the row.
struct LanguagePacksView: View {
    let source: String
    let target: String
    @State private var status: [String: PackStatus] = [:]
    @State private var showsAll: Bool

    /// `expanded`: the list of every language is open from the start (the captures of rows in each state).
    init(source: String, target: String, expanded: Bool = false) {
        self.source = source
        self.target = target
        _showsAll = State(initialValue: expanded)
    }

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
    }

    private func row(_ source: String) -> some View {
        let pair = PackPair(source: source, target: target)
        let phase = PackDownload.shared.ledger.phase(of: pair)
        return LabeledContent {
            switch status[source] {
            case .installed?:
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            case .viaIntelligence?:
                // Nothing is stopped: Apple Intelligence translates this pair until the faster pack is here.
                HStack(spacing: 8) {
                    Text("Using Apple Intelligence").font(.caption).foregroundStyle(.secondary)
                    download(pair, phase)
                }
            case .downloadable?:
                download(pair, phase)
            case nil:
                ProgressView().controlSize(.small)
            case .unsupported?:
                Text("Not supported").foregroundStyle(.secondary)
            }
        } label: {
            Text(verbatim: "\(Languages.name(source)) → \(Languages.name(target))")
        }
    }

    /// The pack's ask, as far as it has got: the button, the sheet being up, or the sheet having ended without the pack.
    @ViewBuilder private func download(_ pair: PackPair, _ phase: PackLedger.Phase?) -> some View {
        switch phase {
        case .downloading?:
            ProgressView().controlSize(.small)
            Text("Downloading…").font(.caption).foregroundStyle(.secondary)
        case .notFinished?:
            Text("Didn’t finish").font(.caption).foregroundStyle(.secondary)
            Button("Try again") { PackDownload.shared.request(pair, in: .settings) }
        case nil:
            Button("Download") { PackDownload.shared.request(pair, in: .settings) }
        }
    }

    private func reload() async {
        var next: [String: PackStatus] = [:]
        for s in sources { next[s] = await PackDownload.shared.status(PackPair(source: s, target: target)) }
        await MainActor.run { status = next }
    }
}

struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model
    @State private var restoring = false

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
                Picker("Color", selection: $model.settings.lensTint) {
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
                Picker(selection: $model.settings.fontStyle) {
                    ForEach(FontStyleChoice.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Font")
                    Text("Color, weight and size are matched to the original text.")
                }
                .pickerStyle(.segmented)
            }
            Section("Quick boxes") {
                LabeledContent("Opacity") {
                    Slider(value: $model.settings.boxOpacity, in: 0.6...1) {
                        EmptyView()
                    } minimumValueLabel: { Text("Lighter").font(.caption) } maximumValueLabel: { Text("Solid").font(.caption) }
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
            RestoreDefaultsFoot(tab: .appearance) { restoring = true }
        }
        .formStyle(.grouped)
        .restoreDefaultsSheet(tab: .appearance, isPresented: $restoring)
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

struct ShortcutSettings: View {
    @Environment(AppModel.self) private var model
    @State private var restoring = false

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
            RestoreDefaultsFoot(tab: .shortcuts) { restoring = true }
        }
        .formStyle(.grouped)
        .restoreDefaultsSheet(tab: .shortcuts, isPresented: $restoring)
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
            // The row's name is the button's: "Add Lens, ⌃⌥L", not five buttons that all say "Record Shortcut".
            .accessibilityLabel(action.title)
            .accessibilityValue(monitor != nil ? String(localized: "Type a shortcut…") : combo?.display ?? String(localized: "Record Shortcut"))
            Button { model.settings.shortcuts[action.rawValue] = nil } label: { Image(systemName: "xmark.circle.fill").frame(width: 22, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.borderless).foregroundStyle(.tertiary)
                .help("Remove Shortcut")
                .accessibilityLabel(Text(verbatim: "\(String(localized: "Remove Shortcut")), \(action.title)"))
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
    #if !MAS
    private let updates = Updates.shared
    #endif

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 10) {
            AppGlyph(size: 80)
            Text("Mwoyeo").font(.largeTitle.weight(.semibold))
            Text("Translates the screen in place, wherever you put a lens.")
                .foregroundStyle(.secondary)
            Text("Version \(Updates.version) (\(Updates.build))")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)

            #if !MAS
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
            #endif

            HStack(spacing: 18) {
                Link(destination: Updates.repository) { Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                #if !MAS
                Link(destination: Updates.releases) { Label("Release Notes", systemImage: "doc.text") }
                #endif
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
            Link(destination: Distribution.privacyPolicy) { Label("Privacy Policy", systemImage: "hand.raised") }
                .font(.callout)

            Divider().frame(width: 300).padding(.vertical, 6)
            // The icons share one column, so the lines start at the same place (ui-audit-1-1-5 7.1).
            VStack(alignment: .leading, spacing: 6) {
                privacyLine("By default, screen text is read, erased and translated on this Mac and never leaves it", "lock.shield")
                #if !MAS
                privacyLine("Update checks ask GitHub for the latest version and count installs without any identifier", "arrow.down.circle")
                #endif
                privacyLine("Vision · Translation · Apple Intelligence · Core ML", "apple.intelligence")
                privacyLine("Inpainting: MI-GAN (Picsart AI Research, MIT)", "paintbrush")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Text(verbatim: "© 2026 midagedev · MIT License").font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func privacyLine(_ text: LocalizedStringKey, _ symbol: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: symbol).frame(width: 18) }
    }

    #if !MAS
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
    #endif
}

enum EngineSheetTarget: Identifiable {
    case add
    case edit(EngineConfig)
    /// "Allow…" on an engine that needs the person's permission: the edit sheet, at the box.
    case allow(EngineConfig)
    /// "Change…" in a profile's Context: the edit sheet with its Context open.
    case context(EngineConfig)
    var id: String {
        switch self {
        case .add: "add"
        case let .edit(e), let .allow(e), let .context(e): e.id.uuidString
        }
    }
}

/// An added engine's radio label, laid out like the Apple choices: its name, then where it runs and its measured time.
private struct AddedEngineLabel<Actions: View>: View {
    @Environment(AppModel.self) private var model
    let engine: EngineConfig
    let allow: () -> Void
    @ViewBuilder let actions: Actions

    var body: some View {
        // The buttons share the title's line, where the radio sits (vision ui-fixes 4.3: centred on both lines they sat 6 pt off it).
        // An HStack above a Text gets the standard 8 pt, not the text-to-text spacing of the built-in rows; 1 pt keeps their 17 pt rhythm.
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(engine.name).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                if engine.needsPermission(model.settings.enginePermissions) { Button("Allow…", action: allow).buttonStyle(.borderless).foregroundStyle(.tint) }
                Menu { actions } label: { Image(nsImage: .moreActions) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(width: 22, height: 22).contentShape(Rectangle())   // ui-audit-1-1-5 X1
                    // The 22 pt hit area overhangs the title's line instead of growing it (vision ui-fixes pass 2).
                    .padding(.vertical, -3)
                    .help("More actions for \(engine.name)")
                    .accessibilityLabel("More actions for \(engine.name)")
            }
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var detail: String {
        let permissions = model.settings.enginePermissions
        let seconds = engine.needsPermission(permissions) ? nil : model.translator.measuredSeconds(for: engine.id)
        return engine.listSubtitle(permissions: permissions) + (seconds.map { String(format: " · ~%.1f s", $0) } ?? "")
    }
}

/// "First result 0.3 s · 62% reused", for the engine in use once it has run a few batches.
private struct SpeedLine: View {
    let summary: SpeedSummary

    var body: some View {
        Text("First result \(String(format: "%.1f", summary.seconds)) s · \(Int((summary.fromMemory * 100).rounded()))% reused")
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
