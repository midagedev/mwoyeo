import MwoyeoCore
import SwiftUI

/// The initialization of the text models (`TextRecognizer.warmUp`) as the menu panel shows it: quietly, since lenses read
/// with the simpler reader meanwhile. A warm launch shows nothing. A cold one (`SwiftVisionGate.shouldShowProgress`) turns the
/// header's status line into "Preparing text recognition…", whose tooltip lists the steps; a failed step becomes the panel's
/// usual issue banner, with "Try Again".
enum VisionSetupDisplay {
    /// The gate and its clock: the real one, or `MenuPanel.fakeSetup` for `--capture-ui`.
    @MainActor static var current: (gate: SwiftVisionGate, now: TimeInterval) {
        MenuPanel.fakeSetup ?? (VisionSetup.shared.gate, Trace.now)
    }

    static func failed(_ gate: SwiftVisionGate) -> Bool {
        gate.steps.values.contains { if case .failed = $0 { true } else { false } }
    }

    static func allDone(_ gate: SwiftVisionGate) -> Bool {
        SwiftVisionGate.Step.allCases.allSatisfy { if case .done = gate.steps[$0] { true } else { false } }
    }

    /// One line per step, for the tooltip: "Text reader  12 s".
    static func details(_ gate: SwiftVisionGate, now: TimeInterval) -> String {
        SwiftVisionGate.Step.allCases.map { step in
            let state = gate.steps[step] ?? .pending
            let time: String = switch state {
            case .pending, .failed: ""
            case let .running(since): String(localized: "\(Int(max(0, now - since))) s")
            case let .done(seconds): String(localized: "\(Int(seconds.rounded())) s")
            }
            let mark = switch state {
            case .pending: "○"
            case .running: "…"
            case .done: "✓"
            case .failed: "!"
            }
            return "\(mark) \(title(step))  \(time)"
        }.joined(separator: "\n")
    }

    private static func title(_ step: SwiftVisionGate.Step) -> String {
        switch step {
        case .textModel: String(localized: "Text reader")
        case .documentModel: String(localized: "Paragraph reader")
        case .swiftTextModel: String(localized: "Language reader")
        }
    }
}

/// The header's status line, or "Preparing text recognition…" while a cold initialization runs.
struct StatusLine: View {
    let base: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let (gate, now) = VisionSetupDisplay.current
            // A status line goes back the moment the steps are done (the gate's linger is for a card that should not blink away).
            let preparing = gate.shouldShowProgress(now: now) && !VisionSetupDisplay.failed(gate) && !VisionSetupDisplay.allDone(gate)
            Text(preparing ? String(localized: "Preparing text recognition…") : base)
                .font(.caption).foregroundStyle(.secondary).contentTransition(.opacity)
                .help(preparing ? VisionSetupDisplay.details(gate, now: now) : "")
        }
    }
}

/// A failed initialization step, as the panel's usual issue banner.
struct SetupIssue: View {
    var body: some View {
        let (gate, now) = VisionSetupDisplay.current
        if VisionSetupDisplay.failed(gate) {
            IssueBanner(message: String(localized: "Text recognition isn’t fully ready."),
                        detail: String(localized: "Lenses keep working with a simpler reader."),
                        action: String(localized: "Try Again")) { VisionSetup.shared.retry() }
                .help(VisionSetupDisplay.details(gate, now: now))
        }
    }
}
