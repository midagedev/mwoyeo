import MwoyeoCore
import SwiftUI

/// The side that runs and checks regex rows and scripts (rewrite-rules §5): the app's `ScriptConnection`, or a fake in a gate. The sheet's Test and its
/// error lines only ever go through this.
protocol RewriteService: RewriteRunner {
    func check(rows: [RewriteRow], script: RewriteScript?) async -> RewriteCheckResult
}

extension ScriptConnection: RewriteService {}

/// What the Script's Test made of the sample (rewrite-rules §7): the line as `before` leaves it, the line as `after` shows it, and what went wrong.
struct ScriptTestResult: Equatable {
    var before: String
    var after: String
    var issue: String?
}

/// The rules table and the script of one profile, edited in the profile sheet's Customize (design rewrite-rules §7; names-and-context §6.3 d, e). The
/// model is Core's (`RewriteRow`, `RewriteScript`, the limits of `RewriteLimits`); this adds the editing: drafts, the caps at the field, the checks
/// (the pure ones always, the service's only when a pattern or a script is there, so a profile with none never starts it) and the Test.
extension AppMemoryEditor {
    /// The rows stored for the profile (All apps' are the settings' own).
    var rewrites: [RewriteRow] { isAllApps ? model.settings.rewrites : (profile?.rewrites ?? []) }
    var script: RewriteScript? { isAllApps ? model.settings.script : profile?.script }

    /// The rows on screen: the stored ones, then the one being made.
    var rewriteRows: [RewriteRow] { rewrites + (pendingRewrite.map { [$0] } ?? []) }
    var canAddRewrite: Bool { rewrites.count + (pendingRewrite == nil ? 0 : 1) < RewriteLimits.maxRows }
    /// A table with a row that changes the translation says that a particle can come out wrong (rewrite-rules §7).
    var rewritesTouchTranslation: Bool { rewriteRows.contains { $0.stage == .after } }

    private func setRewrites(_ rows: [RewriteRow]) {
        if isAllApps {
            model.settings.rewrites = rows
        } else {
            write { $0.rewrites = rows; return .saved }
        }
        scheduleCheck()
    }

    /// "Add Rewrite": a new row, last, on the original (before); nothing is stored until it has something to find.
    func addRewrite() {
        guard canAddRewrite, pendingRewrite == nil else { return }
        pendingRewrite = RewriteRow(.before, "")
    }

    /// Changes row `i` as the person typed, cuts the fields to their caps, and stores a draft once its Find holds a character. A stored row whose Find is
    /// emptied goes back to being the draft (an empty Find is not a row of the file).
    func updateRewrite(at i: Int, _ change: (inout RewriteRow) -> Void) {
        var rows = rewrites
        if i == rows.count, var draft = pendingRewrite {
            change(&draft)
            draft = Self.cut(draft)
            if draft.find.isEmpty {
                pendingRewrite = draft
            } else {
                pendingRewrite = nil
                setRewrites(rows + [draft])
            }
            return
        }
        guard rows.indices.contains(i) else { return }
        var row = rows[i]
        change(&row)
        row = Self.cut(row)
        if row.find.isEmpty {
            rows.remove(at: i)
            pendingRewrite = pendingRewrite ?? row
        } else {
            rows[i] = row
        }
        setRewrites(rows)
    }

    func removeRewrite(at i: Int) {
        var rows = rewrites
        if i == rows.count {
            pendingRewrite = nil
        } else if rows.indices.contains(i) {
            rows.remove(at: i)
            setRewrites(rows)
        }
    }

    /// The caps of §2 at the field: Find and Replace with hold at most 200 characters.
    private static func cut(_ row: RewriteRow) -> RewriteRow {
        var r = row
        r.find = String(r.find.prefix(RewriteLimits.findLength.upperBound))
        r.replace = String(r.replace.prefix(RewriteLimits.maxReplace))
        return r
    }

    // MARK: the script

    enum ScriptState: Equatable { case off, on, error }

