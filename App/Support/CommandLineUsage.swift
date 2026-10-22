import Foundation
import MwoyeoCore

/// The command line of the app: every flag it reads and the text it prints for one it does not (`LaunchArguments` says which arguments are
/// flags). The flags that run before the app starts are dispatched by `Entry.main`; `--add-region`, `--glide` and `--relaunched` are read by
/// the app that starts. A flag that is in no row opens nothing and touches no settings file, whichever settings path the run would use.
enum CommandLineUsage {
    struct Flag {
        var name: String
        /// What follows the flag, as the usage text shows it.
        var arguments: String
        var summary: String
    }

    /// The flags a person or a script may use, in the order of the usage text. A build for the App Store has the modes that need no files of
    /// this machine: the settings commands and the MCP server.
    static var flags: [Flag] {
        var flags: [Flag] = []
        #if !MAS
        flags += [
            Flag(name: "--render", arguments: "in.png out.png …", summary: "the pipeline on a still image"),
            Flag(name: "--reader-check", arguments: "scenario …", summary: "the reader services, on a scenario"),
            Flag(name: "--capture-ui", arguments: "outdir scenario …", summary: "window captures and logic checks"),
        ]
        #endif
        flags += [
            Flag(name: "--mcp", arguments: "", summary: "an MCP server on stdin and stdout (the translation log and each app's memory, for an agent)"),
            Flag(name: "--settings-path", arguments: "", summary: "print where settings.json is (MWOYEO_SETTINGS_FILE names another)"),
            Flag(name: "--settings-schema", arguments: "", summary: "print the schema of settings.json"),
            Flag(name: "--check-settings", arguments: "[path]", summary: "print each issue of a settings file, or ok; exit 1 when there are issues"),
        ]
        #if !MAS
        flags += [
            Flag(name: "--add-region", arguments: "x,y,w,h", summary: "open the app with a lens at that place (global points, top-left origin)"),
            Flag(name: "--glide", arguments: "dx,dy,seconds,after;…", summary: "with --add-region: move that lens by script"),
        ]
        #endif
        return flags
    }

    /// Every flag the app reads, the ones the usage text leaves out too (`--relaunched <pid>` is the app started again by "Restart Mwoyeo").
    static var known: [String] { flags.map(\.name) + ["--relaunched"] }

    /// The first flag of the command line that no row has, or nil.
    static func unknown(in arguments: [String] = Array(CommandLine.arguments.dropFirst())) -> String? {
        LaunchArguments.unknown(in: arguments, known: known)
    }

    /// What is printed to stderr for `flag`.
    static func text(for flag: String) -> String {
        let width = flags.map { ($0.name + ($0.arguments.isEmpty ? "" : " " + $0.arguments)).count }.max() ?? 0
        let rows = flags.map { f -> String in
            let head = f.name + (f.arguments.isEmpty ? "" : " " + f.arguments)
            return "  " + head.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + f.summary
        }
        return (["Mwoyeo: unknown option \(flag)", "usage: Mwoyeo [flag]", "  With no flag it opens the app."] + rows).joined(separator: "\n") + "\n"
    }

    /// Prints the usage and exits, before anything of the app (its settings, its windows) exists.
    static func refuse(_ flag: String) -> Never {
        FileHandle.standardError.write(Data(text(for: flag).utf8))
        exit(LaunchArguments.usageExit)
    }
}
