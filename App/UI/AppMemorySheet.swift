import AppKit
import MwoyeoCore
import SwiftUI

/// The Memory sheet of one app's profile (design §3): what the translator is told about the app. Entered from the profile row's ⋯ menu
/// and nowhere else. Edits go straight to settings.json through `AppModel`, as every other setting does; the file reloads live.
///
/// Order, top to bottom: the note, the names and terms (src and dst on the row, the rest behind the row's disclosure), the app's
/// context choice with its one-line promise, the "Sent:" line, the learned rows (only when there are some), and the buttons.
struct AppMemorySheet: View {
    @State private var editor: AppMemoryEditor
    private let height: CGFloat
    @Environment(\.dismiss) private var dismiss
    @FocusState private var noteFocused: Bool

    /// - `openDetails`, `askingToStartFresh`, `height`: for the capture harness: rows (by position) whose details start open, the sheet as
    ///   it is after Start Fresh was pressed, and a taller sheet that shows every section without scrolling.
    init(bundleID: String, model: AppModel, openDetails: [Int] = [], askingToStartFresh: Bool = false, height: CGFloat = 640) {
        self.height = height
        let e = AppMemoryEditor(bundleID: bundleID, model: model)
        for i in openDetails where e.rows.indices.contains(i) { e.expanded.insert(e.rows[i].id) }
        e.confirmingFresh = askingToStartFresh
        _editor = State(initialValue: e)
    }

