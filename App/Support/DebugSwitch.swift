#if !MAS
import Foundation
import MwoyeoCore

/// The film and debug switches that turn one rule off to show or measure what it does: `MWOYEO_KEEP=off` (the code regions are
/// translated again), `MWOYEO_PREDICT=off` (the scroll predictor is not fed); or one setting on without the system's: `MWOYEO_REDUCE_MOTION=on`
/// (a take of the Reduce Motion path, which would otherwise need the Mac's own setting changed); or one of two feels of a rule: `MWOYEO_SNAP=instant|dwell`
/// (a resize's snap, `LiveSnap`). Never a default, and not compiled into the App
/// Store build: its callers read these names under the same condition.
enum DebugSwitch {
    /// Whether `name` is set to `off` in `environment`; any other value, or none, leaves the rule on.
    static func isOff(_ name: String, in environment: [String: String]) -> Bool { environment[name] == "off" }

    /// The feel of a resize's snap `MWOYEO_SNAP` names (`instant` or `dwell`); any other value, or none, is the standard one (`LiveSnap.standard`).
    static func snapFeel(in environment: [String: String]) -> LiveSnap.Feel {
        environment["MWOYEO_SNAP"].flatMap(LiveSnap.Feel.init(rawValue:)) ?? LiveSnap.standard
    }

    /// Whether `name` is set to `on` in `environment`; any other value, or none, leaves the setting to the system.
    static func isOn(_ name: String, in environment: [String: String]) -> Bool { environment[name] == "on" }
}
#endif
