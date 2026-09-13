import Foundation
import Testing
@testable import MangaBaka

/// `Fetched<T>` is the fix for systemic cause (a): the largest single family
/// in the failure review is a service returning `[]` / `nil` / `.empty` for
/// both "asked and got nothing" and "asked and failed", so the caller cannot
/// tell a quiet section from a broken one. `FeedResult` already draws this
/// line by hand for feeds; these tests pin that `Fetched` draws the same line
/// the same way, so both can eventually collapse onto one type without a
/// behaviour change.
@Suite("Fetched")
struct FetchedTests {
    private let error = APIError.server(status: 500, message: "x")

    /// Expected to fail before the fix: `Fetched` did not exist, so this call
    /// could not be written.
    @Test("A loaded value is usable, whether or not it's partial")
    func loadedIsUsable() {
        let complete = Fetched.loaded(1, fetchedAt: Date(), isPartial: false)
        let partial = Fetched.loaded(1, fetchedAt: Date(), isPartial: true)
        #expect(complete.isUsable)
        #expect(partial.isUsable)
        #expect(complete.blockingError == nil)
        #expect(partial.blockingError == nil)
    }

    @Test("A failure with stale content is usable and not blocking — mirrors FeedResult")
    func failedWithStaleIsUsable() {
        let fetched = Fetched.failed(error, stale: 1)
        #expect(fetched.isUsable)
        #expect(fetched.blockingError == nil, "Content exists, so this is a StaleBar, not a blocking failure")
        #expect(fetched.value == 1)
        #expect(fetched.error == error)
    }

    @Test("A failure with nothing cached is not usable and is blocking")
    func failedWithNoStaleBlocks() {
        let fetched = Fetched<Int>.failed(error, stale: nil)
        #expect(!fetched.isUsable)
        #expect(fetched.blockingError == error)
        #expect(fetched.value == nil)
    }

    @Test(".idle and .loading have nothing to show and are not loading-or-blocking confusedly")
    func idleAndLoadingAreEmpty() {
        let idle = Fetched<Int>.idle
        let loading = Fetched<Int>.loading
        #expect(!idle.isUsable && idle.value == nil && idle.error == nil && !idle.isLoading)
        #expect(!loading.isUsable && loading.value == nil && loading.error == nil)
        #expect(loading.isLoading)
        #expect(!idle.isLoading)
    }

    @Test("Equatable compares the whole case, when T is Equatable")
    func equatableComparesCases() {
        let now = Date()
        let complete = Fetched.loaded(1, fetchedAt: now, isPartial: false)
        let partial = Fetched.loaded(1, fetchedAt: now, isPartial: true)
        #expect(complete == Fetched.loaded(1, fetchedAt: now, isPartial: false))
        #expect(complete != partial)
        #expect(Fetched<Int>.failed(error, stale: nil) == Fetched<Int>.failed(error, stale: nil))
        #expect(Fetched<Int>.idle == Fetched<Int>.idle)
        #expect(Fetched<Int>.idle != Fetched<Int>.loading)
    }
}
