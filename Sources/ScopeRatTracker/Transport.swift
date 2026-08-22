import Foundation
import os

/// The HTTP seam, so the pipeline and the flag store can be tested without a
/// server. Production uses `URLSessionTransport`.
protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: Transport {
    private let session: URLSession

    init(timeout: TimeInterval) {
        // Ephemeral: no cookie store, no URL cache. Nothing here benefits from
        // either, and analytics has no business sharing credentials with the
        // host app's own requests.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TransportError.notHTTP
        }
        return (data, http)
    }
}

enum TransportError: Error {
    case notHTTP
}

extension HTTPURLResponse {
    var isSuccess: Bool {
        (200..<300).contains(statusCode)
    }

    /// Whether a failed upload is worth keeping. Rate limits, timeouts, and
    /// server errors pass; the rest — a revoked key, a payload the schema
    /// rejects — will fail identically forever, so retrying only wedges the
    /// queue behind events that can never drain.
    var isRetryable: Bool {
        statusCode == 408 || statusCode == 429 || statusCode >= 500
    }
}

enum Log {
    static let tracker = Logger(subsystem: "ai.scoperat.tracker", category: "tracker")
    static let flags = Logger(subsystem: "ai.scoperat.tracker", category: "flags")
}
