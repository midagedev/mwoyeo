import AppKit
import Observation

#if MAS
/// The Mac App Store distributes updates (guideline 2.4.5(vii)): this build compiles no update check, banner or install count.
/// What the About view reads stays, so it is one view in both flavours.
enum Updates {
    static let repository = URL(string: "https://github.com/midagedev/mwoyeo")!
    static let issues = repository.appending(path: "issues")
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
}
#else
/// Asks GitHub for the latest release. Sends nothing but the request itself: no screen text, no identifiers.
///
/// The check downloads a small file attached to every release, so GitHub's download count of it says how many Macs
/// checked. Two more files are downloaded at most once each — one ever, one per calendar month — so their counts are
/// installs and monthly active installs. This Mac remembers what it already sent; nothing identifies it.
@MainActor
@Observable
final class Updates {
    static let shared = Updates()

    enum State: Equatable {
        case idle, checking, upToDate, failed
        case available(version: String, page: URL)
    }

    private(set) var state = State.idle

    static let repository = URL(string: "https://github.com/midagedev/mwoyeo")!
    static let releases = repository.appending(path: "releases")
    static let issues = repository.appending(path: "issues")
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    /// Installed with `brew install midagedev/tap/mwoyeo`: update the same way, or brew loses track of the app.
    static let viaHomebrew = ["/opt/homebrew/Caskroom/mwoyeo", "/usr/local/Caskroom/mwoyeo"]
        .contains { FileManager.default.fileExists(atPath: $0) }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let lastCheckKey = "lastUpdateCheck"
    /// Counted only while automatic checks are on; a check from the button alone counts nothing.
    @ObservationIgnored private var counts = false
    private static let latestAsset = repository.appending(path: "releases/latest/download")

    func check() async {
        state = .checking
        do {
            let (latest, page) = try await latestRelease()
            state = Self.isNewer(latest, than: Self.version) ? .available(version: latest, page: page) : .upToDate
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            if counts { await countOnce() }
        } catch {
            state = .failed
        }
    }

    /// The version and page from the latest release's `version.json`, or from the API for releases without one.
    private func latestRelease() async throws -> (String, URL) {
        struct Asset: Decodable { let version: String; let page: URL }
        if let data = try? await Self.get(Self.latestAsset.appending(path: "version.json")),
           let a = try? JSONDecoder().decode(Asset.self, from: data) {
            return (a.version, a.page)
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/midagedev/mwoyeo/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        struct Release: Decodable { let tag_name: String; let html_url: URL }
        let release = try JSONDecoder().decode(Release.self, from: try await Self.get(request))
        return (release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name, release.html_url)
    }

    /// `install.json` once ever, `month.json` once a calendar month; remembered only after GitHub served them.
    private func countOnce() async {
        let d = UserDefaults.standard
        if !d.bool(forKey: "countedInstall"), (try? await Self.get(Self.latestAsset.appending(path: "install.json"))) != nil {
            d.set(true, forKey: "countedInstall")
        }
        let month = Date().formatted(.iso8601.year().month())
        if d.string(forKey: "countedMonth") != month, (try? await Self.get(Self.latestAsset.appending(path: "month.json"))) != nil {
            d.set(month, forKey: "countedMonth")
        }
    }

    private static func get(_ url: URL) async throws -> Data { try await get(URLRequest(url: url)) }

    private static func get(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    /// Checks once a day while `enabled`, starting now if the last check is a day old.
    func schedule(enabled: Bool) {
        timer?.invalidate()
        timer = nil
        counts = enabled
        guard enabled else { return }
        let due = { [lastCheckKey] in
            (UserDefaults.standard.object(forKey: lastCheckKey) as? Date).map { Date().timeIntervalSince($0) > 86_400 } ?? true
        }
        if due() { Task { await check() } }
        let t = Timer(timeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in if due() { await Updates.shared.check() } }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }
}
#endif
