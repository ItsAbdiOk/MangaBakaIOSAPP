import Foundation
import Testing

enum Fixture {
    /// Loads a bundled JSON fixture, failing loudly rather than returning empty
    /// data, so a missing fixture can never masquerade as a passing test.
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle(for: BundleToken.self)
            .url(forResource: name, withExtension: "json")
        else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    enum FixtureError: Error, CustomStringConvertible {
        case missing(String)
        var description: String {
            switch self {
            case let .missing(name): "Fixture \(name).json is not in the test bundle."
            }
        }
    }
}

private final class BundleToken {}
