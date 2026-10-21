import MwoyeoCore
import SwiftUI

/// What the engine sheet's Context section shows and says, without a window: the checks ask these the same way the view does.
/// The settings are All apps' amount (`context`, `useLearned`) and the engine's `allow` (`EngineAllow`, design names-and-context §4.1, §6.5);
/// this file adds no key. The old `engines[].context` is read by the converter and never written.
enum EngineContextRules {
    /// The section is for the engines the context layout reaches: a chat server, Anthropic and DeepL. An HTTP template or a command
    /// owns its body, so no context goes into it and the section is not offered (`LayoutKind.tier == nil`).
    static func shows(_ kind: EngineKind) -> Bool { LayoutKind.engine(kind).tier != nil }

    /// The window title goes to an engine on this Mac whatever the switch says, so the switch is for the others only.
    static func asksTitle(_ kind: EngineKind) -> Bool { !LayoutKind.engine(kind).isOnDevice }

    /// DeepL answers with the translation alone, so the names and terms the model would suggest never come back from it.
    static func asksLearned(_ kind: EngineKind) -> Bool {
        if case .deepL = kind { return false }
        return true
    }

    static func asksDeepLNotes(_ kind: EngineKind) -> Bool {
        if case .deepL = kind { return true }
        return false
    }

    /// The collapsed section's one line, after "Context ·": All apps' amount in words ("names and note", "conversation 3").
    static func summary(_ context: AppContextOverride?) -> String { ProfileWords.amount(context) }

    /// The disclosure's animation: none while Reduce Motion is on (`Motion` owns the setting).
    @MainActor static func expansion() -> Animation? { Motion.shared.animation(.snappy) }

    // MARK: writing

    /// Changes what the engine may be sent (`engines[].allow`) in settings (and so in settings.json, as every control of the app does). An
    /// engine that allows nothing new writes nothing: `allow` is saved only when it is not the default.
    @MainActor static func update(_ id: UUID, in model: AppModel, _ change: (inout EngineAllow) -> Void) {
        guard let i = model.settings.engines.firstIndex(where: { $0.id == id }) else { return }
        var allow = model.settings.engines[i].allow
        change(&allow)
        model.settings.engines[i].allow = allow
    }
}

