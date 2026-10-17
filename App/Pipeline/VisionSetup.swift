import MwoyeoCore
import Observation

/// What a screen shows about the initialization of the text models (`TextRecognizer.warmUp`): the gate's state, replaced after
/// every change. `gate.steps` is where each step stands, `gate.shouldShowProgress(now: Trace.now)` whether the screen is up.
@MainActor @Observable
final class VisionSetup {
    static let shared = VisionSetup()
    var gate = SwiftVisionGate()

    /// Runs the failed steps again.
    func retry() { TextRecognizer.retrySetup() }
}
