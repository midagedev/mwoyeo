#if !MAS
import Foundation

/// The film and debug switches that turn one rule off to show or measure what it does: `MWOYEO_KEEP=off` (the code regions are
/// translated again), `MWOYEO_PREDICT=off` (the scroll predictor is not fed). Never a default, and not compiled into the App Store
/// build: its callers read these names under the same condition.
enum DebugSwitch {
    /// Whether `name` is set to `off` in `environment`; any other value, or none, leaves the rule on.
    static func isOff(_ name: String, in environment: [String: String]) -> Bool { environment[name] == "off" }
}
#endif
