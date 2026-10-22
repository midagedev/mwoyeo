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

/// Round text2, F14: with the menu bar item hidden, reopening the app is the way in.
@Suite struct ReopenWindowTests {
    @Test func reopeningAnAppThatIsSetUpOpensThePanelAsAWindow() {
        #expect(ReopenWindow.shown(completedWelcome: true, screenAccess: true) == .menu)
    }

    @Test func reopeningBeforeTheWelcomeIsDoneOrTheGrantIsThereOpensTheWelcome() {
        #expect(ReopenWindow.shown(completedWelcome: false, screenAccess: true) == .welcome)
        #expect(ReopenWindow.shown(completedWelcome: true, screenAccess: false) == .welcome)
        #expect(ReopenWindow.shown(completedWelcome: false, screenAccess: false) == .welcome)
    }
}

/// Round text2, F3: a flag the app does not know ends in usage, not in the app.
@Suite struct LaunchArgumentsTests {
    private static let known = ["--render", "--mcp", "--relaunched", "--add-region"]

    @Test func anUnknownFlagIsFoundWhereverItStands() {
        #expect(LaunchArguments.unknown(in: ["--help"], known: Self.known) == "--help")
        #expect(LaunchArguments.unknown(in: ["-h"], known: Self.known) == "-h")
        #expect(LaunchArguments.unknown(in: ["--relaunched", "123", "--bogus"], known: Self.known) == "--bogus")
        #expect(LaunchArguments.unknown(in: ["--"], known: Self.known) == "--")
    }

    @Test func theAppsOwnFlagsAndTheSystemsLaunchArgumentsAreNoTrouble() {
        #expect(LaunchArguments.unknown(in: [], known: Self.known) == nil)
        #expect(LaunchArguments.unknown(in: ["--relaunched", "123"], known: Self.known) == nil)
        #expect(LaunchArguments.unknown(in: ["--add-region", "1,2,3,4"], known: Self.known) == nil)
        #expect(LaunchArguments.unknown(in: ["-AppleLanguages", "(ko)", "-NSDocumentRevisionsDebugMode", "YES", "-psn_0_4242", "-translateImage", "/tmp/a.png"], known: Self.known) == nil)
        #expect(LaunchArguments.unknown(in: ["/tmp/a file.png", "-1,2,3,4", "-help-me"], known: Self.known) == nil)
    }

    @Test func usageExitsWithEXUSAGE() {
        #expect(LaunchArguments.usageExit == 64)
    }
}
