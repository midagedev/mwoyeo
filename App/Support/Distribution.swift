import Foundation
import MwoyeoCore

/// Which flavour of the one target this is. The Mac App Store build (`-configuration MAS`, Swift condition `MAS`) leaves out what
/// that store does not allow: update checks and the install count, the debug hooks, the command engine (docs/app-store/).
/// Code that cannot be left out by `#if MAS` (it is in a package, or a value is passed on) reads `isAppStore`.
enum Distribution {
    #if MAS
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif

    /// The engines this build runs (`EngineReach`): the App Store build keeps the screen's text on this Mac.
    static let engineReach: EngineReach = isAppStore ? .thisMac : .anywhere

    /// Linked from the About view in both flavours (guideline 5.1.1(i)).
    static let privacyPolicy = URL(string: "https://github.com/midagedev/mwoyeo/blob/main/docs/PRIVACY.md")!
}
