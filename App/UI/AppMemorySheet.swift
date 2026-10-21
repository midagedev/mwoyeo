import AppKit
import MwoyeoCore
import SwiftUI

/// The profile sheet (design names-and-context §6.3): what the translator is told for one profile, an app, a window or All apps. Entered from a
/// profile row in Settings › Translation, from "Memory for <App>…" and "New Profile…" in a lens's menu and from the menu bar; an app with no
/// profile opens it empty, and its first edit makes the profile. Edits go straight to settings.json through `AppModel`, as every other setting
/// does; the file reloads live.
///
/// Order, top to bottom: the names and terms (the reason people come), the note, the learned rows (only when there are some), the "Sent:" line
/// (only with an added engine in effect), and **Customize**, one collapsed row whose summary says what differs from All apps. Open, it shows
/// When it’s used, Languages, Context, Rewrites and Script, in that order (L2, design §6.1). The bottom bar is "Done", and "Start Fresh"
/// only while the profile keeps a conversation.
struct AppMemorySheet: View {
    @State private var editor: AppMemoryEditor
    @State private var customizeOpen: Bool
    private let scriptOpen: Bool
    private let runsTest: Bool
    private let scrollTarget: String?
    @State private var phraseSelection: TextSelection?
    private let height: CGFloat
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?

    private enum Field: Hashable { case note, name, phrase(Int), pending }

    /// - `openDetails`, `askingToStartFresh`, `height`, `customize`: for the capture harness: rows (by position) whose details start open, the
    ///   sheet as it is after Start Fresh was pressed, a taller sheet that shows every section without scrolling, and Customize open or shut
    ///   whatever the profile uses (nil: as the profile asks, design §6.3). `scriptOpen` opens the Script editor and `runsTest` runs its Test once, for the same.
    init(target: MemoryTarget, model: AppModel, openDetails: [Int] = [], askingToStartFresh: Bool = false, height: CGFloat = 640, customize: Bool? = nil,
         scriptOpen: Bool = false, runsTest: Bool = false, scrollTo: String? = nil) {
        self.height = height
        self.scriptOpen = scriptOpen
        self.runsTest = runsTest
        self.scrollTarget = scrollTo
        let e = AppMemoryEditor(target: target, model: model)
        for i in openDetails where e.rows.indices.contains(i) { e.expanded.insert(e.rows[i].id) }
        e.confirmingFresh = askingToStartFresh
        _editor = State(initialValue: e)
        _customizeOpen = State(initialValue: customize ?? e.customizeStartsOpen)
    }

