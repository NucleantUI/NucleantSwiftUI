//
//  Environment.swift
//  NucleantSwiftUI
//

/// A key into `EnvironmentValues`.
public protocol EnvironmentKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

/// Values handed down a subtree — the foreground color a `Text` picks up, the
/// font it inherits, the tint a `Button` uses.
public struct EnvironmentValues: @unchecked Sendable {

    private var storage: [ObjectIdentifier: Any] = [:]

    /// Stamped on every write from a process-wide counter, so two values
    /// with the same stamp are copies of one another and need no comparing.
    /// Different stamps say nothing either way — see `_isEquivalent`.
    private var version: UInt64 = 0

    nonisolated(unsafe) private static var nextVersion: UInt64 = 1

    public init() {}

    public subscript<K: EnvironmentKey>(key: K.Type) -> K.Value {
        get { storage[ObjectIdentifier(key)] as? K.Value ?? K.defaultValue }
        set {
            storage[ObjectIdentifier(key)] = newValue
            version = Self.nextVersion
            Self.nextVersion &+= 1
        }
    }

    /// Whether a view built under `other` would see the same values.
    ///
    /// A parent that re-runs re-applies its `.font(…)` and produces a fresh
    /// copy, so the stamp usually differs even when nothing did; the values
    /// are then compared one by one. A value the framework can't compare — a
    /// closure, a class — makes the whole environment "changed", which
    /// only ever costs a rebuild.
    @MainActor
    func _isEquivalent(to other: EnvironmentValues) -> Bool {
        if version == other.version { return true }
        guard storage.count == other.storage.count else { return false }
        for (key, value) in storage {
            guard let theirs = other.storage[key], _dynamicallyEquivalent(value, theirs) else {
                return false
            }
        }
        return true
    }
}

/// Reads one environment value.
///
/// ```swift
/// @Environment(\.foregroundColor) private var foreground
/// ```
@propertyWrapper
@MainActor
public struct Environment<Value>: DynamicProperty {

    final class Holder {
        var value: Value?
    }

    private let holder = Holder()
    private let read: (EnvironmentValues) -> Value

    public init(_ keyPath: KeyPath<EnvironmentValues, Value>) {
        self.read = { $0[keyPath: keyPath] }
    }

    public var wrappedValue: Value {
        guard let value = holder.value else {
            preconditionFailure(
                "@Environment read before the view was built — environment values "
                + "are only available inside `body`."
            )
        }
        return value
    }

    public func _bind(to context: BindingContext) {
        holder.value = read(context.environment)
    }
}

// MARK: - Built-in keys

private struct ForegroundColorKey: EnvironmentKey {
    static let defaultValue = Color.primary
}

private struct FontKey: EnvironmentKey {
    static let defaultValue = Font.body
}

private struct TintKey: EnvironmentKey {
    static let defaultValue = Color.blue
}

private struct IsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

private struct MultilineTextAlignmentKey: EnvironmentKey {
    static let defaultValue = TextAlignment.leading
}

private struct LineLimitKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

private struct DisplayScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

extension EnvironmentValues {
    public var foregroundColor: Color {
        get { self[ForegroundColorKey.self] }
        set { self[ForegroundColorKey.self] = newValue }
    }

    public var font: Font {
        get { self[FontKey.self] }
        set { self[FontKey.self] = newValue }
    }

    public var tint: Color {
        get { self[TintKey.self] }
        set { self[TintKey.self] = newValue }
    }

    public var isEnabled: Bool {
        get { self[IsEnabledKey.self] }
        set { self[IsEnabledKey.self] = newValue }
    }

    public var multilineTextAlignment: TextAlignment {
        get { self[MultilineTextAlignmentKey.self] }
        set { self[MultilineTextAlignmentKey.self] = newValue }
    }

    public var lineLimit: Int? {
        get { self[LineLimitKey.self] }
        set { self[LineLimitKey.self] = newValue }
    }

    /// Backing-store pixels per point. The window seeds it from the layer's
    /// `contentsScale`; layout runs in points and the renderer scales up.
    public var displayScale: Double {
        get { self[DisplayScaleKey.self] }
        set { self[DisplayScaleKey.self] = newValue }
    }
}
