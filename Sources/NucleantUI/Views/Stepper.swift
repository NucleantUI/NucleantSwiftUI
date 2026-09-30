//
//  Stepper.swift
//  NucleantUI
//

import Observation

/// A control that increments and decrements a value.
///
/// ```swift
/// Stepper("Tempo: \(tempo) BPM", value: $tempo, in: 40...240)
///
/// Stepper("Bars: \(bars)", value: $bars, in: 1...64, step: 4)
///
/// Stepper {
///     Text("Zoom \(zoom)×")
/// } onIncrement: {
///     zoom *= 2
/// } onDecrement: {
///     zoom /= 2
/// }
/// ```
///
/// The label sits on the leading edge and the − / + buttons on the trailing
/// one. A press steps once; held, it keeps stepping, faster after a
/// moment. A button whose step would leave the range is disabled, as is one
/// with no action.
@View
public struct Stepper<Label: View>: View {
    let label: Label
    let actions: StepperActions
    let onEditingChanged: (Bool) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.labelsHidden) private var labelsHidden
    @Environment(\.tint) private var tint

    /// Which button is held, and the repeat running while it is.
    @State private var repeater = StepperRepeater()

    public init(
        _viewID: ViewID = #viewID,
        @ViewBuilder label: () -> Label,
        onIncrement: (() -> Void)?,
        onDecrement: (() -> Void)?,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.label = label()
        self.actions = StepperActions(storage: StepperClosures(increment: onIncrement, decrement: onDecrement))
        self.onEditingChanged = onEditingChanged
        self._viewID = _viewID
    }

    init(label: Label, actions: StepperActions, onEditingChanged: @escaping (Bool) -> Void, _viewID: ViewID) {
        self.label = label
        self.actions = actions
        self.onEditingChanged = onEditingChanged
        self._viewID = _viewID
    }

    public var body: some View {
        HStack(spacing: 8) {
            if !labelsHidden {
                label
                Spacer(minLength: 8)
            }
            HStack(spacing: 0) {
                button("−", direction: .decrement, isAvailable: actions.storage.canDecrement)
                Color.separator
                    .frame(width: 1, height: 16)
                button("+", direction: .increment, isAvailable: actions.storage.canIncrement)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.tertiaryBackground))
        }
        .opacity(isEnabled ? 1 : 0.4)
    }

    private func button(_ glyph: String, direction: StepperRepeater.Direction, isAvailable: Bool) -> some View {
        let isHeld = repeater.held == direction
        let storage = actions.storage
        let repeater = self.repeater
        let onEditingChanged = self.onEditingChanged
        return Text(glyph)
            .font(.system(size: 17, weight: .medium))
            .foregroundColor(isAvailable ? .primary : .tertiary)
            .frame(width: 40, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHeld ? controlTrackColor : Color.clear)
            )
            ._hitTarget(HitTarget(
                isEnabled: isEnabled && isAvailable,
                // A step on the press, not the release — and more while
                // held. Dragging off does not take it back.
                onPress: { _ in
                    onEditingChanged(true)
                    repeater.start(direction) {
                        switch direction {
                        case .increment:
                            guard storage.canIncrement else { return false }
                            storage.increment()
                        case .decrement:
                            guard storage.canDecrement else { return false }
                            storage.decrement()
                        }
                        return true
                    }
                },
                onRelease: { _, _ in
                    repeater.stop()
                    onEditingChanged(false)
                }
            ))
    }
}

extension Stepper {
    public init<V: Strideable>(
        value: Binding<V>,
        step: V.Stride = 1,
        _viewID: ViewID = #viewID,
        @ViewBuilder label: () -> Label,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.init(
            label: label(),
            actions: StepperActions(storage: StepperValue(value: value, bounds: nil, step: step)),
            onEditingChanged: onEditingChanged,
            _viewID: _viewID
        )
    }

    public init<V: Strideable>(
        value: Binding<V>,
        in bounds: ClosedRange<V>,
        step: V.Stride = 1,
        _viewID: ViewID = #viewID,
        @ViewBuilder label: () -> Label,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.init(
            label: label(),
            actions: StepperActions(storage: StepperValue(value: value, bounds: bounds, step: step)),
            onEditingChanged: onEditingChanged,
            _viewID: _viewID
        )
    }
}

extension Stepper where Label == Text {
    public init<S: StringProtocol>(
        _ title: S,
        onIncrement: (() -> Void)?,
        onDecrement: (() -> Void)?,
        onEditingChanged: @escaping (Bool) -> Void = { _ in },
        _viewID: ViewID = #viewID
    ) {
        self.init(
            _viewID: _viewID,
            label: { Text(title) },
            onIncrement: onIncrement,
            onDecrement: onDecrement,
            onEditingChanged: onEditingChanged
        )
    }

    public init<S: StringProtocol, V: Strideable>(
        _ title: S,
        value: Binding<V>,
        step: V.Stride = 1,
        onEditingChanged: @escaping (Bool) -> Void = { _ in },
        _viewID: ViewID = #viewID
    ) {
        self.init(value: value, step: step, _viewID: _viewID, label: { Text(title) }, onEditingChanged: onEditingChanged)
    }

