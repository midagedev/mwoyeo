import Foundation
import MwoyeoCore

/// What a lens tells the translator about the document under it (design §2, §8). RAM only.
///
/// `screen`, `above` and `below` are screen text: they are handed to the translator and to nothing else (no log, no stats, no
/// file). The pair and the engine are not here: `TranslationService` fills them from its own settings, so they can never disagree
/// with the engine that gets the request.
struct LensContext: Equatable, Sendable {
    /// The app under the lens (`AppModel.app(ofWindow:)`).
    var bundleID: String
    var appName: String
    /// `CategoryDomain.word(for:)` of the app's `LSApplicationCategoryType` (`AppModel.category(ofApp:)`); nil when it has none.
    var categoryWord: String?
    /// The normalised window title, once `TitleConfirmer` confirmed it (the same title on 3 reads over at least 1 s); nil before
    /// the first read. `WindowAnchor.title` is fixed when the lens is anchored, so it is never used here.
    var confirmedTitle: String?
    /// The lens (region) reading this document: two lenses on one app keep a thread each.
    var lensID: String
    /// Every line the lens has on screen, overscan included, for the test "is this a wholly different text" (design §2).
    var screen: [String] = []
    /// The lines right above the batch on screen and right below it, in reading order (`ContextNeighbours`).
    var above: [String] = []
    var below: [String] = []

    /// The app and nothing of the document: what "memory only" needs (the card's app name and category word). No title, no lens, no
    /// screen text, so the thread key is the app's, the pair's and the engine's alone and the screen never reaches RAM here.
    var appOnly: LensContext {
        LensContext(bundleID: bundleID, appName: appName, categoryWord: categoryWord, confirmedTitle: nil, lensID: "")
    }

    /// This context for one batch: the same window with the batch's surroundings.
    func around(_ batch: [String], lines: [ContextNeighbours.Line]) -> LensContext {
        var c = self
        let n = ContextNeighbours.around(batch: batch, lines: lines)
        c.screen = lines.map(\.source)
        c.above = n.above
        c.below = n.below
        return c
    }
}
