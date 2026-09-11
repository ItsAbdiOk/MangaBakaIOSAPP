import SwiftUI
import Testing
import UIKit
@testable import MangaBaka

/// An SF Symbol name that does not exist renders as empty space with no
/// warning, no crash and no build error. The Mix tab shipped that way:
/// "circle.on.circle" is not a symbol, so the tab showed a label and nothing
/// above it. A typo is indistinguishable from a deliberately blank tab, so the
/// only defence is checking every name resolves.
@Suite("Tab bar symbols")
struct AppTabSymbolTests {
    @Test("Every tab's symbol is a real SF Symbol", arguments: AppTab.allCases)
    func symbolResolves(_ tab: AppTab) {
        #expect(
            UIImage(systemName: tab.symbol) != nil,
            "AppTab.\(tab) uses '\(tab.symbol)', which is not an SF Symbol"
        )
    }

    /// The same silent failure as the tab that shipped without a glyph: a
    /// symbol name that is not an SF Symbol renders as nothing. Every name
    /// the feel pass added is checked here.
    @Test("Every animated symbol is a real SF Symbol", arguments: [
        "arrow.trianglehead.2.clockwise", "magnifyingglass", "plus", "xmark"
    ])
    func feelSymbolsResolve(_ name: String) {
        #expect(UIImage(systemName: name) != nil, "'\(name)' is not an SF Symbol")
    }

    @Test("Every tab has a label, so a missing glyph is never the whole control")
    func labelsExist() {
        for tab in AppTab.allCases {
            #expect(!tab.title.isEmpty)
        }
    }
}
