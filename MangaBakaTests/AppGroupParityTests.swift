import Foundation
import Testing
@testable import MangaBaka

/// The App Group identifier, which exists in four places and must be one
/// string in all of them.
///
/// Two Swift constants (`WidgetSnapshot.appGroupID` in the app,
/// `WidgetSnapshotData.appGroupID` in the extension — they cannot share a
/// declaration, the extension has no access to the app's module) and two
/// entitlement files. Nothing checked that they agreed. The failure is silent
/// in the worst way: `containerURL(forSecurityApplicationGroupIdentifier:)`
/// answers nil for an unprovisioned group, `WidgetSnapshot.write` returns
/// early "silent on failure" by design, and the widget shows "Open MangaBaka
/// to load" forever. No crash, no log, no failing test — which is the n−1
/// pattern `XcconfigAssertions` was written for, in the one constant that
/// spans two targets.
@Suite("App Group parity")
struct AppGroupParityTests {
    @Test("Both targets' constants name the same group")
    func constantsAgree() {
        #expect(WidgetSnapshot.appGroupID == WidgetSnapshotData.appGroupID)
    }

    /// Against the entitlement files themselves, because a matching pair of
    /// Swift constants that neither target is entitled to use is exactly as
    /// broken as a mismatched pair.
    @Suite("Against the entitlements", .enabled(if: SourceTree.isAvailable))
    struct EntitlementsTests {
        @Test("Both entitlement files grant the group the code asks for")
        func entitlementsGrantIt() throws {
            for path in ["Configs/MangaBaka.entitlements", "Configs/MangaBakaWidgets.entitlements"] {
                let contents = try SourceTree.read(path)
                #expect(
                    contents.contains("<string>\(WidgetSnapshot.appGroupID)</string>"),
                    "\(path) does not grant \(WidgetSnapshot.appGroupID), so the widget reads nothing"
                )
            }
        }
    }
}
