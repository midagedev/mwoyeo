import AppKit
import MwoyeoCore
import MwoyeoEngines
import SwiftUI

/// Add or edit one translation engine. Step 1 picks what to connect; step 2 asks only for what that choice needs.
/// The key goes to the Keychain the moment it is pasted (the sheet needs it to list models and run the sample) and is
/// never shown again; cancelling an add deletes it.
struct EngineSheet: View {
    /// What to open on: the picker, or one engine to change.
    var editing: EngineConfig?
    /// For the capture harness: fills the sheet as a user would, through the same code paths.
    var autopilot: Autopilot?
    /// Opened from the engine list's "Allow…": the box that allows sending to the engine's host has the focus.
    var focusConsent = false

    struct Autopilot {
        /// A preset's name: opens step 2 for it.
        var preset: String?
        /// A shared setup, pasted into the Paste Setup step.
        var setup: String?
        /// A key, typed into the key field.
        var key: String?
        /// Tick the box that allows sending to the engine's host, as a click on it would.
        var allow = false
        /// Press Add once the sample has run.
        var commit = false
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    // Step
    private enum Step { case pick, paste, configure }
    @State private var step = Step.pick
    @State private var localRunning: [String: Bool] = [:]

    // The engine being set up
    private enum Family { case chat(anthropic: Bool), deepL, template, command }
    @State private var family = Family.chat(anthropic: false)
    @State private var id = UUID()
    @State private var preset: EnginePresets.Preset?
    @State private var needsKey = false
    @State private var custom = false
    @State private var nameText = ""
    @State private var baseURL = ""
    @State private var modelText = ""
    @State private var thinking = Thinking.off
    @State private var headersText = ""
    @State private var formality: String?
    @State private var tMethod = "POST"
    @State private var tURL = ""
    @State private var tBody = ""
    @State private var tResult = ""
    @State private var tBatching = HTTPTemplate.Batching.perLine
    @State private var exe = ""
    @State private var argsText = ""
    @State private var pasted = ""
    @State private var pasteError: String?

    // Key, models, sample
    @State private var key = ""
    @State private var keySaved = false
    @State private var models: [String] = []
    @State private var modelsLoaded = false
    @State private var work: Work = .idle
    @State private var job: Task<Void, Never>?
    @State private var added = false
    /// Editing: the key as it was when the sheet opened, put back if the sheet closes without Save.
    @State private var keyAtOpen: String?
    @State private var showAdvanced = false
    /// The host the person ticked "Send the text the lens reads to …" for. The box counts as ticked only while it is the host the engine
    /// has now, so changing the address un-ticks it. Nothing sets it but the box (and an edit of an engine that already has the record).
    @State private var allowedHost: String?
    @FocusState private var consentFocused: Bool

    private enum Work: Equatable {
        case idle, working
        case ok(sample: String, ms: Int)
        case failed(String)
    }

    private var isEdit: Bool { editing != nil }

    var body: some View {
        VStack(spacing: 0) {
            switch step {
            case .pick: pick
            case .paste: pasteStep
            case .configure: configure
            }
            Divider()
            buttons
        }
        .frame(width: 480, height: 560)
        .task { await start() }
        .onDisappear {
            job?.cancel()
            if !isEdit, !added { try? model.secrets.setSecret(nil, for: id) }
            if isEdit, !added, let k = keyAtOpen { try? model.secrets.setSecret(k, for: id) }
        }
    }

    // MARK: - Step 1

