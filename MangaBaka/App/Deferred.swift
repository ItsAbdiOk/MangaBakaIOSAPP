import Foundation

/// A thing built the first time something asks for it, and never before.
///
/// A reference type rather than `lazy var`, because `AppServices` is a struct
/// held in a `let` by `MangaBakaApp` and passed by value into `RootView` — a
/// `lazy var` there is unreachable without a `var` and would be re-evaluated
/// per copy. This box is shared by every copy, so "built once" survives being
/// passed around, which is the property the launch path actually needs.
///
/// `isBuilt` exists for the test: asserting that the launch path left a store
/// alone is otherwise only checkable by reading the source, and a test that
/// reads source text proves the spelling rather than the behaviour.
@MainActor
final class Deferred<Value> {
    private let build: () -> Value
    private var storage: Value?

    init(_ build: @escaping () -> Value) {
        self.build = build
    }

    /// Whether anything has asked yet. False on a store nothing has reached.
    var isBuilt: Bool { storage != nil }

    /// The thing, built now if this is the first ask.
    var value: Value {
        if let storage { return storage }
        let made = build()
        storage = made
        return made
    }
}
