import MwoyeoCore
import Observation

/// What a screen shows about the initialization of the text models (`TextRecognizer.warmUp`): the gate's state, replaced after
/// every change. `gate.steps` is where each step stands, `gate.shouldShowProgress(now: Trace.now)` whether the screen is up.
@MainActor @Observable
final class VisionSetup {
    static let shared = VisionSetup()
    var gate = SwiftVisionGate()
    /// Called after every replacement of `gate`; the app uses it to tell the lenses (a launch without an app has no one to tell).
    @ObservationIgnored var onChange: (() -> Void)?

    /// Runs the failed steps again.
    func retry() { TextRecognizer.retrySetup() }
}