    private var pick: some View {
        Form {
            Section("On this Mac") {
                ForEach(Self.localNames, id: \.self) { name in
                    if let p = Self.preset(name) { pickRow(verbatim: p.name, verbatim: p.localizedHint, status: localRunning[p.name]) { begin(preset: p) } }
                }
            }
            Section("Cloud") {
                ForEach(Self.cloudNames, id: \.self) { name in
                    if let p = Self.preset(name) { pickRow(verbatim: p.name, verbatim: p.localizedHint) { begin(preset: p) } }
                }
            }
            Section("Connect your own") {
                pickRow("OpenAI-compatible server", "Any server that speaks the OpenAI chat API") { begin(custom: .server) }
                pickRow("HTTP template", "Your own web service, described in a few lines") { begin(custom: .template) }
                if !Distribution.isAppStore {
                    pickRow("Command", "A program on this Mac that reads and writes JSON") { begin(custom: .command) }
                }
                pickRow("Paste Setup", "A setup someone shared with you") { step = .paste }
            }
        }
        .formStyle(.grouped)
    }

    private func pickRow(verbatim title: String, verbatim hint: String, status: Bool? = nil, action: @escaping () -> Void) -> some View {
        pickRow(title: Text(verbatim: title), hint: Text(verbatim: hint), status: status, action: action)
    }

    private func pickRow(_ title: LocalizedStringKey, _ hint: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        pickRow(title: Text(title), hint: Text(hint), status: nil, action: action)
    }

