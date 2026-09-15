//
//  Observation.swift
//  NucleantSwiftUI
//
//  `@Observable` models as view inputs.
//
//  `@State` is tracked by the framework's own reader registration; a property
//  of an `@Observable` class is tracked by the standard library's
//  `withObservationTracking`. Every place user code constructs views — a
//  view's `body`, a `ForEach` row closure — runs inside one tracking scope
//  attributed to that view's path, and the first change to anything it read
//  marks the path dirty. The next frame rebuilds from there, exactly as it
//  would after a `@State` write.
//
//  Scopes are deliberately never nested: a scope wraps the *construction* of
//  child view values, not the building of their nodes, so a child's own
//  reads land on the child's path rather than merging into every ancestor's.
//

import Foundation
import Observation

/// Run `construct` with its `@Observable` reads attributed to the view at
/// `path`. A later change to any of them dirties that path.
@MainActor
func trackingObservation<T>(at path: [Int], _ construct: () -> T) -> T {
    let invalidator = Invalidator.shared
    return withObservationTracking(construct) {
        invalidator.invalidateFromAnyThread(owner: path)
    }
}

extension Invalidator {
    /// `withObservationTracking`'s change handler runs on whichever thread
    /// wrote the property — a background analysis finishing, say. Hop to the
    /// main actor where the dirty set lives; a write already on the main
    /// thread is recorded at once so the very next frame sees it.
    nonisolated func invalidateFromAnyThread(owner path: [Int]) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { invalidate(owner: path) }
        } else {
            DispatchQueue.main.async { self.invalidate(owner: path) }
        }
    }
}

/// Bindings into an `@Observable` object's properties — SwiftUI's `@Bindable`.
///
/// ```swift
/// @View
/// struct GainControl {
///     @Bindable var sample: Sample
///
///     var body: some View {
///         Fader(level: $sample.gain)     // Binding<Double> through a key path
///     }
/// }
/// ```
///
/// A write through the binding is a write to the object, so every view that
/// read that property is invalidated by observation; as a view *input* the
/// wrapper compares by object identity, the same as a bare stored reference.
@propertyWrapper
@dynamicMemberLookup
public struct Bindable<Value: AnyObject> {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    public init(_ wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    public var projectedValue: Bindable<Value> { self }

    @MainActor
    public subscript<Subject>(
        dynamicMember keyPath: ReferenceWritableKeyPath<Value, Subject>
    ) -> Binding<Subject> {
        let object = wrappedValue
        return Binding(
            get: { object[keyPath: keyPath] },
            set: { object[keyPath: keyPath] = $0 }
        )
    }
}

extension Bindable: ViewInput {
    public func _isEquivalent(to other: Bindable<Value>) -> Bool {
        wrappedValue === other.wrappedValue
    }
}
