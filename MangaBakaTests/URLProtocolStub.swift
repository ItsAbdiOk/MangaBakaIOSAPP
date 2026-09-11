import Foundation
import Testing

/// Deterministic HTTP for tests. No real network, no flakiness, and it counts
/// requests so the request-budget test can assert against a real number.
final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    struct Response {
        let statusCode: Int
        let body: Data
        let headers: [String: String]

        init(statusCode: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
            self.statusCode = statusCode
            self.body = body
            self.headers = headers
        }
    }

    /// What the stub should do for the next request.
    enum Outcome {
        case respond(Response)
        case fail(URLError)
    }

    private static let lock = NSLock()
    /// Handlers and recorded requests, per test.
    ///
    /// They were one global pair. Swift Testing runs suites in parallel, so
    /// two suites using the stub at once saw each other's handlers and
    /// requests — "Multi-select filters are sent as repeated keys" once found
    /// a MangaUpdates request from the schedule suite as its first request.
    /// `.serialized` only orders tests within a suite. Now each test's
    /// session stamps the test's id on every request, and the handler and
    /// the record are looked up by it; code outside any test (a suite-level
    /// helper) falls back to a shared bucket, as before.
    nonisolated(unsafe) private static var handlers: [String: @Sendable (URLRequest) -> Outcome] = [:]
    nonisolated(unsafe) private static var recorded: [String: [URLRequest]] = [:]
    private static let header = "X-MangaBaka-Test"
    private static let shared = "shared"

    private static var currentKey: String {
        Test.current.map { String(describing: $0.id) } ?? shared
    }

    static func setHandler(_ handler: @escaping @Sendable (URLRequest) -> Outcome) {
        lock.lock(); defer { lock.unlock() }
        handlers[currentKey] = handler
        recorded[currentKey] = []
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handlers[currentKey] = nil
        recorded[currentKey] = nil
    }

    /// Every request the client actually issued, in order.
    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded[currentKey] ?? []
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        configuration.httpAdditionalHeaders = [header: currentKey]
        return URLSession(configuration: configuration)
    }

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.value(forHTTPHeaderField: Self.header) ?? Self.shared
        Self.lock.lock()
        Self.recorded[key, default: []].append(request)
        let handler = Self.handlers[key]
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        switch handler(request) {
        case let .fail(error):
            client?.urlProtocol(self, didFailWithError: error)

        case let .respond(response):
            guard let url = request.url,
                  let http = HTTPURLResponse(
                      url: url,
                      statusCode: response.statusCode,
                      httpVersion: "HTTP/1.1",
                      headerFields: response.headers
                  )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
