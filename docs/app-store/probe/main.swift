import Foundation
import CoreGraphics
import Carbon.HIToolbox
import Security
import AppKit

func line(_ s: String) { print(s); fflush(stdout) }

let realHome = String(cString: getpwuid(getuid()).pointee.pw_dir)
line("sandboxed env: APP_SANDBOX_CONTAINER_ID=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "nil")")
line("NSHomeDirectory = \(NSHomeDirectory())")
line("real home       = \(realHome)")
let expanded = ("~/Documents/Mwoyeo" as NSString).expandingTildeInPath
line("expandingTildeInPath(~/Documents/Mwoyeo) = \(expanded)")

// 1 write to real ~/Documents
let target = "\(realHome)/Documents/mas-probe-\(getpid())"
do { try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true); line("WRITE real ~/Documents: ALLOWED"); try? FileManager.default.removeItem(atPath: target) }
catch { line("WRITE real ~/Documents: DENIED (\((error as NSError).code) \(error.localizedDescription))") }
// write into container path
do { try FileManager.default.createDirectory(atPath: expanded + "-probe", withIntermediateDirectories: true); line("WRITE container Documents: ALLOWED"); try? FileManager.default.removeItem(atPath: expanded + "-probe") }
catch { line("WRITE container Documents: DENIED \(error)") }
// read other file in real Documents listing
line("LIST real ~/Documents: \((try? FileManager.default.contentsOfDirectory(atPath: "\(realHome)/Documents"))?.count.description ?? "DENIED")")

// 2 spawn
func spawn(_ exe: String, _ args: [String]) {
    var child: pid_t = 0
    let argv = ([exe] + args).map { strdup($0) } + [nil]
    defer { for p in argv { free(p) } }
    let rc = posix_spawn(&child, exe, nil, nil, argv, environ)
    if rc != 0 { line("SPAWN \(exe): posix_spawn rc=\(rc) (\(String(cString: strerror(rc))))"); return }
    var st: Int32 = 0
    waitpid(child, &st, 0)
    let code = (st >> 8) & 0xff
    line("SPAWN \(exe): started, exit=\(code)\(st & 0x7f != 0 ? " signal=\(st & 0x7f)" : "")")
}
spawn("/usr/bin/true", [])
spawn("/bin/echo", ["hi"])
spawn("/usr/bin/python3", ["-c", "print('py-ok')"])
spawn("/opt/homebrew/bin/python3.12", ["-c", "print('brew-py-ok')"])
spawn("/opt/homebrew/bin/actionlint", ["-version"])
spawn("/usr/local/bin/docker-credential-osxkeychain", ["version"])
let script = "\(realHome)/.mas-probe-script.sh"  // outside sandbox; created by the harness script before run
spawn(script, [])
spawn("/private/tmp/mas-probe/script.sh", [])

// 3 window list
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let named = list.filter { ($0[kCGWindowName as String] as? String)?.isEmpty == false }.count
let others = list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) != getpid() }.count
line("CGWindowList: \(list.count) windows, \(others) others, \(named) with a title, \(list.filter { ($0[kCGWindowOwnerName as String] as? String)?.isEmpty == false }.count) with owner name")
line("CGPreflightScreenCaptureAccess (passive) = \(CGPreflightScreenCaptureAccess())")
line("frontmostApplication = \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")

// 4 hotkey
var ref: EventHotKeyRef?
let id = EventHotKeyID(signature: OSType(0x4D57_5941), id: 1)
let hk = RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
line("RegisterEventHotKey ⌃⌥L = \(hk) (0 = noErr)")
if let ref { UnregisterEventHotKey(ref) }

// 5 keychain (legacy file keychain, no data-protection flag, as KeychainSecrets does)
let svc = "dev.midagedev.masprobe.\(getpid())"
let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: svc, kSecAttrAccount as String: "a", kSecAttrSynchronizable as String: false]
var add = q; add[kSecValueData as String] = Data("secret".utf8); add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
let a = SecItemAdd(add as CFDictionary, nil)
var rq = q; rq[kSecReturnData as String] = true; rq[kSecMatchLimit as String] = kSecMatchLimitOne
var out: CFTypeRef?
let r = SecItemCopyMatching(rq as CFDictionary, &out)
line("KEYCHAIN add=\(a) read=\(r) value=\((out as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "nil")")
_ = SecItemDelete(q as CFDictionary)

// 6 network to localhost
let sem = DispatchSemaphore(value: 0)
var url = URL(string: "http://127.0.0.1:18080/")!
URLSession.shared.dataTask(with: url) { d, resp, err in
    line("NET http://127.0.0.1:18080: \(resp.map { "HTTP \(($0 as! HTTPURLResponse).statusCode)" } ?? "ERR \(err.map { ($0 as NSError).code.description + " " + $0.localizedDescription } ?? "?")")")
    sem.signal()
}.resume()
_ = sem.wait(timeout: .now() + 8)
url = URL(string: "https://example.com/")!
URLSession.shared.dataTask(with: url) { d, resp, err in
    line("NET https://example.com: \(resp.map { "HTTP \(($0 as! HTTPURLResponse).statusCode)" } ?? "ERR \(err.map { ($0 as NSError).code.description + " " + $0.localizedDescription } ?? "?")")")
    sem.signal()
}.resume()
_ = sem.wait(timeout: .now() + 8)
