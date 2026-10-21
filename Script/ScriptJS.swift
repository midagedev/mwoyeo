import Foundation
import JavaScriptCore
import MwoyeoCore

/// The JavaScript of the rewrite rules (docs/design/rewrite-rules.md §2, §3, §5). Every job runs in a fresh global object of the one virtual
/// machine: no state is kept between lines. The global has the language and nothing else: no timers, no network, no files (JavaScriptCore ships none; its
/// `console` only logs), and no `Date` and no `Math.random`, because the result of a script must be a function of its inputs (the cache of a translation is
/// keyed by what the chain's rewrites are, `RewritePlan.fingerprint`).
enum ScriptJS {
    private static let machine = JSVirtualMachine()!

    /// Made before the first job, so the first job is not charged for the machine and for compiling the first regular expression.
    static func warm() {
        let box = Sandbox()
        _ = box.replace(pattern: "a+", replacement: "b", in: "aaa")
    }

    static func run(_ job: ScriptJob) -> ScriptReply {
        let box = Sandbox()
        switch job.kind {
        case .regex:
            let (text, failure) = box.replace(pattern: job.pattern, replacement: job.replacement, in: job.text)
            return ScriptReply(id: job.id, pid: 0, text: text, failure: failure)
        case .before, .after:
            let (text, failure) = box.call(job)
            return ScriptReply(id: job.id, pid: 0, text: text, failure: failure)
        case .check:
            let (issues, defines) = box.check(job)
            return ScriptReply(id: job.id, pid: 0, issues: issues, defines: defines)
        }
    }

    /// One fresh global object. Its exceptions are caught in `caught` (a box the handler holds, so that no cycle joins context, handler and value).
    private final class Sandbox {
        private final class Caught { var value: JSValue? }

        let context: JSContext
        private let caught = Caught()

        init() {
            context = JSContext(virtualMachine: ScriptJS.machine)!
            let box = caught
            context.exceptionHandler = { _, exception in box.value = exception }
            _ = context.evaluateScript("delete globalThis.Date; delete Math.random;")
        }

        deinit { context.exceptionHandler = nil }

        /// The exception since the last call, cleared.
        private func take() -> JSValue? { defer { caught.value = nil }; return caught.value }

        private func number(_ exception: JSValue, _ key: String) -> Int? {
            guard exception.isObject, let n = exception.objectForKeyedSubscript(key), n.isNumber else { return nil }
            return Int(n.toInt32())
        }

        /// A throw as the failure it is: JavaScriptCore's line, and the column of a runtime throw (a syntax error has a line only).
        private func failure(_ exception: JSValue, message: String? = nil) -> RewriteFailure {
            RewriteFailure(message ?? exception.toString() ?? "an error", line: number(exception, "line"), column: number(exception, "column"))
        }

        /// A regex row (§2): flags `gu`, `$1` … in the replacement, the JavaScript of `String.prototype.replace`.
        func replace(pattern: String, replacement: String, in text: String) -> (String?, RewriteFailure?) {
            let run = context.evaluateScript("(function (p, r, t) { return t.replace(new RegExp(p, 'gu'), r); })")
            let value = run?.call(withArguments: [pattern, replacement, text])
            if let exception = take() { return (nil, failure(exception)) }
            return result(value, function: "regex", input: text)
        }

        /// The script's `before(text, ctx)` or `after(src, text, ctx)` (§3). A script that does not define it leaves the text as it is.
        func call(_ job: ScriptJob) -> (String?, RewriteFailure?) {
            _ = context.evaluateScript(job.source, withSourceURL: URL(string: "mwoyeo-script")!)
            if let exception = take() { return (nil, failure(exception)) }
            let name = job.kind.rawValue
            guard defined(name), let function = context.evaluateScript(name) else { return (job.text, nil) }
            let ctx: [String: Any] = ["app": job.context.app, "profile": job.context.profile, "source": job.context.source, "target": job.context.target]
            let value = function.call(withArguments: job.kind == .before ? [job.text, ctx] : [job.src, job.text, ctx])
            if let exception = take() { return (nil, failure(exception)) }
            return result(value, function: name, input: job.text)
        }

        /// A function's return as text, or the failure it is: not a string (§5), or longer than 4 × the input + 200 (asked of its length before it is converted).
        private func result(_ value: JSValue?, function: String, input: String) -> (String?, RewriteFailure?) {
            guard let value, value.isString else {
                let typeOf = context.evaluateScript("(function (v) { return v === null ? 'null' : typeof v; })")
                let type = typeOf?.call(withArguments: [value ?? NSNull()])?.toString() ?? "nothing"
                return (nil, RewriteFailure(RewriteText.notText(function, type)))
            }
            if RewriteLimits.replyTooLong(input: input.utf16.count, output: Int(value.objectForKeyedSubscript("length")?.toInt32() ?? 0)) {
                return (nil, RewriteFailure(RewriteText.replyTooLong(function)))
            }
            return (value.toString(), nil)
        }

        private func defined(_ name: String) -> Bool { context.evaluateScript("typeof \(name) === 'function'")?.toBool() ?? false }

        /// Check time (§2, §3): each pattern compiled and never run; the script parsed (`JSCheckScriptSyntax`, which runs nothing), then its top level run once
        /// in this fresh global to see which of the two functions it defines.
        func check(_ job: ScriptJob) -> ([RewriteIssue], [RewriteStage]) {
            var issues: [RewriteIssue] = []
            let compile = context.evaluateScript("(function (p) { new RegExp(p, 'gu'); })")
            for p in job.patterns {
                _ = compile?.call(withArguments: [p.pattern])
                if let exception = take() {
                    let message = exception.isObject ? exception.objectForKeyedSubscript("message")?.toString() : nil
                    issues.append(RewriteIssue(item: p.item, message: message ?? exception.toString() ?? "an error"))
                }
            }
            guard !job.source.isEmpty else { return (issues, []) }
            var thrown: JSValueRef?
            let source = JSStringCreateWithUTF8CString(job.source)
            defer { JSStringRelease(source) }
            guard JSCheckScriptSyntax(context.jsGlobalContextRef, source, nil, 1, &thrown) else {
                let exception = thrown.flatMap { JSValue(jsValueRef: $0, in: context) }
                issues.append(RewriteIssue(item: RewriteIssue.script, exception.map { failure($0) } ?? RewriteFailure("a syntax error")))
                return (issues, [])
            }
            _ = context.evaluateScript(job.source, withSourceURL: URL(string: "mwoyeo-script")!)
            if let exception = take() {
                issues.append(RewriteIssue(item: RewriteIssue.script, failure(exception)))
                return (issues, [])
            }
            let defines = RewriteStage.allCases.filter { defined($0.rawValue) }
            if defines.isEmpty {
                issues.append(RewriteIssue(item: RewriteIssue.script, message: "the script defines neither before(line, ctx) nor after(src, dst, ctx)"))
            }
            return (issues, defines)
        }
    }
}