    private var appName: String { editor.profile?.appName ?? editor.bundleID }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                noteSection
                namesSection
                contextSection
                if !editor.learned.isEmpty { learnedSection }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 520, height: height)
        .task(id: editor.profile) { editor.reconcile() }
        .task(id: editor.learnedCounts) { await editor.refreshLearned() }
        .onChange(of: editor.gone) { _, gone in if gone { dismiss() } }
        .onDisappear { editor.closing() }
    }

    // MARK: header and buttons

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Memory for \(appName)").font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
    }

    @ViewBuilder private var footer: some View {
        if editor.confirmingFresh {
            VStack(alignment: .leading, spacing: 8) {
                Text("Start fresh?").font(.headline)
                Text("The conversation kept for this app is forgotten. Your note, names and learned terms stay.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { withAnimation(Motion.shared.animation(.easeOut(duration: 0.15))) { editor.confirmingFresh = false } }
                        .keyboardShortcut(.cancelAction)
                    // A plain button in a sheet does not colour its destructive role; red text as an alert's destructive button has.
                    Button("Start Fresh", role: .destructive) { Task { await editor.startFresh() } }
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        } else {
            HStack {
                Button("Forget Learned") { Task { await editor.forgetLearned() } }
                    .disabled(editor.learned.isEmpty)
                    .help(editor.learned.isEmpty ? String(localized: "Nothing has been learned for this app yet.")
                          : String(localized: "Forget the names and terms learned for this app."))
                Button("Start Fresh") { withAnimation(Motion.shared.animation(.easeOut(duration: 0.15))) { editor.confirmingFresh = true } }
                    .help("Forget the conversation kept for this app. Learned names stay.")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }

    // MARK: note

    private var noteSection: some View {
        Section {
            TextEditor(text: Binding(get: { editor.note }, set: { editor.setNote($0) }))
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($noteFocused)
                .frame(minHeight: 52, maxHeight: 72)
                .overlay(alignment: .topLeading) {
                    if editor.note.isEmpty {
                        Text("Who is talking, the setting, the tone…")
                            .foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Note for the translator")
            HStack {
                Text("Told to the translator with every line from this app.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Counter(count: editor.note.count, limit: AppMemoryEditor.maxNote)
            }
        } header: {
            Text("Note")
        }
    }

    // MARK: names and terms

    private var namesSection: some View {
        Section {
            ForEach(editor.rows) { row in
                NameRow(editor: editor, id: row.id)
            }
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
        } header: {
            Text("Names and terms")
        }
    }

    // MARK: context

    private var contextSection: some View {
        Section {
            Picker("Context for this app", selection: Binding(get: { editor.contextChoice }, set: { editor.setContext($0) })) {
                Text("Follow the engine").tag(AppMemoryEditor.ContextChoice.follow)
                Text("Off").tag(AppMemoryEditor.ContextChoice.off)
                Text("Nearby").tag(AppMemoryEditor.ContextChoice.nearby)
                Text("Conversation").tag(AppMemoryEditor.ContextChoice.conversation)
            }
            if editor.contextChoice == .conversation {
                Stepper(value: Binding(get: { editor.earlierLines }, set: { editor.setEarlierLines($0) }),
                        in: 0...AppContextOverride.maxPreviousLines) {
                    Text("Earlier lines: \(editor.earlierLines)").monospacedDigit()
                }
            }
            Text("Applies only to engines you added. Apple Translation is not affected.")
                .font(.caption).foregroundStyle(.secondary)
            // What the engine in effect is sent, by the request path's own rule; never cut, it wraps.
            VStack(alignment: .leading, spacing: 4) {
                Text(AppMemorySent.line(editor.sent))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !editor.otherReceivers.isEmpty {
                    Text("Also sent to \(ListFormatter.localizedString(byJoining: editor.otherReceivers.map(\.name))) when another app is in front.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
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
                            Text("Seen once. Used after a second sighting.").font(.caption).foregroundStyle(.tertiary)
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
            Text("Names and terms the engine suggested. Pin keeps one as your own.").font(.caption).foregroundStyle(.secondary)
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

/// One name or term: the name and its translation on the row; the rest behind the disclosure.
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
                        Image(systemName: "minus.circle")
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
        case .full: "That is the most names this app keeps."
        }
    }

    @ViewBuilder private var details: some View {
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
                    Picker("Register", selection: Binding(get: { editor.row(id)?.addressing.first { $0.id == a.id }?.register ?? .polite },
                                                           set: { v in editor.edit(id) { r in if let i = r.addressing.firstIndex(where: { $0.id == a.id }) { r.addressing[i].register = v } } })) {
                        Text("Casual").tag(Register.casual)
                        Text("Polite").tag(Register.polite)
                        Text("Formal").tag(Register.formal)
                        Text("Honorific").tag(Register.honorific)
                    }
                    .labelsHidden().fixedSize()
                    Button { editor.edit(id) { r in r.addressing.removeAll { $0.id == a.id } } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .accessibilityLabel("Remove this person")
                }
            }
            if row.addressing.count < AppMemoryEditor.maxAddressing {
                Button { editor.edit(id) { $0.addressing.append(AppMemoryEditor.AddressDraft()) } } label: { Label("Add Person", systemImage: "plus") }
                    .buttonStyle(.borderless)
            }
        }
    }
}

/// The words of the "Sent:" line in the app's language, built from the fields of `SentSummary` the way the engine sheet builds its own
/// (the same keys, so the two read alike).
enum AppMemorySent {
    static func line(_ s: SentSummary) -> String {
        var parts: [String] = []
        if let app = s.appName { parts.append(s.domain.map { "\(app) · \($0)" } ?? app) }
        if s.windowTitle { parts.append(String(localized: "window title")) }
        if s.hasNote { parts.append(String(localized: "note")) }
        if s.names > 0 { parts.append(s.learned ? String(localized: "up to \(s.names) names (learned too)") : String(localized: "up to \(s.names) names")) }
        if s.linesBefore > 0 { parts.append(String(localized: "\(s.linesBefore) lines before")) }
        if s.linesAfter > 0 { parts.append(String(localized: "\(s.linesAfter) lines after")) }
        return String(localized: "Sent: \(parts.isEmpty ? String(localized: "lines only") : parts.joined(separator: " · "))")
    }
}

/// The app whose Memory sheet is open (`TranslationSettings`' `.sheet(item:)`).
struct MemoryTarget: Identifiable {
    let id: String
}

/// What the app profiles list says about an app's memory, and when it offers the one switch that belongs to all of them.
enum AppMemorySummary {
    /// " · 3 names" of the row: the note and the names, nil while the app has neither. The first part of the row to be cut short.
    static func short(_ p: AppProfile) -> String? {
        var parts: [String] = []
        if !p.note.isEmpty { parts.append(String(localized: "note")) }
        if !p.entries.isEmpty { parts.append(String(localized: "\(p.entries.count) names")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The tooltip: the note and the names in full (the first dozen).
    static func full(_ p: AppProfile) -> String? {
        guard p.hasMemory else { return nil }
        var lines: [String] = []
        if !p.note.isEmpty { lines.append(p.note) }
        lines += p.entries.prefix(12).map { "\($0.src) → \($0.dst)" }
        if p.entries.count > 12 { lines.append("…") }
        return lines.joined(separator: "\n")
    }

    /// "Use my names and terms with Apple Translation" is one global key: it is offered under the profiles and only while there is one.
    static func showsAppleToggle(_ s: AppSettings) -> Bool { !s.appProfiles.isEmpty }

    /// The switch's binding: it writes `appleUsesPinnedTerms` through the settings path, so into settings.json.
    @MainActor static func appleToggle(_ model: AppModel) -> Binding<Bool> {
        Binding(get: { model.settings.appleUsesPinnedTerms }, set: { model.settings.appleUsesPinnedTerms = $0 })
    }
}
