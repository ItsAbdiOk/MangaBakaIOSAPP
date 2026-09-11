import Testing
import Foundation
@testable import MangaBaka

/// The privacy manifest, checked against what the app actually does.
///
/// Apple answers ITMS-91053 on upload, against the binary rather than the
/// source, so an undeclared required-reason API is found at submission time —
/// after the build, after the wait, and with nothing to do but fix it and
/// start again. Cheaper to fail here.
@Suite("Privacy manifest")
struct PrivacyManifestTests {
    private func manifest() throws -> [String: Any] {
        let url = try #require(
            Bundle(for: BundleMarker.self).url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
                ?? Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "the manifest is not in the bundle, which means it would not ship"
        )
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    @Test("UserDefaults is declared, with a reason")
    func userDefaultsIsDeclared() throws {
        // Eleven files use UserDefaults, all of them for the reader's own
        // settings on their own device. CA92.1 is the reason for exactly that.
        let types = try #require(manifest()["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let userDefaults = types.first {
            $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults"
        }
        let entry = try #require(userDefaults, "UserDefaults is used and must be declared")
        let reasons = try #require(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
        #expect(reasons.contains("CA92.1"))
    }

    @Test("Nothing is collected and nothing tracks")
    func collectsNothing() throws {
        let manifest = try manifest()
        #expect((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
    }
}

/// Somewhere to hang `Bundle(for:)` so the test can find its own bundle's
/// resources rather than the host app's.
private final class BundleMarker {}