    /// "Script · Off", "On", "Error": a script that is not running, one that is, or one the checks or the Test found a fault in.
    var scriptState: ScriptState {
        guard let s = script, !s.source.isEmpty else { return .off }
        if rewriteIssues.contains(where: { $0.item == RewriteIssue.script }) { return .error }
        return s.on ? .on : .off
    }

    /// The script's text as typed (cut at 8,000). A script nobody has been told to run is written with `on: false`, so a first draft changes nothing.
    func setScriptSource(_ text: String) {
        let source = String(text.prefix(RewriteLimits.maxScript))
        let next = source.isEmpty ? nil : RewriteScript(source: source, on: script?.on ?? false)
        setScript(next)
        testResult = nil
        scheduleCheck()
    }

    func setScriptOn(_ on: Bool) {
        guard var s = script else { return }
        s.on = on
        setScript(s)
    }

    private func setScript(_ value: RewriteScript?) {
        if isAllApps {
            model.settings.script = value
        } else {
            write { $0.script = value; return .saved }
        }
    }

    // MARK: checks

    /// The checks, a moment after the last edit (the service is asked once typing stops).
    func scheduleCheck() {
        checking?.cancel()
        checking = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.check()
        }
    }

    /// What is wrong with the rows and the script: the pure checks (counts, lengths) always; a pattern that does not compile and a script that does not parse
    /// are the service's, asked only while a pattern or a script is there (rewrite-rules §5: with none in the chain the service never starts).
    func check() async {
        let rows = rewrites, script = script
        var issues = RewriteCheck.rows(rows) + (script.map(RewriteCheck.script) ?? [])
        let needsService = rows.contains { $0.regex && $0.isActive } || (script.map { !$0.source.isEmpty } ?? false)
        if needsService {
            let result = await service.check(rows: rows, script: script)
            for issue in result.issues where !issues.contains(issue) { issues.append(issue) }
        }
        guard rows == rewrites, script == self.script else { return }   // edited meanwhile: the next check answers
        rewriteIssues = issues
    }

    /// The line a row's problems read as, under it: a pattern that does not compile says so (JavaScriptCore gives it no position), the rest as they are.
    func issueLine(forRow i: Int) -> String? {
        guard let issue = rewriteIssues.first(where: { $0.item == i && $0.message != RewriteText.turnedOff }) else { return nil }
        let isPattern = rewriteRows.indices.contains(i) && rewriteRows[i].regex
        return isPattern ? String(localized: "Pattern error: \(issue.message)") : issue.message
    }

    /// The script's problem, under the editor: "Line 3: …" (JavaScriptCore gives a syntax error its line and no column).
    var scriptIssueLine: String? {
        guard let issue = rewriteIssues.first(where: { $0.item == RewriteIssue.script }) else { return nil }
        return issue.line.map { String(localized: "Line \($0): \(issue.message)") } ?? issue.message
    }

    // MARK: Test

    /// "Test": the sample goes through the script alone, `before` and then `after` (on the lens's last translation, else on the sample). Nothing is sent.
    /// A script the time limit cuts is turned off, as at run time (§5).
    func runTest() async {
        guard let s = script, !s.source.isEmpty, !sample.isEmpty else { return }
        let id = isAllApps ? AppProfile.allAppsID : (profile?.id ?? AppProfile.allAppsID)
        let context = RewriteContext(app: appBundleID ?? target.lensBundleID ?? "", profile: id, source: profile?.source ?? model.settings.sourceLanguage,
                                     target: profile?.target ?? model.settings.targetLanguage)
        let plan = RewritePlan(chain: [RewriteLayer(profile: id, script: RewriteScript(source: s.source, on: true))])
        var session = RewriteSession(plan: plan, context: context, runner: service)
        let sent = await session.before(sample)
        let shown = await session.after(src: sent, dst: target.lensTranslation ?? sample)
        var issue: String?
        if !session.turnedOff.isEmpty {
            setScriptOn(false)
            issue = ScriptWords.turnedOff
        } else if let found = session.issues.first {
            issue = found.line.map { String(localized: "Line \($0): \(found.message)") } ?? found.message
        }
        testResult = ScriptTestResult(before: sent, after: shown, issue: issue)
    }
}

