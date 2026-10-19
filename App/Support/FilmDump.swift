#if !MAS
import CoreGraphics
import Foundation
import MwoyeoCore

/// `MWOYEO_FILM_DUMP=<capture|erase|predict|scroll>[,…]`: the geometry the film draws from the app's own run, one JSON record a line on
/// stderr as `[film] <kind> {…}` (tools/film/DESIGN.md, hooks H1-H4; `tools/film/plates/plate_json.py` collects them). Unset, a hook costs
/// one set lookup and builds nothing. Not in the App Store build.
enum FilmDump {
    private static let kinds = Set((ProcessInfo.processInfo.environment["MWOYEO_FILM_DUMP"] ?? "").split(separator: ",").map(String.init))

    static func on(_ kind: String) -> Bool { kinds.contains(kind) }

    static func emit(_ kind: String, _ record: () -> [String: Any]) {
        guard on(kind) else { return }
        let object = record()
        guard JSONSerialization.isValidJSONObject(object), let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        FileHandle.standardError.write(Data("[film] \(kind) ".utf8) + json + Data("\n".utf8))
    }

    static func box(_ r: CGRect) -> [CGFloat] { [r.minX, r.minY, r.width, r.height] }
    static func box(_ r: PixelRect) -> [Int] { [r.x, r.y, r.width, r.height] }
    static func boxOrNull(_ r: PixelRect?) -> Any { r.map { box($0) as Any } ?? NSNull() }
}
#endif
