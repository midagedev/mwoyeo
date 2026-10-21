import Foundation
import MwoyeoCore

/// The script service (docs/design/rewrite-rules.md §5): runs the regex rows and the scripts of the rewrite rules in JavaScriptCore, one job at a
/// time, in a fresh global object per job. It reads no file, opens no connection and keeps nothing between jobs. The time limit is the app's
/// (`App/Script/ScriptConnection.swift` kills this process over it): `JSContextGroupSetExecutionTimeLimit` is private API.

// Exit is the host's decision (`exitWhenIdle` after its idle time, a kill over the limit, the app quitting), as in the reader services.
ProcessInfo.processInfo.disableAutomaticTermination("script worker")
ProcessInfo.processInfo.disableSuddenTermination()

final class Listener: NSObject, NSXPCListenerDelegate {
    let worker = ScriptWorker()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = ScriptWire.interface()
        connection.exportedObject = worker
        connection.resume()
        return true
    }
}

let listener = Listener()
let service = NSXPCListener.service()
service.delegate = listener
service.resume()
