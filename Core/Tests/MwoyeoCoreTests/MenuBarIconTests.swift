import Testing
@testable import MwoyeoCore

/// 2026-10-18 lens-robust: the menu bar icon says when a lens is in error (a capture that failed, a missing grant).
@Suite struct MenuBarIconTests {
    private func icon(paused: Bool = false, visible: Bool = true, lens: Bool = true, attention: Bool = false) -> MenuBarIcon {
        MenuBarIcon(paused: paused, translationsVisible: visible, hasLens: lens, needsAttention: attention)
    }

    @Test func theSymbolFollowsTheState() {
        #expect(icon().symbol == "text.viewfinder")
        #expect(icon(lens: false).symbol == "viewfinder")
        #expect(icon(visible: false).symbol == "eye.slash")
        #expect(icon(paused: true, visible: false).symbol == "pause.circle")
    }

    @Test func aLensInErrorPutsABadgeOnWhateverTheIconShows() {
        #expect(icon(attention: true).badge)
        #expect(icon(visible: false, attention: true).badge)
        #expect(icon(attention: true).symbol == "text.viewfinder")
        #expect(!icon().badge)
    }

    @Test func pausedIsOnPurposeAndShowsNoBadge() {
        #expect(!icon(paused: true, attention: true).badge)
    }

    @Test func aLensNeedsThePersonWhenTheGrantIsMissingOrACaptureIsDown() {
        #expect(MenuBarIcon.needsAttention(permissionGranted: false, enabledLenses: 1, lensesDown: 0))
        #expect(MenuBarIcon.needsAttention(permissionGranted: true, enabledLenses: 2, lensesDown: 1))
        #expect(!MenuBarIcon.needsAttention(permissionGranted: true, enabledLenses: 2, lensesDown: 0))
    }

    @Test func aNewUserWithoutLensesIsNeverNagged() {
        #expect(!MenuBarIcon.needsAttention(permissionGranted: false, enabledLenses: 0, lensesDown: 0))
    }
}