    private func pickRow(title: Text, hint: Text, status: Bool?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    title
                    hint.font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let status {
                    Text(status ? "Running" : "Not running").font(.caption)
                        .foregroundStyle(status ? Color.green : Color.secondary)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static let localNames = ["Ollama", "LM Studio", "LibreTranslate", "DeepLX"]
    private static let cloudNames = ["Gemini", "OpenAI", "Claude", "DeepSeek", "OpenRouter", "Groq", "Qwen (Alibaba Cloud)", "DeepL"]
    private static func preset(_ name: String) -> EnginePresets.Preset? { EnginePresets.all.first { $0.name == name } }

    private enum Custom { case server, template, command }

    private func begin(preset p: EnginePresets.Preset) {
        preset = p
        custom = false
        needsKey = p.needsKey
        load(p.instantiate(), blankURL: false)
        step = .configure
        if !p.needsKey { job = Task { await run(loadModels: true) } }
    }

    private func begin(custom kind: Custom) {
        preset = nil
        custom = true
        switch kind {
        case .server:
            load(EngineConfig(name: String(localized: "My server"), kind: .openAICompatible(
                baseURL: URL(string: "http://localhost")!, model: "", thinking: .off, extraHeaders: [:])), blankURL: true)
        case .template:
            load(EngineConfig(name: String(localized: "HTTP template"), kind: .httpTemplate(HTTPTemplate(url: "", resultPath: ""))), blankURL: true)
        case .command:
            load(EngineConfig(name: String(localized: "Command"), kind: .command(CommandSpec(executable: ""))), blankURL: true)
        }
        needsKey = false
        step = .configure
    }

    // MARK: - Paste Setup

    private var pasteStep: some View {
        Form {
            Section {
                TextEditor(text: $pasted)
                    .font(.body.monospaced())
                    .frame(minHeight: 220)
                    .scrollContentBackground(.hidden)
                HStack {
                    Button("Paste from Clipboard") { pasted = NSPasteboard.general.string(forType: .string) ?? pasted; pasteError = nil }
                    Spacer()
                    Button("Continue") { readPasted() }.disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let pasteError {
                    Label(pasteError, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Paste Setup")
            } footer: {
                Text("A setup holds the engine’s address and settings, never its key. You add the key next.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func readPasted() {
        do {
            let config = try EngineShare.decode(pasted, allowsCommands: !Distribution.isAppStore)
            preset = EnginePresets.all.first { $0.name == config.name }
            custom = false
            load(config, blankURL: false)
            needsKey = preset?.needsKey ?? !config.isOnThisMac
            step = .configure
            job = Task { await run(loadModels: true) }
        } catch let e as EngineConfigError {
            switch e {
            case .unknownKind: pasteError = String(localized: "This engine needs a newer Mwoyeo.")
            case .secretField: pasteError = String(localized: "This setup contains a key. Remove it and try again.")
            case .commandNotAllowed: pasteError = String(localized: "Command engines are not available in this version.")
            case .notAnEngineFile: pasteError = String(localized: "This is not an engine setup.")
            case .malformed: pasteError = String(localized: "This text is not a valid setup.")
            }
        } catch {
            pasteError = String(localized: "This text is not a valid setup.")
        }
    }

    // MARK: - Step 2

    private var configure: some View {
        Form {
            Section {
                if hasKeyField { keyRow }
                if isLocalPreset { serverRow }
                if case .chat = family { modelRow }
                if case .template = family { templateMainFields }
                if case .command = family { commandMainFields }
                if custom, case .chat = family { TextField("Base URL", text: $baseURL, prompt: Text(verbatim: "http://localhost:8080/v1")) }
            } header: {
                Text(headerTitle)
            }
            if let host = remoteHost {
                Section {
                    Toggle("Send the text the lens reads to \(host)", isOn: consent)
                        .toggleStyle(.checkbox)
                        .focused($consentFocused)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Group {
                            Text("Your engine's provider handles that text under its own privacy policy.")
                            if sendsContext { Text("Recent lines are sent too, for context.") }
                        }
                        .foregroundStyle(.secondary)
                        Link("Privacy Policy", destination: Distribution.privacyPolicy)
                    }
                    .font(.caption)
                }
            }
            Section { resultRow }
            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) { advancedFields }
            }
        }
        .formStyle(.grouped)
    }

    private var headerTitle: String {
        if let preset { return preset.name }
        return nameText
    }

    private var hasKeyField: Bool {
        switch family {
        case .chat: needsKey || preset == nil
        case .deepL: true
        case .template: (tBody + headersText).contains("{{key}}")
        case .command: false
        }
    }

    private var isLocalPreset: Bool { preset.map { !$0.needsKey && $0.keyURL == nil } ?? false }

    private var remoteHost: String? {
        guard let c = build(), !c.isOnThisMac else { return nil }
        return c.endpointName
    }

    /// The host the box is about (lower case, as the record keeps it); nil while the engine stays on this Mac.
    private var consentHost: String? { build().flatMap(EnginePermissions.host(of:)) }

    private var consentGiven: Bool { consentHost != nil && allowedHost == consentHost }

    private var consent: Binding<Bool> {
        Binding(get: { consentGiven }, set: { allowedHost = $0 ? consentHost : nil })
    }

    /// Whether recent lines can go along with the text: the engine's context switch, or an app's override, can turn context on.
    private var sendsContext: Bool {
        guard var c = build() else { return false }
        c.context = model.settings.engines.first { $0.id == id }?.context
        return EnginePermissions.sendsContext(c, profiles: model.settings.appProfiles)
    }

    private var keyRow: some View {
        LabeledContent(needsKey ? "API key" : "API key (optional)") {
            if keySaved {
                HStack(spacing: 8) {
                    Label("Saved in Keychain", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary).labelStyle(.titleAndIcon)
                    Button("Replace…") { keySaved = false }
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("", text: $key, prompt: Text("Paste your key"))
                        .labelsHidden()
                        .onChange(of: key) { _, _ in keyChanged() }
                        .onSubmit { keyChanged(now: true) }
                    if let url = preset?.keyURL { Link("Get a key", destination: url).font(.callout) }
                }
            }
        }
    }

    private var serverRow: some View {
        LabeledContent("Server") {
            HStack(spacing: 8) {
                let running = localRunning[preset?.name ?? ""]
                Text(running == nil ? "Checking…" : running == true ? "Running" : "Not running")
                    .foregroundStyle(running == true ? Color.green : Color.secondary)
                Button("Check again") { job?.cancel(); job = Task { await run(loadModels: true) } }
            }
        }
    }

    @ViewBuilder private var modelRow: some View {
        if models.isEmpty {
            TextField("Model", text: $modelText, prompt: Text(verbatim: preset?.suggestedModel ?? "model-name"))
                .onSubmit { schedule(loadModels: false) }
        } else {
            Picker("Model", selection: Binding(get: { modelText }, set: { modelText = $0; schedule(loadModels: false) })) {
                if modelText.isEmpty { Text("Choose a model").tag("") }
                if !modelText.isEmpty, !models.contains(modelText) { Text(verbatim: modelText).tag(modelText) }
                ForEach(models, id: \.self) { Text(verbatim: $0).tag($0) }
            }
        }
    }

    @ViewBuilder private var templateMainFields: some View {
        TextField("URL", text: $tURL, prompt: Text(verbatim: "http://localhost:5000/translate"))
        TextField("Request body", text: $tBody, prompt: Text(verbatim: #"{"q": {{text}}, "target": "{{target}}"}"#), axis: .vertical)
            .lineLimit(2...5).font(.body.monospaced())
        TextField("Where the translation is", text: $tResult, prompt: Text(verbatim: "translatedText"))
    }

    @ViewBuilder private var commandMainFields: some View {
        TextField("Command", text: $exe, prompt: Text(verbatim: "/usr/local/bin/my-translator"))
        TextField("Arguments", text: $argsText, prompt: Text("One per line"), axis: .vertical).lineLimit(1...4)
    }

    @ViewBuilder private var advancedFields: some View {
        TextField("Name", text: $nameText)
        switch family {
        case .chat(let anthropic):
            if !custom { TextField("Base URL", text: $baseURL) }
            Picker("Thinking", selection: $thinking) {
                Text("Off").tag(Thinking.off)
                Text("Provider default").tag(Thinking.provider)
            }
            if !anthropic {
                TextField("Extra headers", text: $headersText, prompt: Text("Name: value, one per line"), axis: .vertical).lineLimit(1...4)
            }
        case .deepL:
            TextField("Base URL", text: $baseURL)
        case .template:
            TextField("Method", text: $tMethod)
            TextField("Headers", text: $headersText, prompt: Text("Name: value, one per line"), axis: .vertical).lineLimit(1...4)
            Picker("Lines per request", selection: $tBatching) {
                Text("One").tag(HTTPTemplate.Batching.perLine)
                Text("All as a JSON list").tag(HTTPTemplate.Batching.jsonArray)
            }
        case .command:
            EmptyView()
        }
    }

    @ViewBuilder private var resultRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch work {
            case .idle:
                Text(canTest ? "Run a sample to check the connection." : "A sample translation shows here.")
                    .font(.callout).foregroundStyle(.secondary)
            case .working:
                ProgressView().controlSize(.small)
                Text("Checking…").font(.callout).foregroundStyle(.secondary)
            case let .ok(sample, ms):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(verbatim: "\(sample) · \(ms) ms").font(.callout).textSelection(.enabled)
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Test") { schedule(loadModels: false) }.disabled(!canTest || work == .working)
        }
    }

    private var buttons: some View {
        HStack {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer()
            if step != .pick, !isEdit { Button("Back") { back() } }
            if step == .configure {
                Button(isEdit ? "Save" : "Add") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(16)
    }

    private func back() {
        job?.cancel()
        try? model.secrets.setSecret(nil, for: id)
        keySaved = false
        key = ""
        models = []
        work = .idle
        step = .pick
        id = UUID()
    }

    // MARK: - State ↔ engine

    private func load(_ c: EngineConfig, blankURL: Bool) {
        id = c.id
        nameText = c.name
        allowedHost = nil
        models = []
        work = .idle
        thinking = .off
        headersText = ""
        formality = nil
        modelText = ""
        baseURL = ""
        switch c.kind {
        case let .openAICompatible(url, model, think, headers):
            family = .chat(anthropic: false)
            baseURL = blankURL ? "" : url.absoluteString
            modelText = model
            thinking = think
            headersText = headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        case let .anthropic(url, model, think):
            family = .chat(anthropic: true)
            baseURL = url.absoluteString
            modelText = model
            thinking = think
        case let .deepL(url, form):
            family = .deepL
            baseURL = url.absoluteString
            formality = form
        case let .httpTemplate(t):
            family = .template
            tMethod = t.method
            tURL = t.url
            tBody = t.body
            tResult = t.resultPath
            tBatching = t.batching
            headersText = t.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        case let .command(spec):
            family = .command
            exe = spec.executable
            argsText = spec.arguments.joined(separator: "\n")
        }
    }

    private func parseHeaders() -> [String: String] {
        var out: [String: String] = [:]
        for line in headersText.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty { out[parts[0]] = parts[1] }
        }
        return out
    }

    private func build() -> EngineConfig? {
        let name = nameText.trimmingCharacters(in: .whitespaces)
        let shown = name.isEmpty ? (preset?.name ?? String(localized: "Engine")) : name
        let model = modelText.trimmingCharacters(in: .whitespaces)
        func url() -> URL? {
            guard let u = URL(string: baseURL.trimmingCharacters(in: .whitespaces)), u.scheme != nil, u.host != nil else { return nil }
            return u
        }
        switch family {
        case let .chat(anthropic):
            guard let u = url() else { return nil }
            return EngineConfig(id: id, name: shown, kind: anthropic
                ? .anthropic(baseURL: u, model: model, thinking: thinking)
                : .openAICompatible(baseURL: u, model: model, thinking: thinking, extraHeaders: parseHeaders()))
        case .deepL:
            guard let u = url() else { return nil }
            return EngineConfig(id: id, name: shown, kind: .deepL(baseURL: u, formality: formality))
        case .template:
            let t = tURL.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            return EngineConfig(id: id, name: shown, kind: .httpTemplate(HTTPTemplate(
                method: tMethod.isEmpty ? "POST" : tMethod, url: t, headers: parseHeaders(), body: tBody,
                resultPath: tResult.trimmingCharacters(in: .whitespaces), batching: tBatching)))
        case .command:
            let e = exe.trimmingCharacters(in: .whitespaces)
            guard !e.isEmpty else { return nil }
            let args = argsText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return EngineConfig(id: id, name: shown, kind: .command(CommandSpec(executable: e, arguments: args)))
        }
    }

    private var keyPresent: Bool { keySaved || !key.isEmpty }

    private var canAdd: Bool {
        guard let c = build() else { return false }
        guard EnginePermissions.mayCommit(c, ticked: allowedHost) else { return false }
        switch c.kind {
        case .openAICompatible, .anthropic: return c.modelName != nil && (!needsKey || keyPresent)
        case .deepL: return keyPresent
        case let .httpTemplate(t): return !t.resultPath.isEmpty
        case .command: return true
        }
    }

    private var canTest: Bool {
        guard let c = build() else { return false }
        switch c.kind {
        case .openAICompatible, .anthropic: return c.modelName != nil && (!needsKey || keyPresent)
        case .deepL: return keyPresent
        case let .httpTemplate(t): return !t.resultPath.isEmpty
        case .command: return true
        }
    }

    private func commit() {
        saveKey()
        guard let config = build() else { return }
        added = true
        model.setSendingAllowed(consentGiven, for: config)
        if isEdit { model.updateEngine(config) } else { model.addEngine(config) }
        dismiss()
    }

    // MARK: - Key, models, sample

    private func keyChanged(now: Bool = false) {
        guard !key.isEmpty else { return }
        job?.cancel()
        job = Task {
            if !now { try? await Task.sleep(for: .milliseconds(700)) }
            guard !Task.isCancelled else { return }
            saveKey()
            await run(loadModels: true)
        }
    }

    /// Writes the pasted key to the Keychain and clears the field.
    private func saveKey() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        do {
            try model.secrets.setSecret(k, for: id)
            keySaved = true
        } catch {
            work = .failed(String(localized: "The key could not be saved to the Keychain."))
        }
        key = ""
    }

    private func schedule(loadModels: Bool) {
        job?.cancel()
        job = Task { await run(loadModels: loadModels) }
    }

    /// Lists the engine's models (chat engines), then runs one sample translation once a model is chosen.
    private func run(loadModels: Bool) async {
        guard var config = build() else { return }
        if needsKey, !keyPresent { work = .idle; return }
        if isLocalPreset, let p = preset {
            localRunning[p.name] = await LocalServer.isRunning(config.kind)
            if localRunning[p.name] != true { work = .idle; return }
        }
        if case .chat = family {
            if loadModels {
                work = .working
                switch await model.translator.engineModels(config, refresh: true) {
                case let .success(ids):
                    guard !Task.isCancelled else { return }
                    models = ids
                    if modelText.isEmpty || !ids.contains(modelText) {
                        if let s = preset?.suggestedModel, ids.contains(s) { modelText = s }
                        else if ids.count == 1 { modelText = ids[0] }
                    }
                case let .failure(error):
                    guard !Task.isCancelled else { return }
                    models = []
                    work = .failed(error.localizedMessage)
                    return
                }
            }
            guard !modelText.isEmpty, let c = build() else { work = .idle; return }
            config = c
        }
        guard canTest else { work = .idle; return }
        work = .working
        let r = await model.translator.engineProbe(config)
        guard !Task.isCancelled else { return }
        if let error = r.error { work = .failed(error.localizedMessage) }
        else { work = .ok(sample: r.sample ?? "", ms: r.ms) }
    }

    // MARK: - Opening

    private func start() async {
        if let e = editing {
            load(e, blankURL: false)
            custom = false
            preset = EnginePresets.all.first { $0.name == e.name }
            needsKey = { if case .command = e.kind { return false }; return !e.isOnThisMac }()
            keyAtOpen = (try? model.secrets.secret(for: e.id)) ?? nil
            keySaved = keyAtOpen != nil
            allowedHost = model.settings.enginePermissions.allows(e) ? EnginePermissions.host(of: e) : nil
            step = .configure
            consentFocused = focusConsent
            if keySaved || e.isOnThisMac { await run(loadModels: true) }
        } else {
            async let running: Void = detectLocal()
            if let a = autopilot { await drive(a) }
            await running
        }
    }

    private func drive(_ a: Autopilot) async {
        if let name = a.preset, let p = Self.preset(name) { begin(preset: p) }
        if let setup = a.setup { pasted = setup; readPasted() }
        if a.allow { allowedHost = consentHost }
        if let k = a.key {
            try? await Task.sleep(for: .milliseconds(400)) // the key field has to be on screen to be typed into
            key = k
        }
        guard a.commit else { return }
        try? await Task.sleep(for: .seconds(1.5))
        while work == .working || (a.key != nil && !keySaved) { try? await Task.sleep(for: .milliseconds(100)) }
        commit()
    }

    private func detectLocal() async {
        await withTaskGroup(of: (String, Bool).self) { group in
            for name in Self.localNames {
                guard let kind = Self.preset(name)?.config.kind else { continue }
                group.addTask { (name, await LocalServer.isRunning(kind)) }
            }
            for await (name, running) in group { localRunning[name] = running }
        }
    }
}

/// Is a local engine's server up? Asked within half a second. A chat server must answer its model list; a self-hosted
/// translator must answer its root with anything but an error (port 5000 on a Mac is often AirPlay, which answers 403).
enum LocalServer {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 0.5
        c.timeoutIntervalForResource = 0.5
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static func isRunning(_ kind: EngineKind) async -> Bool {
        switch kind {
        case let .openAICompatible(base, _, _, _):
            var url = base
            url.append(path: "models")
            return await status(of: url) == 200
        case let .httpTemplate(t):
            guard let url = URL(string: t.url), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
            parts.path = "/"
            parts.query = nil
            guard let root = parts.url, let code = await status(of: root) else { return false }
            return code < 400
        default:
            return false
        }
    }

    private static func status(of url: URL) async -> Int? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5
        guard let (_, response) = try? await session.data(for: request) else { return nil }
        return (response as? HTTPURLResponse)?.statusCode
    }
}
