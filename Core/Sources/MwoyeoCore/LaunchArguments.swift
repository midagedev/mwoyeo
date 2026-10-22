import Foundation

/// Which of the arguments an app is started with are flags it does not know. A flag has two dashes (`--render`) or is `-h`; one dash and a
/// word (`-AppleLanguages`, `-NSDocumentRevisionsDebugMode`, `-psn_0_123`, the debug launch `-translateImage`) is a defaults override or a
/// launch the system makes, which Cocoa reads and an unknown one is no trouble. Before this an unknown flag started the whole app, on the
/// settings path of the person running it (a `--help` rewrote a settings schema on 2026-10-22); now it ends in a usage text and exit 64.
public enum LaunchArguments {
    /// What a command line that is not understood exits with (`EX_USAGE`).
    public static let usageExit: Int32 = 64

    /// The first of `arguments` (the program's name left out) that is a flag and not one of `known`; nil when every flag is known.
    public static func unknown(in arguments: [String], known: some Collection<String>) -> String? {
        arguments.first { ($0.hasPrefix("--") || $0 == "-h") && !known.contains($0) }
    }
}
