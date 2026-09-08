import Foundation

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
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Outcome)?
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func setHandler(_ handler: @escaping @Sendable (URLRequest) -> Outcome) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        recorded = []
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        recorded = []
    }

    /// Every request the client actually issued, in order.
    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let handler = Self.handler
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
