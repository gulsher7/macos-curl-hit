import Foundation

/// One completed request attempt.
struct HitResult: Identifiable, Sendable {
    let id = UUID()
    let index: Int
    /// Which parallelism level this hit ran at. In a ramp this is the stage key.
    let stage: Int
    let statusCode: Int          // 0 means the request never got a response
    let seconds: Double
    let startedAt: Date
    let byteCount: Int
    let body: String
    let responseHeaders: [(String, String)]
    let errorText: String?

    var ok: Bool { statusCode >= 200 && statusCode < 400 }
    var isRateLimited: Bool { statusCode == 429 }
    var isServerError: Bool { statusCode >= 500 }
    var isTransportFailure: Bool { statusCode == 0 }
    var statusLabel: String { statusCode == 0 ? "ERR" : String(statusCode) }
    var milliseconds: Double { seconds * 1000 }
}

/// Mirrors curl's `-L` / `-k` behaviour, which `URLSession` does not do by default.
private final class EngineDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let followRedirects: Bool
    let insecure: Bool

    init(followRedirects: Bool, insecure: Bool) {
        self.followRedirects = followRedirects
        self.insecure = insecure
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // curl only follows when -L is given; otherwise the 3xx itself is the result.
        completionHandler(followRedirects ? request : nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard insecure,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// Sends a parsed request repeatedly. Pure `URLSession`, so it runs fine inside the
/// App Sandbox (no subprocess, no bundled curl).
final class HTTPEngine: @unchecked Sendable {
    private let session: URLSession
    private let delegate: EngineDelegate
    private let maxBodyChars = 200_000

    init(request: ParsedRequest, timeout: Double, maxConnections: Int = 1) {
        let config = URLSessionConfiguration.ephemeral   // nothing cached, nothing persisted
        config.timeoutIntervalForRequest = request.timeout ?? timeout
        config.timeoutIntervalForResource = (request.timeout ?? timeout) + 5
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData

        // Without this, URLSession quietly caps concurrent connections to one host
        // at 6, and a parallel run above that would queue instead of overlapping.
        config.httpMaximumConnectionsPerHost = max(1, maxConnections)

        self.delegate = EngineDelegate(followRedirects: request.followRedirects,
                                       insecure: request.insecure)
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func invalidate() { session.finishTasksAndInvalidate() }

    func send(_ request: URLRequest, index: Int, stage: Int) async -> HitResult {
        let startedAt = Date()
        let clock = DispatchTime.now()

        func elapsed() -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - clock.uptimeNanoseconds) / 1_000_000_000
        }

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            var text = String(data: data, encoding: .utf8) ?? "<\(data.count) bytes of binary data>"
            if text.count > maxBodyChars {
                text = String(text.prefix(maxBodyChars)) + "\n\n… truncated (\(data.count) bytes total)"
            }
            let headers = (http?.allHeaderFields as? [String: String] ?? [:])
                .sorted { $0.key.lowercased() < $1.key.lowercased() }
                .map { ($0.key, $0.value) }

            return HitResult(index: index,
                             stage: stage,
                             statusCode: http?.statusCode ?? 0,
                             seconds: elapsed(),
                             startedAt: startedAt,
                             byteCount: data.count,
                             body: text,
                             responseHeaders: headers,
                             errorText: nil)
        } catch {
            return HitResult(index: index,
                             stage: stage,
                             statusCode: 0,
                             seconds: elapsed(),
                             startedAt: startedAt,
                             byteCount: 0,
                             body: "",
                             responseHeaders: [],
                             errorText: (error as NSError).localizedDescription)
        }
    }
}