/// The Context section of the engine sheet (design §6.5): one collapsed disclosure between the sample result and Advanced, for an engine that is
/// already added, "Context · <All apps' words>". Open, it holds All apps' amount ("For all apps", with "Earlier lines"), "Learn names and terms"
/// where the engine learns, the line that says a profile can ask for more or less (with "Profiles…" while one exists), and, for an engine off
/// this Mac, what may go there: the lines around the text, the window title, DeepL's notes; then the Sent line. Every control writes settings as
/// it is turned; the sheet's Save does not own it. "Use context" and "Previous lines" are gone: the profile holds the amount.
struct EngineContextSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The engine as the sheet has it now: what is typed in the form (the kind), with its switches as settings hold them.
    let engine: EngineConfig
    @State private var expanded: Bool

    init(engine: EngineConfig, opensExpanded: Bool = false) {
        self.engine = engine
        _expanded = State(initialValue: opensExpanded)
    }

    private var kind: EngineKind { engine.kind }
    private var allow: EngineAllow { model.settings.engines.first { $0.id == engine.id }?.allow ?? .default }
    private var amount: AppContextOverride? { model.settings.context }
    private var summary: String { EngineContextRules.summary(amount) }
    /// The engine with its switches as they are this moment, for the Sent line.
    private var current: EngineConfig {
        var e = engine
        e.allow = allow
        return e
    }

    private func allowBinding(_ key: WritableKeyPath<EngineAllow, Bool>) -> Binding<Bool> {
        Binding(get: { allow[keyPath: key] }, set: { value in EngineContextRules.update(engine.id, in: model) { $0[keyPath: key] = value } })
    }

    /// All apps' amount: a profile can set its own (design §6.3 c); here it is the one that every other chain starts from.
    private var choice: Binding<AppMemoryEditor.ContextChoice> {
        Binding(get: {
            switch amount?.mode {
            case nil, .memory?: .memory
            case .off?: .off
            case .nearby?: .nearby
            case .conversation?: .conversation
            }
        }, set: { choice in
            let lines = amount?.previousLines ?? AppContextOverride.defaultPreviousLines
            switch choice {
            case .follow, .memory: model.settings.context = nil
            case .off: model.settings.context = AppContextOverride(mode: .off)
            case .nearby: model.settings.context = AppContextOverride(mode: .nearby)
            case .conversation: model.settings.context = AppContextOverride(mode: .conversation, previousLines: lines)
            }
        })
    }

    private var disclosure: Binding<Bool> {
        Binding(get: { expanded }, set: { open in withAnimation(EngineContextRules.expansion()) { expanded = open } })
    }

    var body: some View {
        DisclosureGroup(isExpanded: disclosure) {
            Picker("For all apps", selection: choice) {
                Text("Only the line").tag(AppMemoryEditor.ContextChoice.off)
                Text("Names and note").tag(AppMemoryEditor.ContextChoice.memory)
                Text("Nearby lines").tag(AppMemoryEditor.ContextChoice.nearby)
                Text("Conversation").tag(AppMemoryEditor.ContextChoice.conversation)
            }
            if amount?.mode == .conversation {
                LabeledContent("Earlier lines") {
                    HStack(spacing: 6) {
                        // The stepper says its own value to a screen reader; the digit beside it is for the eye.
                        Text(verbatim: "\(amount?.previousLines ?? 0)").monospacedDigit().foregroundStyle(.secondary).accessibilityHidden(true)
                        Stepper("Earlier lines", value: Binding(get: { amount?.previousLines ?? AppContextOverride.defaultPreviousLines },
                                                                set: { model.settings.context = AppContextOverride(mode: .conversation, previousLines: $0) }),
                                in: 0...AppContextOverride.maxPreviousLines)
                            .labelsHidden()
                    }
                }
                .help("How many lines before the text are sent. More lines tell the engine more about who and what is meant, and make each request longer.")
            }
            // Right under the amount it qualifies, not under the Learn switch it would read as the subtitle of (ui-all A4).
            HStack {
                Text("A profile can ask for more or less.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !model.settings.appProfiles.isEmpty {
                    // The profiles are a section of Settings, behind this sheet: the sheet closes (no sheet over a sheet).
                    Button("Profiles…") { dismiss() }.buttonStyle(.borderless).foregroundStyle(.tint).font(.caption)
                }
            }
            if EngineContextRules.asksLearned(kind) {
                Toggle("Learn names and terms", isOn: Binding(get: { model.settings.useLearned }, set: { model.settings.useLearned = $0 }))
                    .help("The engine suggests the names and terms it translated, and Mwoyeo reuses them for that profile.")
            }
            if EngineContextRules.asksTitle(kind) {
                Toggle("Send the lines around the text", isOn: allowBinding(\.lines))
                    .help("Lines before and after the text go to this engine, so names and tone stay consistent.")
                if !allow.lines {
                    Text("\(engine.name) gets only the line, whatever a profile asks.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Send the window title", isOn: allowBinding(\.title))
                    .help("The title of the window under the lens goes to this engine too. Titles can hold private text, so this stays off until you turn it on.")
            }
            if EngineContextRules.asksDeepLNotes(kind) {
                Toggle("Use my notes with DeepL", isOn: allowBinding(\.deepLInstructions))
                    .help("Sends your note and names for the profile to DeepL as instructions, and sets the formality from them.")
            }
            Text(verbatim: EngineContextSent.line(for: current, in: model))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            // One element for a screen reader: the name, and the summary as its value ("Context, names and note"). The modifiers sit on the label,
            // not on the group: on the group they would rename every control inside it.
            HStack(spacing: 4) {
                Text("Context")
                Text(verbatim: "· \(summary)").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Context")
            .accessibilityValue(summary)
        }
    }
}
