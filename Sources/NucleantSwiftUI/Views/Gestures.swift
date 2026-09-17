//
//  Gestures.swift
//  NucleantSwiftUI
//

/// A dragging gesture: a press, movement while held, and a release.
///
/// ```swift
/// .gesture(
///     DragGesture()
///         .onChanged { value in level = value.location.x / value.bounds.width }
///         .onEnded { _ in isEditing = false }
/// )
/// ```
public struct DragGesture {

    /// The state of a drag at one moment. `startLocation`, `location` and
    /// `translation` match SwiftUI's; `bounds` does not exist there.
    public struct Value {
        /// Which pointer this is: stable for the life of one finger on a
        /// touch host, so a view under several can tell them apart. A mouse
        /// is always 0.
        ///
        /// Not a SwiftUI field — there, one `DragGesture` sees one finger.
        public var id: Int
        /// Where the drag began, in the gesture view's own coordinates.
        public var startLocation: Point
        /// Where the pointer is now, in the same space.
        public var location: Point
        /// How far it has moved since the start.
        public var translation: Size
        /// The gesture view's own rect.
        ///
        /// Not a SwiftUI field — there, a control that needs its own width
        /// reads it through `GeometryReader`, which this framework doesn't have
        /// yet. Carrying it on the value is what lets a fader convert a
        /// position into a fraction without being told its width up front.
        public var bounds: Rect
    }

    /// Movement, in points, before the gesture starts reporting — so a tap
    /// with a shaky hand doesn't register as a drag.
    public var minimumDistance: Double

    var changedAction: (@MainActor (Value) -> Void)?
    var endedAction: (@MainActor (Value) -> Void)?

    public init(minimumDistance: Double = 0) {
        self.minimumDistance = minimumDistance
    }

    public func onChanged(_ action: @escaping @MainActor (Value) -> Void) -> DragGesture {
        var copy = self
        copy.changedAction = action
        return copy
    }

    public func onEnded(_ action: @escaping @MainActor (Value) -> Void) -> DragGesture {
        var copy = self
        copy.endedAction = action
        return copy
    }
}

extension View {
    /// Attaches a drag gesture to this view.
    public func gesture(_ gesture: DragGesture) -> some View {
        _ModifierView(content: self) { context in
            InteractionContent(target: HitTarget(
                isEnabled: context.environment.isEnabled,
                minimumDragDistance: gesture.minimumDistance,
                // A drag reports on press too, so a click that never moves
                // still sets the value it landed on — how a fader jumps to
                // where you tapped it.
                onDragChanged: gesture.changedAction,
                onDragEnded: gesture.endedAction
            ))
        }
    }
}
