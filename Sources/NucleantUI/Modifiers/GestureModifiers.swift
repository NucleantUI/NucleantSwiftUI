//
//  GestureModifiers.swift
//  NucleantUI
//
//  `.gesture`, `.highPriorityGesture`, `.simultaneousGesture`, and the
//  shorthands built on them: `.onTapGesture(count:)` and
//  `.onLongPressGesture`.
//
//  How gestures compete is SwiftUI's: when a press reaches several, a
//  `.highPriorityGesture` goes before the gestures of the views inside it,
//  a `.gesture` goes after them, and a `.simultaneousGesture` competes
//  with nothing. The host's `GestureArena` is where that is decided.
//

/// Which gestures a `.gesture(_:including:)` leaves on: the one being
/// attached, those of the views inside, both, or neither.
public struct GestureMask: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Neither this gesture nor those inside.
    public static let none = GestureMask([])
    /// This gesture, with those of the views inside turned off.
    public static let gesture = GestureMask(rawValue: 1 << 0)
    /// The gestures of the views inside, with this one turned off.
    public static let subviews = GestureMask(rawValue: 1 << 1)
    /// This gesture and those inside — the default.
    public static let all: GestureMask = [.gesture, .subviews]
}

extension View {

    /// Attaches `gesture` to this view, after the gestures of the views
    /// inside it: a press they recognize is theirs.
    public func gesture<G: Gesture>(_ gesture: G, including mask: GestureMask = .all) -> some View {
        attachGesture(gesture, priority: .normal, mask: mask)
    }

    public func gesture<G: Gesture>(_ gesture: G, isEnabled: Bool) -> some View {
        attachGesture(gesture, priority: .normal, mask: isEnabled ? .all : .subviews)
    }

    /// Attaches `gesture` to this view, before the gestures of the views
    /// inside it: while it may still be recognized, theirs wait.
    public func highPriorityGesture<G: Gesture>(_ gesture: G, including mask: GestureMask = .all) -> some View {
        attachGesture(gesture, priority: .high, mask: mask)
    }

    public func highPriorityGesture<G: Gesture>(_ gesture: G, isEnabled: Bool) -> some View {
        attachGesture(gesture, priority: .high, mask: isEnabled ? .all : .subviews)
    }

    /// Attaches `gesture` to this view alongside every other gesture: it
    /// neither waits for nor stops any of them — a pinch and a twist on the
    /// same photo, a drag that also reports to an outer view.
    public func simultaneousGesture<G: Gesture>(_ gesture: G, including mask: GestureMask = .all) -> some View {
        attachGesture(gesture, priority: .simultaneous, mask: mask)
    }

    public func simultaneousGesture<G: Gesture>(_ gesture: G, isEnabled: Bool) -> some View {
        attachGesture(gesture, priority: .simultaneous, mask: isEnabled ? .all : .subviews)
    }

    private func attachGesture<G: Gesture>(
        _ gesture: G,
        priority: GestureAttachment.Priority,
        mask: GestureMask
    ) -> some View {
        let recognition = gesture._recognition
        return _ModifierView(content: self) { context in
            GestureContent(attachment: GestureAttachment(
                path: context.path,
                priority: priority,
                recognition: recognition,
                includesGesture: mask.contains(.gesture) && context.environment.isEnabled,
                includesSubviews: mask.contains(.subviews)
            ))
        }
    }
}

extension View {

    /// Runs `action` when this view is tapped `count` times in a row.
    ///
    /// With a double tap and a single tap on the same view, attach the
    /// double tap first; the single tap then waits until a second tap can
    /// no longer come.
    ///
    /// ```swift
    /// thumbnail
    ///     .onTapGesture(count: 2) { open(photo) }
    ///     .onTapGesture { select(photo) }
    /// ```
    public func onTapGesture(count: Int, perform action: @escaping @MainActor () -> Void) -> some View {
        _ModifierView(content: self) { context -> any NodeContent in
            guard count > 1 else {
                return InteractionContent(target: HitTarget(
                    isEnabled: context.environment.isEnabled,
                    onRelease: { _, inside in if inside { action() } }
                ))
            }
            return GestureContent(attachment: GestureAttachment(
                path: context.path,
                priority: .normal,
                recognition: TapGesture(count: count).onEnded(action)._recognition,
                includesGesture: context.environment.isEnabled,
                includesSubviews: true
            ))
        }
    }