    public init<S: StringProtocol, V: Strideable>(
        _ title: S,
        value: Binding<V>,
        in bounds: ClosedRange<V>,
        step: V.Stride = 1,
        onEditingChanged: @escaping (Bool) -> Void = { _ in },
        _viewID: ViewID = #viewID
    ) {
        self.init(value: value, in: bounds, step: step, _viewID: _viewID, label: { Text(title) }, onEditingChanged: onEditingChanged)
    }
}

// MARK: - What the buttons do

/// A stepper's actions, as the view holds them: one concrete type whatever
/// the value type, the actions themselves in a subclass that knows it.
struct StepperActions: ViewInput {
    let storage: StepperStorage

    func _isEquivalent(to other: StepperActions) -> Bool {
        storage.isEquivalent(to: other.storage)
    }
}

@MainActor
class StepperStorage {
    /// Whether a step up (down) is possible — false with no action, or at
    /// the end of the range.
    var canIncrement: Bool { fatalError("StepperStorage is abstract") }
    var canDecrement: Bool { fatalError("StepperStorage is abstract") }

    func increment() { fatalError("StepperStorage is abstract") }
    func decrement() { fatalError("StepperStorage is abstract") }

    func isEquivalent(to other: StepperStorage) -> Bool {
        fatalError("StepperStorage is abstract")
    }
}

/// The caller's own `onIncrement` / `onDecrement`.
final class StepperClosures: StepperStorage {
    let onIncrement: (() -> Void)?
    let onDecrement: (() -> Void)?

    init(increment: (() -> Void)?, decrement: (() -> Void)?) {
        self.onIncrement = increment
        self.onDecrement = decrement
    }

    override var canIncrement: Bool { onIncrement != nil }
    override var canDecrement: Bool { onDecrement != nil }

    override func increment() { onIncrement?() }
    override func decrement() { onDecrement?() }

    /// Closures can't be compared, and count for nothing, as a stored
    /// closure does for `@View` — only whether each button has one.
    override func isEquivalent(to other: StepperStorage) -> Bool {
        guard let other = other as? StepperClosures else { return false }
        return (onIncrement == nil) == (other.onIncrement == nil)
            && (onDecrement == nil) == (other.onDecrement == nil)
    }
}

/// A bound value stepped by `step`, clamped to `bounds`.
final class StepperValue<V: Strideable>: StepperStorage {
    let value: Binding<V>
    let bounds: ClosedRange<V>?
    let step: V.Stride

    init(value: Binding<V>, bounds: ClosedRange<V>?, step: V.Stride) {
        self.value = value
        self.bounds = bounds
        self.step = step
    }

    override var canIncrement: Bool {
        guard let bounds else { return true }
        return value.wrappedValue < bounds.upperBound
    }

    override var canDecrement: Bool {
        guard let bounds else { return true }
        return value.wrappedValue > bounds.lowerBound
    }

    /// A step that would pass the end of the range lands on it.
    override func increment() {
        var next = value.wrappedValue.advanced(by: step)
        if let bounds { next = min(bounds.upperBound, max(bounds.lowerBound, next)) }
        value.wrappedValue = next
    }

    override func decrement() {
        var next = value.wrappedValue.advanced(by: -step)
        if let bounds { next = min(bounds.upperBound, max(bounds.lowerBound, next)) }
        value.wrappedValue = next
    }

    /// Same value, same range, same step.
    override func isEquivalent(to other: StepperStorage) -> Bool {
        guard let other = other as? StepperValue<V> else { return false }
        return value._isEquivalent(to: other.value) && bounds == other.bounds && step == other.step
    }
}

// MARK: - Holding a button

/// Steps once when a button is pressed, then again every so often while it
/// is held: a pause first, so a press is one step, then a steady repeat
/// that speeds up. A class kept in `@State`, so the press, the release and
/// the repeat all reach the same one; `@Observable`, so the stepper, which
/// reads `held` to show the button down, rebuilds as it changes.
@MainActor @Observable
final class StepperRepeater {
    enum Direction {
        case increment, decrement
    }

    private(set) var held: Direction?

    @ObservationIgnored private var task: Task<Void, Never>?

    init() {}

    /// `step` answers whether it stepped; the repeat stops at the end of
    /// the range.
    func start(_ direction: Direction, step: @escaping @MainActor () -> Bool) {
        stop()
        held = direction
        guard step() else { return }
        task = Task { @MainActor in
            var interval: UInt64 = 120_000_000
            try? await Task.sleep(nanoseconds: 450_000_000)
            var count = 0
            while !Task.isCancelled, step() {
                count += 1
                if count % 8 == 0 { interval = max(40_000_000, interval * 2 / 3) }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if held != nil { held = nil }
    }
}

extension StepperRepeater: ViewInput {
    /// One per stepper, for its lifetime.
    func _isEquivalent(to other: StepperRepeater) -> Bool {
        self === other
    }
}
