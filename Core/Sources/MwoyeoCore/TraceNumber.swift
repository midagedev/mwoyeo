import CoreGraphics

/// Numbers in trace lines. A trace line is made only when the trace is on, so a trap in one is a crash only a gate that traces can see:
/// the vn render of p6 ended rc=133 with `MWOYEO_TRACE=1` on `Int(_:)` of a rect that was `.null` (r1-reader-service found it,
/// r3-docs-xpc fixed it).
public enum TraceNumber {
    /// `v` as a whole number of pixels for a trace line. A value that is not finite (an empty box is `CGRect.null`, whose origin is
    /// infinite) is 0, and a huge one is cut at ±1e9: `Int(_:)` traps on both.
    public static func px(_ v: CGFloat) -> Int { v.isFinite ? Int(max(-1e9, min(1e9, v))) : 0 }
}