    /// Runs `action` with the last tap's location, in the view's own
    /// coordinates, when this view is tapped `count` times in a row.
    public func onTapGesture(
        count: Int,
        perform action: @escaping @MainActor (Point) -> Void
    ) -> some View {
        _ModifierView(content: self) { context -> any NodeContent in
            guard count > 1 else {
                return InteractionContent(target: HitTarget(
                    isEnabled: context.environment.isEnabled,
                    onRelease: { point, inside in if inside { action(point) } }
                ))
            }
            var tap = TapGesture(count: count)
            tap.locatedAction = action
            return GestureContent(attachment: GestureAttachment(
                path: context.path,
                priority: .normal,
                recognition: tap._recognition,
                includesGesture: context.environment.isEnabled,
                includesSubviews: true
            ))
        }
    }

    /// Runs `action` once a press on this view has been held for
    /// `minimumDuration` seconds without wandering more than
    /// `maximumDistance` points — while the press is still down.
    /// `onPressingChanged` hears `true` when a press starts and `false`
    /// when it ends, whether or not it lasted long enough.
    public func onLongPressGesture(
        minimumDuration: Double = 0.5,
        maximumDistance: Double = 10,
        perform action: @escaping @MainActor () -> Void,
        onPressingChanged: (@MainActor (Bool) -> Void)? = nil
    ) -> some View {
        var press = LongPressGesture(minimumDuration: minimumDuration, maximumDistance: maximumDistance)
            .onEnded { _ in action() }
        press.pressingAction = onPressingChanged
        return gesture(press)
    }

    /// The same, with the pressing callback first — SwiftUI's older
    /// spelling.
    public func onLongPressGesture(
        minimumDuration: Double = 0.5,
        maximumDistance: Double = 10,
        pressing: (@MainActor (Bool) -> Void)?,
        perform action: @escaping @MainActor () -> Void
    ) -> some View {
        onLongPressGesture(
            minimumDuration: minimumDuration,
            maximumDistance: maximumDistance,
            perform: action,
            onPressingChanged: pressing
        )
    }
}

/// One gesture attached to a view, as hit testing finds it.
///
/// Known by its path, as a `HoverTarget` is: the actions a gesture runs
/// usually write state, which rebuilds the view and replaces this object,
/// and a gesture in flight must keep reaching the current actions.
@MainActor
final class GestureAttachment {
    enum Priority {
        /// `.gesture` — after the gestures inside.
        case normal
        /// `.highPriorityGesture` — before the gestures inside.
        case high
        /// `.simultaneousGesture` — alongside everything.
        case simultaneous
    }

    let path: [Int]
    let priority: Priority
    let recognition: _GestureRecognition
    /// Whether this gesture runs at all — off for `.disabled`, `isEnabled:
    /// false`, or a mask without `.gesture`.
    let includesGesture: Bool
    /// Whether the gestures and pointer targets of the views inside run —
    /// off for a mask without `.subviews`.
    let includesSubviews: Bool

    init(
        path: [Int],
        priority: Priority,
        recognition: _GestureRecognition,
        includesGesture: Bool,
        includesSubviews: Bool
    ) {
        self.path = path
        self.priority = priority
        self.recognition = recognition
        self.includesGesture = includesGesture
        self.includesSubviews = includesSubviews
    }
}

/// `.gesture`, `.highPriorityGesture`, `.simultaneousGesture`.
struct GestureContent: NodeContent {
    let attachment: GestureAttachment

    var gestureAttachment: GestureAttachment? { attachment }
}
