import Foundation
import MwoyeoCore

/// The reader service: one executable, two roles. The role is in this bundle's Info.plist (`MwoyeoReaderRole`), so the same
/// sources build `…reader.lines` and `…reader.docs` (design §4.2).
guard let name = Bundle.main.object(forInfoDictionaryKey: ReaderRole.infoKey) as? String, let role = ReaderRole(rawValue: name) else {
    FileHandle.standardError.write("reader: \(ReaderRole.infoKey) is missing from Info.plist\n".data(using: .utf8)!)
    exit(2)
}

// Exit is the host's decision (`exitWhenIdle`, a kill on a stuck recycle), not the system's: an idle worker is the warm one, and
// its idle exit would only make the host believe it still is. Messages in flight already hold the process. The app gone (quit, force
// quit, crash), its connection is invalidated and `ServiceLifetime` ends the service (App Review 2.4.5(iii), 2026-11-05).
ProcessInfo.processInfo.disableAutomaticTermination("reader worker")
ProcessInfo.processInfo.disableSuddenTermination()

final class Listener: NSObject, NSXPCListenerDelegate {
    let worker: ReaderWorker
    let lifetime = ServiceLifetime()

    init(role: ReaderRole) { worker = ReaderWorker(role: role) }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = ReaderWire.interface()
        connection.exportedObject = worker
        lifetime.hold(connection)
        connection.resume()
        return true
    }
}

let listener = Listener(role: role)
let service = NSXPCListener.service()
service.delegate = listener
service.resume()
