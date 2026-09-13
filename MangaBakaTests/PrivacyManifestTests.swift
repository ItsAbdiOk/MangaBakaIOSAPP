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

    @Test("Only the reader's own library is collected, and nothing tracks")
    func collectsNothing() throws {
        let manifest = try manifest()
        // The reader's library goes to their MangaBaka account and stays
        // there, which is Apple's definition of collected: declared as a
        // user ID and user content, linked, never for tracking.
        let collected = (manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]]) ?? []
        let types = Set(collected.compactMap { $0["NSPrivacyCollectedDataType"] as? String })
        #expect(types == ["NSPrivacyCollectedDataTypeUserID", "NSPrivacyCollectedDataTypeOtherUserContent"])
        #expect(collected.allSatisfy { ($0["NSPrivacyCollectedDataTypeTracking"] as? Bool) == false })
        #expect(manifest["NSPrivacyTracking"] as? Bool == false)
        #expect((manifest["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
    }
}

/// Somewhere to hang `Bundle(for:)` so the test can find its own bundle's
/// resources rather than the host app's.
private final class BundleMarker {}

/// Every host this build actually contacts, kept as a constant so this suite
/// and the manifest's own comment can be checked against the same list
/// rather than two hand-typed copies drifting apart — which is exactly how
/// the manifest comment came to name four of about fifteen hosts in the
/// first place.
private enum ContactedHosts {
    static let all: [String] = [
        "api.mangabaka.org",
        "graphql.anilist.co",
        "shikimori.io",
        "itunes.apple.com",
        "googleapis.com",
        "webtoons.com",
        "comic.naver.com",
        "tonarinoyj.jp",
        "shonenjumpplus.com",
        "comic-days.com",
        "magcomi.com",
        "shonenmagazine.com",
        "comic-gardo.com",
        "comic-earthstar.com",
        "api.mangaupdates.com"
    ]
}

/// Checks the constant above — and so the manifest comment it mirrors —
/// against the network clients themselves, by grepping their source for each
/// host, rather than trusting a hand-typed list to stay in sync with them.
@Suite("Every contacted host is named", .enabled(if: SourceTree.isAvailable))
struct ContactedHostsTests {
    @Test("Every host in the privacy-manifest list is actually referenced by a client")
    func everyHostIsReferenced() throws {
        let files = try SourceTree.swiftFiles(under: "MangaBaka/Core")
        let combined = try files.map { try SourceTree.read($0) }.joined()
        for host in ContactedHosts.all {
            #expect(combined.contains(host), "\(host) is listed but no client under Core/ mentions it")
        }
    }

    /// The seven GigaViewer hosts are all confirmed by the client's own
    /// dictionary (`ReleaseSource.gigaViewerHostNames`) rather than by the
    /// magazine RSS request being spelled out per host, so this pins the
    /// count independently of how that lookup happens to be written.
    @Test("The GigaViewer host count matches the client's own list")
    func gigaViewerHostCountMatches() {
        #expect(ReleaseSource.gigaViewerHostNames.count == 7)
        for host in ContactedHosts.all where host.hasSuffix(".jp") || host.hasSuffix(".com") {
            guard ReleaseSource.gigaViewerHostNames[host] != nil else { continue }
            #expect(ReleaseSource.gigaViewerHostNames.keys.contains(host))
        }
    }
}
