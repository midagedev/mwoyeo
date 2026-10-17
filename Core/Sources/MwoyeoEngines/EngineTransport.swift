import Foundation

/// The one `URLSession` every engine request goes through.
///
/// - `.ephemeral`, no cache, no cookies, no credential storage: the screen text we send and the translations we get
///   back never touch the disk, and a provider cannot tag us with a cookie.
/// - Nothing else is tuned. The default session speaks HTTP/2 and keeps connections alive, and that is the point of
///   sharing one: the second batch to a provider skips the DNS lookup and the TLS handshake (most of a cloud engine's
///   0.9 to 1.4 s for a three-line batch is network).
/// - `timeoutIntervalForRequest` is only the silence limit. The real limit is the caller's deadline; a cancelled
///   caller cancels the HTTP task.
enum EngineTransport {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.timeoutIntervalForRequest = 30
        return URLSession(configuration: c)
    }()

    /// Hands each finished task's metrics to the client's hook (the live test reads `isReusedConnection` from it).
    private final class MetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let hook: @Sendable (URLSessionTaskMetrics) -> Void
        init(_ hook: @escaping @Sendable (URLSessionTaskMetrics) -> Void) { self.hook = hook }
        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            hook(metrics)
        }
    }

    struct Reply {
        var status: Int
        var data: Data
        var retryAfter: Double?
    }

    /// Any status is a reply; only a transport failure throws. `scrub` cleans the message of the failure.
    static func send(_ request: URLRequest, metrics: (@Sendable (URLSessionTaskMetrics) -> Void)?,
                     scrub: Scrubber) async throws(EngineError) -> Reply {
        do {
            let (data, response) = try await session.data(for: request, delegate: metrics.map(MetricsDelegate.init))
            guard let http = response as? HTTPURLResponse else { throw EngineError.network("not an HTTP answer") }
            return Reply(status: http.statusCode, data: data,
                         retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) })
        } catch let e as EngineError {
            throw e
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { throw .cancelled }
            throw .network(scrub((error as? URLError).map(describe) ?? "request failed"))
        }
    }

    /// `URLError.localizedDescription` can carry the failing URL; keep the code's meaning only.
    private static func describe(_ e: URLError) -> String {
        switch e.code {
        case .timedOut: "timed out"
        case .notConnectedToInternet: "no internet connection"
        case .cannotFindHost, .dnsLookupFailed: "host not found"
        case .cannotConnectToHost: "connection refused"
        case .networkConnectionLost: "connection lost"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: "TLS failed"
        case .appTransportSecurityRequiresSecureConnection: "blocked: plain http needs a local address"
        default: "network error \(e.code.rawValue)"
        }
    }
}
