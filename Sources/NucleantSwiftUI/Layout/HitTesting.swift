//
//  HitTesting.swift
//  NucleantSwiftUI
//

/// A node that responds to pointer input. Coordinates handed to the callbacks
/// are in the node's own space — the placed frame's origin subtracted and any
/// ambient transform undone.
@MainActor
public final class HitTarget {
    let isEnabled: Bool
    let onPress: (@MainActor (Point) -> Void)?
    /// `(point, inside)` — `inside` is false when the pointer was released
    /// outside the node, which is how a drag-off cancels a button.
    let onRelease: (@MainActor (Point, Bool) -> Void)?
    let onTap: (@MainActor (Point) -> Void)?
    let onScroll: (@MainActor (Point) -> Void)?

    /// How far the pointer must travel before a drag starts reporting.
    let minimumDragDistance: Double
    let onDragChanged: (@MainActor (DragGesture.Value) -> Void)?
    let onDragEnded: (@MainActor (DragGesture.Value) -> Void)?

    public init(
        isEnabled: Bool = true,
        minimumDragDistance: Double = 0,
        onPress: (@MainActor (Point) -> Void)? = nil,
        onRelease: (@MainActor (Point, Bool) -> Void)? = nil,
        onTap: (@MainActor (Point) -> Void)? = nil,
        onScroll: (@MainActor (Point) -> Void)? = nil,
        onDragChanged: (@MainActor (DragGesture.Value) -> Void)? = nil,
        onDragEnded: (@MainActor (DragGesture.Value) -> Void)? = nil
    ) {
        self.isEnabled = isEnabled
        self.minimumDragDistance = minimumDragDistance
        self.onPress = onPress
        self.onRelease = onRelease
        self.onTap = onTap
        self.onScroll = onScroll
        self.onDragChanged = onDragChanged
        self.onDragEnded = onDragEnded
    }

    var handlesPointer: Bool {
        onPress != nil || onRelease != nil || onTap != nil
            || onDragChanged != nil || onDragEnded != nil
    }
    var handlesScroll: Bool { onScroll != nil }
}

/// One node found under a point, with the point already mapped into its space.
@MainActor
struct HitResult {
    let target: HitTarget
    let localPoint: Point
    /// The node's frame, kept so a later release can ask "still inside?".
    let frame: Rect
    let transform: Transform
}

extension ViewNode {

    /// The frontmost node under `point` (window coordinates) whose target
    /// satisfies `matching`.
    ///
    /// Depth-first with children reversed: the display list paints children in
    /// order, so the last one drawn is on top and must be tested first.
    func hitTest(_ point: Point, matching: (HitTarget) -> Bool) -> HitResult? {
        // Off screen, whatever the frames left over from an earlier pass say.
        guard !content.isParked else { return nil }
        // A clipping node's children only exist inside its frame.
        if content.clipsChildren {
            guard let local = mapIntoLocalSpace(point), frame.contains(local) else { return nil }
        }
        for child in children.reversed() {
            if let hit = child.hitTest(point, matching: matching) { return hit }
        }

        guard let target = content.hitTarget, target.isEnabled, matching(target) else {
            return nil
        }
        guard let local = mapIntoLocalSpace(point), frame.contains(local) else { return nil }
        return HitResult(
            target: target,
            localPoint: Point(x: local.x - frame.minX, y: local.y - frame.minY),
            frame: frame,
            transform: transform
        )
    }

    /// `point` with this node's ambient transform undone — `nil` for a
    /// degenerate transform (a zero `scaleEffect`), which can't be hit.
    func mapIntoLocalSpace(_ point: Point) -> Point? {
        guard !transform.isIdentity else { return point }
        return transform.inverted()?.apply(to: point)
    }

    /// Whether `point` still falls inside this node — asked on pointer release
    /// to decide whether a press became a tap.
    func contains(windowPoint point: Point) -> Bool {
        guard let local = mapIntoLocalSpace(point) else { return false }
        return frame.contains(local)
    }
}

extension HitResult {
    /// The window point mapped into this result's node space, for a later
    /// event in the same gesture.
    func localPoint(for windowPoint: Point) -> Point? {
        let local: Point
        if transform.isIdentity {
            local = windowPoint
        } else if let inverse = transform.inverted() {
            local = inverse.apply(to: windowPoint)
        } else {
            return nil
        }
        return Point(x: local.x - frame.minX, y: local.y - frame.minY)
    }

    func contains(_ windowPoint: Point) -> Bool {
        if transform.isIdentity { return frame.contains(windowPoint) }
        guard let inverse = transform.inverted() else { return false }
        return frame.contains(inverse.apply(to: windowPoint))
    }
}
