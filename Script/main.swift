import Foundation
import MwoyeoCore

/// The script service (docs/design/rewrite-rules.md §5): runs the regex rows and the scripts of the rewrite rules in JavaScriptCore, one job at a
/// time, in a fresh global object per job. It reads no file, opens no connection and keeps nothing between jobs. The time limit is the app's
/// (`App/Script/ScriptConnection.swift` kills this process over it): `JSContextGroupSetExecutionTimeLimit` is private API.

// Exit is the host's decision (`exitWhenIdle` after its idle time, a kill over the limit), as in the reader services; the app gone, its
// connection is invalidated and `ServiceLifetime` ends the service (App Review 2.4.5(iii), 2026-11-05).
ProcessInfo.processInfo.disableAutomaticTermination("script worker")
ProcessInfo.processInfo.disableSuddenTermination()

final class Listener: NSObject, NSXPCListenerDelegate {
    let worker = ScriptWorker()
    let lifetime = ServiceLifetime()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = ScriptWire.interface()
        connection.exportedObject = worker
        lifetime.hold(connection)
        connection.resume()
        return true
    }
}

let listener = Listener()
let service = NSXPCListener.service()
service.delegate = listener
service.resume()
