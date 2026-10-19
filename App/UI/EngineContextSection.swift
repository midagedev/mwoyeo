import MwoyeoCore
import SwiftUI

/// What the engine sheet's Context section shows and says, without a window: the checks ask these the same way the view does.
/// The settings are `engines[].context` (`EngineContext`); this file adds no key.
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

    /// The collapsed section's one line, after "Context ·": the number of previous lines when it is on, else Off.
    static func summary(_ context: EngineContext?) -> String {
        guard let context, context.enabled else { return String(localized: "Off") }
        return String(localized: "\(context.previousLines) lines")
    }

    /// The disclosure's animation: none while Reduce Motion is on (`Motion` owns the setting).
    @MainActor static func expansion() -> Animation? { Motion.shared.animation(.snappy) }

    // MARK: writing

    /// Changes the engine's context in settings (and so in settings.json, as every control of the app does). An engine with none
    /// starts from `EngineContext()`, which is Off.
    @MainActor static func update(_ id: UUID, in model: AppModel, _ change: (inout EngineContext) -> Void) {
        guard let i = model.settings.engines.firstIndex(where: { $0.id == id }) else { return }
        var context = model.settings.engines[i].context ?? EngineContext()
        change(&context)
        model.settings.engines[i].context = context
    }
}

/// The Context section of the engine sheet (design §3): one collapsed disclosure between the sample result and Advanced, for an
/// engine that is already added. Every control writes `settings.engines[].context` as it is turned; the sheet's Save does not own it.
/// Descriptions are help tags, so the only text that is always on screen is the controls' names and the Sent line.
struct EngineContextSection: View {
    @Environment(AppModel.self) private var model
    /// The engine as the sheet has it now: what is typed in the form (the kind), with its switches as settings hold them.
    let engine: EngineConfig
    @State private var expanded: Bool

    init(engine: EngineConfig, opensExpanded: Bool = false) {
        self.engine = engine
        _expanded = State(initialValue: opensExpanded)
    }

    private var kind: EngineKind { engine.kind }
    private var context: EngineContext? { model.settings.engines.first { $0.id == engine.id }?.context }
    private var isOn: Bool { context?.enabled ?? false }
    private var lines: Int { (context ?? EngineContext()).previousLines }
    private var summary: String { EngineContextRules.summary(context) }
    /// The engine with its switches as they are this moment, for the Sent line.
    private var current: EngineConfig {
        var e = engine
        e.context = context
        return e
    }

    private func binding<V>(_ key: WritableKeyPath<EngineContext, V>) -> Binding<V> {
        Binding(get: { (context ?? EngineContext())[keyPath: key] },
                set: { value in EngineContextRules.update(engine.id, in: model) { $0[keyPath: key] = value } })
    }

    private var disclosure: Binding<Bool> {
        Binding(get: { expanded }, set: { open in withAnimation(EngineContextRules.expansion()) { expanded = open } })
    }

    var body: some View {
        DisclosureGroup(isExpanded: disclosure) {
            Toggle("Use context", isOn: binding(\.enabled))
                .help("Sends the app’s name and the lines around the text with each request, so names and tone stay consistent.")
            LabeledContent("Previous lines") {
                HStack(spacing: 6) {
                    // The stepper says its own value to a screen reader; the digit beside it is for the eye.
                    Text(verbatim: "\(lines)").monospacedDigit().foregroundStyle(.secondary).accessibilityHidden(true)
                    Stepper("Previous lines", value: binding(\.previousLines), in: 0...AppContextOverride.maxPreviousLines)
                        .labelsHidden()
                }
            }
            .disabled(!isOn)
            .help("How many lines before the text are sent. More lines tell the engine more about who and what is meant, and make each request longer.")
            if EngineContextRules.asksTitle(kind) {
                Toggle("Include window title", isOn: binding(\.includeTitle))
                    .disabled(!isOn)
                    .help("The title of the window under the lens goes to this engine too. Titles can hold private text, so this stays off until you turn it on.")
            }
            if EngineContextRules.asksLearned(kind) {
                Toggle("Learn names and terms", isOn: binding(\.useLearned))
                    .disabled(!isOn)
                    .help("The engine suggests the names and terms it translated, and Mwoyeo reuses them for that app.")
            }
            if EngineContextRules.asksDeepLNotes(kind) {
                Toggle("Use my notes with DeepL", isOn: binding(\.deepLInstructions))
                    .disabled(!isOn)
                    .help("Sends your note and names for the app to DeepL as instructions, and sets the formality from them.")
            }
            Text(verbatim: EngineContextSent.line(for: current, in: model))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            // One element for a screen reader: the name, and the summary as its value ("Context, 3 lines"). The modifiers sit on the label,
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
