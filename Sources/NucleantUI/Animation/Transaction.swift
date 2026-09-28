//
//  Transaction.swift
//  NucleantUI
//
//  The context of one state change: whether, and how, what it causes on
//  screen should animate. `withAnimation` / `withTransaction` publish one
//  for the length of their body; every state write made meanwhile files it
//  with the `Invalidator`, and the next frame builds and lays out under it.
//
//  One transaction per frame, not per write: the frame that serves the
//  writes animates everything they changed — the rows a toggled row pushed
//  down included, which is the whole point. Two writes in the same frame,
//  one animated and one not, both animate.
//

/// The context of a state change — SwiftUI's `Transaction`.
public struct Transaction {

    /// How what this change causes on screen moves, or `nil` for at once.
    public var animation: Animation?

    /// True to override `.animation(_:value:)` inside the changed views,
    /// so only this transaction's own `animation` applies.
    public var disablesAnimations = false

    /// True while the change is one of a continuous stream — a drag.
    public var isContinuous = false

    /// `withAnimation(_:_:completion:)` callbacks waiting on this change.
    var completions: [AnimationCompletion] = []

    public init() {}

    public init(animation: Animation?) {
        self.animation = animation
    }

    /// Fold in a later transaction from the same frame: an animated one
    /// wins over one without, so a stray plain write doesn't cancel it.
    mutating func merge(_ later: Transaction) {
        if later.animation != nil || later.disablesAnimations {
            animation = later.animation
            disablesAnimations = later.disablesAnimations
        }
        isContinuous = isContinuous || later.isContinuous
        completions += later.completions
    }
}

/// The transaction the code running right now is inside.
@MainActor
enum TransactionScope {
    static var current: Transaction?
}

/// Runs `body` with `transaction` as the context of every state change it
/// makes.
@MainActor
public func withTransaction<Result>(_ transaction: Transaction, _ body: () throws -> Result) rethrows -> Result {
    let saved = TransactionScope.current
    TransactionScope.current = transaction
    defer { TransactionScope.current = saved }
    return try body()
}

/// Runs `body` with one property of the current transaction changed.
@MainActor
public func withTransaction<R, V>(
    _ keyPath: WritableKeyPath<Transaction, V>,
    _ value: V,
    _ body: () throws -> R
) rethrows -> R {
    var transaction = TransactionScope.current ?? Transaction()
    transaction[keyPath: keyPath] = value
    return try withTransaction(transaction, body)
}

/// Runs `body`, animating whatever its state changes do to the screen.
///
/// ```swift
/// Button("Toggle") {
///     withAnimation(.bouncy) { isOn.toggle() }
/// }
/// ```
@MainActor
public func withAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    try withTransaction(Transaction(animation: animation), body)
}

/// Runs `body` animated, then calls `completion` once every animation it
/// started has finished — at once, on the next frame, if it started none.
@MainActor
public func withAnimation<Result>(
    _ animation: Animation? = .default,
    completionCriteria: AnimationCompletionCriteria = .logicallyComplete,
    _ body: () throws -> Result,
    completion: @escaping @MainActor () -> Void
) rethrows -> Result {
    let tracker = AnimationCompletion(action: completion)
    var transaction = Transaction(animation: animation)
    transaction.completions = [tracker]
    defer { tracker.bodyFinished() }
    return try withTransaction(transaction, body)
}

/// When `withAnimation`'s completion counts as due. Accepted for SwiftUI
/// source compatibility; both criteria wait for the animations to end.
public struct AnimationCompletionCriteria: Hashable, Sendable {
    private let name: String

    /// The animations have reached their final values.
    public static let logicallyComplete = AnimationCompletionCriteria(name: "logicallyComplete")
    /// The animations have finished and been removed.
    public static let removed = AnimationCompletionCriteria(name: "removed")
}

/// One `withAnimation(completion:)` call, waiting to be told it is done.
///
/// A state write inside the body files it with the frame that serves the
/// write; each animation that frame starts is added to `runs`. Once that
/// frame has been laid out and every run is done, the callback runs. A
/// body that wrote nothing is due at once.
@MainActor
final class AnimationCompletion {
    private let action: @MainActor () -> Void

    /// A write inside the body carried this into a frame.
    var isClaimed = false
    /// The frame that served that write has been laid out — every
    /// animation it was going to start has started.
    var isScheduled = false
    /// The animations started for it.
    var runs: [AnimationRun] = []
    private var hasRun = false

    /// Bodies that wrote nothing, waiting for the next frame to call them.
    static var unclaimed: [AnimationCompletion] = []

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func bodyFinished() {
        if !isClaimed { Self.unclaimed.append(self) }
    }

    func run() {
        guard !hasRun else { return }
        hasRun = true
        action()
    }
}