// MARK: the views

/// The words Core gives as English constants (`RewriteText`), in the app's language.
enum ScriptWords {
    static var turnedOff: String { String(localized: String.LocalizationValue(RewriteText.turnedOff)) }
}

/// The "Rewrites" section of Customize (design rewrite-rules §7): a caption, the rows (stage, Find, →, Replace with, the pattern switch, minus) and one
/// borderless "Add Rewrite". Empty, only the button shows. A row the time limit turned off is dimmed, says so, and has "Turn On".
struct RewriteTable: View {
    let editor: AppMemoryEditor
    @FocusState private var focus: Int?

    /// Find and Replace with share the row's width equally (ui-all A4: Find's layout priority left Replace 12 pt), neither under 100 pt; the ".*" switch is wide
    /// enough to draw both characters.
    static let fieldMinWidth: CGFloat = 100
    static let patternWidth: CGFloat = 28

    var body: some View {
        Section {
            let rows = editor.rewriteRows
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                VStack(alignment: .leading, spacing: 3) {
                    rowLine(i, row)
                    if !row.on {
                        HStack {
                            Text(ScriptWords.turnedOff).font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button("Turn On") { editor.updateRewrite(at: i) { $0.on = true } }
                                .buttonStyle(.borderless).foregroundStyle(.tint).font(.caption)
                        }
                    }
                    if let problem = editor.issueLine(forRow: i) {
                        Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if editor.rewritesTouchTranslation {
                Text("Changing the translation can leave a wrong particle (은/는, 이/가) after a replaced word. Prefer “Swap into the text” on the name’s row.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button {
                    editor.addRewrite()
                    focus = editor.rewriteRows.count - 1
                } label: {
                    Label("Add Rewrite", systemImage: "plus")
                }
                .buttonStyle(.borderless).foregroundStyle(.tint)
                .disabled(!editor.canAddRewrite)
                if !editor.canAddRewrite {
                    Text("That is the most: \(RewriteLimits.maxRows).").font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            // The caption sits under the header, as the design says (rewrite-rules §7), not below the card.
            VStack(alignment: .leading, spacing: 2) {
                Text("Rewrites")
                Text("Change the text on this Mac, free: the original before it is translated, or the translation after.")
                    .font(.caption.weight(.regular)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stagePicker(_ stage: Binding<RewriteStage>) -> some View {
        Picker("Applies to", selection: stage) {
            Text("Original").tag(RewriteStage.before)
            Text("Translation").tag(RewriteStage.after)
        }
        .labelsHidden()
    }

    private func rowLine(_ i: Int, _ row: RewriteRow) -> some View {
        HStack(spacing: 6) {
            // Every row's pop-up is as wide as the wider stage name in this language: a fixed 96 pt cut "Translation" to
            // "Transl…" (ui-all A4 recapture), and sizing to the shown name made rows uneven (vision-final FIX-1).
            ZStack {
                ForEach([RewriteStage.before, .after], id: \.self) { stage in
                    stagePicker(.constant(stage)).fixedSize().hidden().accessibilityHidden(true)
                }
                stagePicker(Binding(get: { row.stage }, set: { v in editor.updateRewrite(at: i) { $0.stage = v } }))
                    .frame(maxWidth: .infinity)
            }
            .fixedSize()
            TextField("Find", text: Binding(get: { editor.rewriteRows.indices.contains(i) ? editor.rewriteRows[i].find : "" },
                                            set: { v in editor.updateRewrite(at: i) { $0.find = v } }), prompt: Text("Find"))
                .labelsHidden()
                .accessibilityLabel("Text to find")
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: i)
                .frame(minWidth: Self.fieldMinWidth, maxWidth: .infinity)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            TextField("Replace with", text: Binding(get: { editor.rewriteRows.indices.contains(i) ? editor.rewriteRows[i].replace : "" },
                                                    set: { v in editor.updateRewrite(at: i) { $0.replace = v } }), prompt: Text("Replace with"))
                .labelsHidden()
                .accessibilityLabel("Replacement")
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: Self.fieldMinWidth, maxWidth: .infinity)
            Toggle(isOn: Binding(get: { row.regex }, set: { v in editor.updateRewrite(at: i) { $0.regex = v } })) {
                Text(verbatim: ".*").font(.body.monospaced())
            }
            .toggleStyle(.button)
            .frame(width: Self.patternWidth)
            .help("Treat Find as a pattern (a JavaScript regular expression)")
            .accessibilityLabel("Pattern")
            Button { editor.removeRewrite(at: i) } label: { Image(systemName: "minus.circle").frame(width: 22, height: 22).contentShape(Rectangle()) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Remove this rewrite")
                .accessibilityLabel("Remove this rewrite")
        }
        .opacity(row.on ? 1 : 0.5)
    }
}

/// The "Script" row of Customize and its editor (design rewrite-rules §7): collapsed it says "Script · Off", "On" or "Error"; open it holds a monospaced
/// editor (120 to 240 pt) that shows the two examples in tertiary while empty, its counter, the switch "Run this script", a sample line with "Test", and the
/// two lines the Test made ("Before → …", "After → …"). Errors are red with their line.
struct ScriptEditor: View {
    let editor: AppMemoryEditor
    @State private var open: Bool

    /// - `open`: for the capture harness and the checks, the editor open from the start (nil: collapsed, or open for a profile that has a script).
    init(editor: AppMemoryEditor, open: Bool? = nil) {
        self.editor = editor
        _open = State(initialValue: open ?? false)
    }

    private static let examples = """
        function before(line, ctx) { return line.replace(/（[ぁ-ゖ]+）/gu, "") }
        function after(src, dst, ctx) { return ctx.target === "ko" ? dst.replace(/\\.\\.\\./g, "…") : dst }
        """

    private var stateWord: String {
        switch editor.scriptState {
        case .off: String(localized: "Off")
        case .on: String(localized: "On")
        case .error: String(localized: "Error")
        }
    }

    var body: some View {
        Section {
            Button {
                withAnimation(Motion.shared.animation(.snappy)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12)
                    Text("Script · \(stateWord)")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Script")
            .accessibilityValue(stateWord)
            .accessibilityAddTraits(.isButton)
            if open { editorBody }
        }
    }

    @ViewBuilder private var editorBody: some View {
        let source = editor.script?.source ?? ""
        TextEditor(text: Binding(get: { source }, set: { editor.setScriptSource($0) }))
            .font(.body.monospaced())
            .scrollContentBackground(.hidden)
            .frame(minHeight: 120, maxHeight: 240)
            .overlay(alignment: .topLeading) {
                if source.isEmpty {
                    Text(verbatim: Self.examples).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        .padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                }
            }
            .accessibilityLabel("Script text")
        HStack {
            Toggle("Run this script", isOn: Binding(get: { editor.script?.on ?? false }, set: { editor.setScriptOn($0) }))
                .disabled(source.isEmpty)
                .help("Run this script on every line of this profile.")
            Spacer()
            Text("\(source.count.formatted()) / \(RewriteLimits.maxScript.formatted())")
                .font(.caption).monospacedDigit()
                .foregroundStyle(source.count >= RewriteLimits.maxScript ? Color.orange : Color.secondary)
        }
        if let problem = editor.scriptIssueLine {
            Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            TextField("A line to test", text: Binding(get: { editor.sample }, set: { editor.sample = $0 }), prompt: Text("A line to test"))
                .accessibilityLabel("A line to test")
                .textFieldStyle(.roundedBorder)
            Button("Test") { Task { await editor.runTest() } }
                .disabled(source.isEmpty || editor.sample.isEmpty)
                .help("Run the script on this line. Nothing is sent.")
        }
        if let result = editor.testResult {
            VStack(alignment: .leading, spacing: 2) {
                Text("Before → \(result.before)")
                Text("After → \(result.after)")
                if let issue = result.issue { Text(issue).foregroundStyle(.red) }
            }
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