    /// An app's sheet (a bundle ID, and the name the lens gave it when it has no profile yet).
    init(bundleID: String, model: AppModel, appName: String? = nil, openDetails: [Int] = [], askingToStartFresh: Bool = false, height: CGFloat = 640,
         customize: Bool? = nil, scriptOpen: Bool = false) {
        self.init(target: MemoryTarget(id: bundleID, name: appName), model: model, openDetails: openDetails, askingToStartFresh: askingToStartFresh,
                  height: height, customize: customize, scriptOpen: scriptOpen)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                Form {
                    namesSection
                    if !editor.isAllApps { noteSection }
                    if !editor.learned.isEmpty { learnedSection }
                    if let sent = editor.sent { sentSection(sent) }
                    customizeRow.id("customize")
                    if customizeOpen { customizeBody }
                }
                .formStyle(.grouped)
                .onChange(of: customizeOpen) { _, open in
                    if open { withAnimation(Motion.shared.animation(.snappy)) { proxy.scrollTo("customize", anchor: .top) } }
                }
                .task {
                    // The capture harness: the sheet scrolled to a section, as a person who scrolls down to it sees it.
                    guard let id = scrollTarget else { return }
                    try? await Task.sleep(for: .milliseconds(1500))
                    proxy.scrollTo(id, anchor: id == "rewrites" ? UnitPoint(x: 0.5, y: 0.12) : .top)
                }
                .task {
                    // A profile being made by hand opens on Customize with the name, or the window's phrase, ready to be typed over.
                    guard customizeOpen, editor.target.kind == .new else { return }
                    try? await Task.sleep(for: .milliseconds(350))
                    proxy.scrollTo("customize", anchor: .top)
                    if editor.target.focusesPhrase, let i = editor.profile?.when.firstIndex(where: { !($0.titleContains ?? "").isEmpty }) {
                        focus = .phrase(i)
                        let text = editor.profile?.when[i].titleContains ?? ""
                        phraseSelection = TextSelection(range: text.startIndex..<text.endIndex)
                    } else {
                        focus = .name
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 520, height: height)
        .task(id: editor.profile) { editor.reconcile() }
        .task {
            await editor.check()
            if runsTest { await editor.runTest() }   // the capture harness: the Script's Test as it looks once run
        }
        .task(id: editor.learnedCounts) { await editor.refreshLearned() }
        .onChange(of: editor.gone) { _, gone in if gone { dismiss() } }
        .onDisappear { editor.closing() }
    }

    // MARK: header and buttons

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Memory for \(editor.title)").font(.headline).lineLimit(1).truncationMode(.tail)
            Text(editor.captionLine).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 30).padding(.top, 16).padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var footer: some View {
        if editor.confirmingFresh {
            VStack(alignment: .leading, spacing: 8) {
                Text("Start fresh?").font(.headline)
                Text("The conversation kept for this profile is forgotten. Your note, names and learned terms stay.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { withAnimation(Motion.shared.animation(.easeOut(duration: 0.15))) { editor.confirmingFresh = false } }
                        .keyboardShortcut(.cancelAction)
                    // Plain, not destructive: the person chose it (ui-audit-1-1-5 10.6).
                    Button("Start Fresh") { Task { await editor.startFresh() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        } else {
            HStack {
                if editor.keepsConversation {
                    Button("Start Fresh") { withAnimation(Motion.shared.animation(.easeOut(duration: 0.15))) { editor.confirmingFresh = true } }
                        .help("Forget the conversation kept for this profile. Learned names stay.")
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }

    // MARK: names and terms

    private var namesSection: some View {
        Section {
            if editor.isAllApps {
                LabeledContent("Glossary") {
                    HStack(spacing: 8) {
                        Text("\(editor.glossaryCount) pairs").foregroundStyle(.secondary).monospacedDigit()
                        // The glossary is a section of this tab: the sheet closes first (no sheet over a sheet, design §6.1).
                        Button("Edit Glossary…") { dismiss() }.buttonStyle(.borderless).foregroundStyle(.tint)
                    }
                }
            } else {
                if editor.rows.isEmpty {
                    Text("Type a name as the screen shows it, then how it should read.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(editor.rows) { row in
                    NameRow(editor: editor, id: row.id)
                }
                swapCallout
                Button {
                    withAnimation(Motion.shared.animation(.easeOut(duration: 0.15))) {
                        if let id = editor.addRow() { editor.expanded.remove(id) }
                    }
                } label: {
                    Label("Add Name", systemImage: "plus")
                }
                .disabled(!editor.canAddRow)
                HStack {
                    if !editor.canAddRow {
                        Text("That is the most. Remove a name to add another.").font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    Text("Names: \(editor.rows.count) of \(AppMemoryEditor.maxRows)")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(editor.canAddRow ? Color.secondary : Color.orange)
                }
            }
        } header: {
            Text("Names and terms")
        }
    }

    /// Rows on Tell while the engine in effect takes no hints: one callout with the one button that fixes them (design §6.3).
    @ViewBuilder private var swapCallout: some View {
        let n = editor.swappableHintRows.count
        if n > 0 {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(editor.engineName) uses only names swapped into the text; \(n) here are not.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Swap Them In") { withAnimation(Motion.shared.animation(.easeOut(duration: 0.15))) { editor.swapThemIn() } }
                    .buttonStyle(.borderless).foregroundStyle(.tint)
            }
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: note

    private var noteSection: some View {
        Section {
            TextEditor(text: Binding(get: { editor.note }, set: { editor.setNote($0) }))
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($focus, equals: .note)
                .frame(minHeight: 52, maxHeight: 72)
                .overlay(alignment: .topLeading) {
                    if editor.note.isEmpty {
                        Text("Who is talking, the setting, the tone…")
                            .foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Note for the translator")
            HStack {
                Text("Told to the translator with every line from this profile.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Counter(count: editor.note.count, limit: AppMemoryEditor.maxNote)
            }
        } header: {
            Text("Note")
        }
    }

    // MARK: learned rows

    private var learnedSection: some View {
        Section {
            ForEach(editor.learned, id: \.entry.id) { record in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(record.entry.src) → \(record.entry.dst)").lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                        if !record.isUsable {
                            Text("Seen once. Used after a second sighting.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    // The accent says they are buttons; it is set on them alone, because a style set on the row would also tint the dimmed text.
                    Button("Pin") { Task { await editor.pin(record) } }
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Text("Pin \(record.entry.src)"))
                    Button("Remove") { Task { await editor.removeLearned(record) } }
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Text("Remove \(record.entry.src)"))
                }
                .buttonStyle(.borderless)
                .accessibilityElement(children: .contain)
            }
            if let notice = editor.learnedNotice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Learned")
        } footer: {
            HStack {
                Text("Names and terms the engine suggested. Pin keeps one as your own.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Forget All") { Task { await editor.forgetLearned() } }
                    .buttonStyle(.borderless).foregroundStyle(.tint).font(.caption)
                    .help("Forget the names and terms learned for this profile.")
            }
        }
    }

    // MARK: what is sent

    /// What the engine in effect is sent for this profile, by the request path's own rule; never cut, it wraps.
    private func sentSection(_ sent: SentSummary) -> some View {
        Section {
            Text(EngineContextSent.said(sent, in: .current))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityElement(children: .combine)
        }
    }

    // MARK: Customize (L2)

    /// The disclosure row: a triangle, "Customize" and, in secondary, what differs from All apps. One accessibility element; the summary is its value.
    private var customizeRow: some View {
        Section {
            Button {
                withAnimation(Motion.shared.animation(.snappy)) { customizeOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(customizeOpen ? 90 : 0)).frame(width: 12)
                    Text("Customize")
                    Spacer(minLength: 12)
                    Text(editor.customizeSummary).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // No `.accessibilityElement(children: .ignore)` on a Button: it swaps the button's element for one with no AXPress (D11). The label, value and hint
            // replace what the button says; `PressChecks` presses it.
            .accessibilityLabel("Customize")
            .accessibilityValue(editor.customizeSummary)
            .accessibilityHint(customizeOpen ? String(localized: "Collapses the options") : String(localized: "Shows the options"))
        }
    }

    @ViewBuilder private var customizeBody: some View {
        if !editor.isAllApps {
            whenSection
            languagesSection
        }
        contextSection
        // (d) Rewrites, (e) Script (design rewrite-rules §7): after Context, drawn only with Customize open.
        RewriteTable(editor: editor).id("rewrites")
        ScriptEditor(editor: editor, open: scriptOpen).id("script")
    }

    // (a) When it’s used

    private var whenSection: some View {
        Section {
            LabeledContent("Name") {
                TextField("Name", text: Binding(get: { editor.profile?.name ?? "" }, set: { editor.setName($0) }))
                    .labelsHidden().multilineTextAlignment(.trailing)
                    .focused($focus, equals: .name)
            }
            let conditions = editor.profile?.when ?? []
            ForEach(Array(conditions.enumerated()), id: \.offset) { i, c in conditionRow(i, c) }
            if let pending = editor.pendingPhrase {
                HStack(spacing: 8) {
                    Image(systemName: "textformat").frame(width: 14).foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Title contains", text: Binding(get: { pending }, set: { editor.pendingPhrase = $0 }))
                        .labelsHidden()
                        .focused($focus, equals: .pending)
                        .onSubmit { editor.commitPending() }
                        .onChange(of: focus) { _, now in if now != .pending { editor.commitPending() } }
                    Spacer(minLength: 0)
                }
                Text("Keep the part that stays the same, like a game’s name.").font(.caption).foregroundStyle(.secondary)
            }
            if conditions.isEmpty, editor.pendingPhrase == nil {
                Text("No conditions: used only when you pick it.").font(.callout).foregroundStyle(.secondary)
            }
            if editor.canAddCondition { addConditionMenu }
        } header: {
            Text("When it’s used")
        }
    }

    private func conditionRow(_ i: Int, _ c: ProfileCondition) -> some View {
        let profiles = editor.allProfiles
        let app = c.app.flatMap { $0.isEmpty ? nil : $0 }
        return HStack(spacing: 8) {
            Group {
                if let app, let icon = Self.icon(ofApp: app) {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                } else {
                    Image(systemName: c.titleContains != nil ? "textformat" : "app").frame(width: 14).foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)
            if let phrase = c.titleContains {
                TextField("Title contains", text: Binding(get: { phrase }, set: { editor.setPhrase($0, at: i) }),
                          selection: focus == .phrase(i) ? $phraseSelection : .constant(nil))
                    .labelsHidden()
                    .focused($focus, equals: .phrase(i))
                if let app { Text("in \(ProfileWords.appName(app, in: profiles))").foregroundStyle(.secondary).lineLimit(1) }
            } else if let app {
                Text(ProfileWords.appName(app, in: profiles)).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { editor.removeCondition(at: i) } label: { Image(systemName: "minus.circle").frame(width: 22, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Remove this condition")
                .accessibilityLabel("Remove this condition")
        }
    }

    private var addConditionMenu: some View {
        Menu {
            if let bundle = editor.target.lensBundleID {
                Button(editor.target.lensAppName ?? bundle) { editor.addCondition(ProfileCondition(app: bundle)) }
                    .disabled(editor.profile?.when.contains(ProfileCondition(app: bundle)) == true)
            }
            let title = editor.target.lensTitle ?? ""
            Button("This Window’s Title") {
                editor.addCondition(ProfileCondition(app: editor.target.lensBundleID,
                                                     titleContains: String(title.prefix(ProfileCondition.maxTitleLength))))
            }
            .disabled(title.isEmpty)
            Button("Other App…") { chooseApp() }
            Button("Title Contains…") {
                editor.pendingPhrase = ""
                Task { try? await Task.sleep(for: .milliseconds(100)); focus = .pending }
            }
        } label: {
            // ui-audit-1-1-5 X1: a hit area of at least 20 pt. A borderless menu is 16 pt tall whatever its label; the language bar's style takes the
            // label's own height, so the padding is the control's.
            Label("Add Condition", systemImage: "plus").padding(.vertical, 4).contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(.tint)
        .fixedSize()
    }

    /// "Other App…": an app of this Mac, by its bundle ID.
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        editor.addCondition(ProfileCondition(app: id))
    }

    private static func icon(ofApp bundleID: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    // (b) Languages

    private var languagesSection: some View {
        Section {
            Picker("From", selection: Binding(get: { editor.profile?.source ?? "auto" }, set: { editor.setSource($0) })) {
                ForEach(Languages.sources, id: \.self) { Text(Languages.name($0)).tag($0) }
            }
            Picker("To", selection: Binding(get: { editor.profile?.target ?? "en" }, set: { editor.setTarget($0) })) {
                ForEach(Languages.targets, id: \.self) { Text(Languages.name($0)).tag($0) }
            }
            // The file's own value ("" follows All apps, "apple", an engine's id): `ProfileEngine` is Core's and not Hashable. With no added engine there is
            // only Apple to choose, so the row is not drawn (a Settings row that cannot act is not drawn, design §6.1).
            if !editor.engines.isEmpty {
                Picker("Engine", selection: Binding(get: { editor.profile?.engine?.fileValue ?? "" },
                                                    set: { editor.setEngine(ProfileEngine.named($0)) })) {
                    Text("Same as All apps (\(editor.allAppsEngineName))").tag("")
                    Text("Apple Translation").tag(ProfileEngine.apple.fileValue)
                    ForEach(editor.engines) { engine in Text(engine.name).tag(ProfileEngine.added(engine.id).fileValue) }
                }
            }
            Picker("Paragraphs", selection: Binding(get: { editor.profile?.paragraphReader }, set: { editor.setReader($0) })) {
                Text("Automatic").tag(ParagraphReader?.none)
                ForEach(ParagraphReader.allCases.filter { $0 != .automatic }, id: \.self) { Text($0.title).tag(ParagraphReader?.some($0)) }
            }
        } header: {
            Text("Languages")
        }
    }

    // (c) Context

    private var contextSection: some View {
        Section {
            if editor.takesContext {
                Picker("Context", selection: Binding(get: { editor.contextChoice }, set: { editor.setContext($0) })) {
                    if !editor.isAllApps { Text("Same as All apps (\(editor.allAppsWords))").tag(AppMemoryEditor.ContextChoice.follow) }
                    Text("Only the line").tag(AppMemoryEditor.ContextChoice.off)
                    Text("Names and note").tag(AppMemoryEditor.ContextChoice.memory)
                    Text("Nearby lines").tag(AppMemoryEditor.ContextChoice.nearby)
                    Text("Conversation").tag(AppMemoryEditor.ContextChoice.conversation)
                }
                if editor.contextChoice == .conversation {
                    Stepper(value: Binding(get: { editor.earlierLines }, set: { editor.setEarlierLines($0) }), in: 0...AppContextOverride.maxPreviousLines) {
                        Text("Earlier lines: \(editor.earlierLines)").monospacedDigit()
                    }
                }
                if editor.learns {
                    Toggle("Learn names and terms", isOn: Binding(get: { editor.learnsNames }, set: { editor.setLearnsNames($0) }))
                }
                if editor.linesAskedButDenied, let engine = editor.engineInEffect {
                    HStack {
                        Text("\(engine.name) gets only the line.").font(.caption).foregroundStyle(.orange)
                        Spacer(minLength: 8)
                        Button("Change…") { ProfileRoutes.shared.editEngineContext(engine.id); dismiss() }
                            .buttonStyle(.borderless).foregroundStyle(.tint)
                    }
                }
            } else {
                Text("\(editor.engineName) gets only the line.").font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Context")
        }
    }
}

/// "123 / 500", orange at the cap.
private struct Counter: View {
    let count: Int
    let limit: Int

    var body: some View {
        Text("\(count) / \(limit)")
            .font(.caption).monospacedDigit()
            .foregroundStyle(count >= limit ? Color.orange : Color.secondary)
            .accessibilityLabel(Text("\(count) of \(limit) characters"))
    }
}

/// One name or term: the name and its translation on the row; the rest behind the disclosure (the Use pop-up first, design §10).
private struct NameRow: View {
    let editor: AppMemoryEditor
    let id: UUID

    private var row: AppMemoryEditor.Row { editor.row(id) ?? AppMemoryEditor.Row(id: id) }

    private func text(_ keyPath: WritableKeyPath<AppMemoryEditor.Row, String>) -> Binding<String> {
        Binding(get: { editor.row(id)?[keyPath: keyPath] ?? "" }, set: { v in editor.edit(id) { $0[keyPath: keyPath] = v } })
    }

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { editor.expanded.contains(id) },
                                            set: { if $0 { editor.expanded.insert(id) } else { editor.expanded.remove(id) } })) {
            details
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    TextField("Name", text: text(\.src), prompt: Text("Name or term"))
                        .labelsHidden()
                        .accessibilityLabel("Name or term in the text")
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                    TextField("Translation", text: text(\.dst), prompt: Text("Translation"))
                        .labelsHidden()
                        .accessibilityLabel("Its translation")
                    Button { withAnimation(Motion.shared.animation(.easeOut(duration: 0.15))) { editor.removeRow(id) } } label: {
                        Image(systemName: "minus.circle").frame(width: 22, height: 22).contentShape(Rectangle())   // ui-audit-1-1-5 X1
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove this name")
                    .accessibilityLabel(Text("Remove \(row.src.isEmpty ? String(localized: "this name") : row.src)"))
                }
                if let problem = row.problem, problem != .incomplete || !row.isBlank {
                    Text(Self.words(problem)).font(.caption).foregroundStyle(problem == .incomplete ? Color.secondary : Color.orange)
                }
            }
        }
    }

    private static func words(_ p: AppMemoryEditor.Problem) -> LocalizedStringKey {
        switch p {
        case .incomplete: "Fill in the name and its translation to store it."
        case .duplicate: "Another row already has this name."
        case .full: "That is the most names this profile keeps."
        }
    }

    private func caption(_ apply: EntryApply) -> LocalizedStringKey {
        switch apply {
        case .hint: "Told to AI engines where it appears."
        case .replace: "Written into the text before translating; Apple Translation uses it too."
        case .both: "Both of these."
        }
    }

    private func item(_ apply: EntryApply) -> String {
        let cost = editor.cost(of: apply, row: row)
        let recommended = apply == .both && editor.recommendsBoth && [EntryKind.person, .place, .org].contains(row.kind)
        return recommended ? cost + " · " + String(localized: "recommended for names") : cost
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Use", selection: Binding(get: { row.apply }, set: { v in editor.edit(id) { $0.apply = v } })) {
                ForEach(EntryApply.allCases, id: \.self) { Text(item($0)).tag($0) }
            }
            Text(caption(row.apply)).font(.caption).foregroundStyle(.secondary)
        }
        Picker("Kind", selection: Binding(get: { row.kind }, set: { v in editor.edit(id) { $0.kind = v } })) {
            Text("Person").tag(EntryKind.person)
            Text("Place").tag(EntryKind.place)
            Text("Term").tag(EntryKind.term)
            Text("Organization").tag(EntryKind.org)
        }
        Picker("Gender", selection: Binding(get: { row.gender }, set: { v in editor.edit(id) { $0.gender = v } })) {
            Text("Not set").tag(Gender?.none)
            Text("Female").tag(Gender?.some(.f))
            Text("Male").tag(Gender?.some(.m))
            Text("Neutral").tag(Gender?.some(.n))
        }
        LabeledContent("Note") {
            HStack {
                TextField("Note", text: text(\.note), prompt: Text("Age, role, how they speak"))
                    .labelsHidden().multilineTextAlignment(.trailing)
                Counter(count: row.note.count, limit: AppMemoryEditor.maxEntryNote)
            }
        }
        LabeledContent("Pronunciation") {
            TextField("Pronunciation", text: text(\.reading), prompt: Text("How it is read, for Japanese"))
                .labelsHidden().multilineTextAlignment(.trailing)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("Speaks to")
            ForEach(row.addressing) { a in
                HStack {
                    TextField("Person", text: Binding(get: { editor.row(id)?.addressing.first { $0.id == a.id }?.to ?? "" },
                                                      set: { v in editor.edit(id) { r in if let i = r.addressing.firstIndex(where: { $0.id == a.id }) { r.addressing[i].to = v } } }),
                              prompt: Text("Who"))
                        .labelsHidden().accessibilityLabel("Who this person speaks to")
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                    Picker("Register", selection: Binding(get: { editor.row(id)?.addressing.first { $0.id == a.id }?.register ?? .polite },
                                                           set: { v in editor.edit(id) { r in if let i = r.addressing.firstIndex(where: { $0.id == a.id }) { r.addressing[i].register = v } } })) {
                        Text("Casual").tag(Register.casual)
                        Text("Polite").tag(Register.polite)
                        Text("Formal").tag(Register.formal)
                        Text("Honorific").tag(Register.honorific)
                    }
                    .labelsHidden().fixedSize()
                    Button { editor.edit(id) { r in r.addressing.removeAll { $0.id == a.id } } } label: {
                        Image(systemName: "minus.circle").frame(width: 22, height: 22).contentShape(Rectangle())   // ui-audit-1-1-5 X1
                    }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .accessibilityLabel("Remove this person")
                }
            }
            if row.addressing.count < AppMemoryEditor.maxAddressing {
                Button { editor.edit(id) { $0.addressing.append(AppMemoryEditor.AddressDraft()) } } label: { Label("Add Person", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)   // the label starts where "Kind" does (ui-all A4)
    }
}

/// What the rest of Settings asks of the profile sheet that cannot be said by closing it: "Change…" on a denied context opens the engine's sheet
/// at its Context (design §6.3 c, §6.5), and the sheet is closed first (no sheet over a sheet).
@MainActor @Observable
final class ProfileRoutes {
    static let shared = ProfileRoutes()
    /// The engine whose sheet Settings › Translation opens next, with its Context open.
    var engineToEdit: UUID?

    func editEngineContext(_ id: UUID) { engineToEdit = id }
}

extension AppModel {
    /// Settings on Translation with `target`'s sheet up (a lens's menu, the menu bar's profile menu and Settings' own rows come here). Without a
    /// way to open Settings (`openSettingsAction`) nothing is left waiting for the next time it opens.
    func openProfile(_ target: MemoryTarget) {
        memoryTarget = target
        if !openSettings(on: .translation) { memoryTarget = nil }
    }
}
