//
//  MapCanvas.swift
//  MindMap
//
//  The map itself. Every topic is a bubble put at its point with
//  `.position(_:)`: the bubble keeps its own size — however long its title
//  — and its center lands on the point, so the branch drawn to that same
//  point always meets it in the middle. Nothing else lays the map out.
//
//  * Drag a bubble to move it with its branches; drag the empty canvas to
//    pan the whole map (the pan is added to every point).
//  * Click selects; double-click folds a topic's branches away, or opens
//    them again — the bubble counts what is hidden.
//  * Tidy Up rewrites every point inside `withAnimation`: each bubble
//    glides because its position changed, and each branch with it because
//    `BranchShape` animates its two ends.
//  * Keys, with the canvas focused: Tab adds a child, Return a sibling,
//    Delete removes the branch, Space folds it, arrows walk the map,
//    Escape clears the selection.
//

import Foundation
import NucleantUI

@View
struct MapCanvas {
    let map: MindMap
    @FocusState.Binding var focus: Field?
    /// The pan when a drag on the empty canvas began.
    @State private var panStart: Size? = nil

    var body: some View {
        let map = self.map
        let pan = map.pan
        let selection = map.selection
        ZStack(alignment: .topLeading) {
            ForEach(map.branches) { branch in
                BranchShape(from: branch.from.shifted(by: pan), to: branch.to.shifted(by: pan))
                    .stroke(Palette.color(branch.colorIndex), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            ForEach(map.visibleTopics) { topic in
                TopicBubble(
                    map: map,
                    topic: topic,
                    isCenter: topic.parentID == nil,
                    isSelected: topic.id == selection,
                    hiddenCount: topic.isCollapsed ? map.descendantCount(of: topic.id) : 0,
                    focus: $focus
                )
                .position(topic.point.shifted(by: pan))
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(Theme.canvas)
        .overlay(alignment: .bottom) {
            HintBar()
                .padding(.bottom, 14)
        }
        // On the empty canvas — the bubbles' own gestures go first.
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    let start = panStart ?? map.pan
                    if panStart == nil { panStart = start }
                    map.setPan(Size(
                        width: start.width + value.translation.width,
                        height: start.height + value.translation.height
                    ))
                }
                .onEnded { _ in panStart = nil }
        )
        .gesture(TapGesture().onEnded {
            map.select(nil)
            focus = .canvas
        })
        .focusable()
        .focused($focus, equals: .canvas)
        .onKeyPress(.tab) {
            guard let id = map.selection else { return .ignored }
            withAnimation(.snappy) { map.addChild(to: id) }
            focus = .topicTitle
            return .handled
        }
        .onKeyPress(.return) {
            guard let id = map.selection else { return .ignored }
            withAnimation(.snappy) { map.addSibling(of: id) }
            focus = .topicTitle
            return .handled
        }
        .onKeyPress(.delete) {
            guard let id = map.selection else { return .ignored }
            withAnimation(.snappy) { map.delete(id) }
            return .handled
        }
        .onKeyPress(.space) {
            guard let id = map.selection else { return .ignored }
            withAnimation(.snappy) { map.toggleCollapsed(id) }
            return .handled
        }
        .onKeyPress(.escape) {
            map.select(nil)
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            walk(press.key)
        }
    }

    /// Arrows move the selection along the map as it is drawn: towards the
    /// center goes to the parent, away from it to the first child.
    private func walk(_ key: KeyEquivalent) -> KeyPress.Result {
        guard let selected = map.selectedTopic else {
            map.select(map.root.id)
            return .handled
        }
        let side = map.side(of: selected)
        switch key {
        case .upArrow:
            map.selectSibling(-1)
        case .downArrow:
            map.selectSibling(1)
        case .leftArrow, .rightArrow:
            let outward = (key == .rightArrow) == (side > 0)
            if selected.parentID == nil {
                // From the center, either way is outward: to the first
                // child on that side.
                let wanted: Double = key == .rightArrow ? 1 : -1
                if let child = map.children(of: selected.id).first(where: { map.side(of: $0) == wanted }) {
                    map.select(child.id)
                }
            } else if outward {
                withAnimation(.snappy) { map.selectFirstChild() }
            } else {
                map.selectParent()
            }
        default:
            return .ignored
        }
        return .handled
    }
}

// MARK: - Topic

/// One topic's bubble. Its gestures are on the bubble, inside the
/// `.position` the canvas puts around it, so only the bubble takes them —
/// not the whole canvas the positioned view spans.
@View
struct TopicBubble {
    let map: MindMap
    let topic: Topic
    let isCenter: Bool
    let isSelected: Bool
    let hiddenCount: Int
    @FocusState.Binding var focus: Field?
    /// The topic's point when a drag on it began.
    @State private var dragStart: Point? = nil

    var body: some View {
        let map = self.map
        let id = topic.id
        let color = Palette.color(topic.colorIndex)
        let radius = isCenter ? 16.0 : 10.0
        HStack(spacing: 8) {
            Text(topic.title.isEmpty ? "New topic" : topic.title)
                .font(.system(size: isCenter ? 18 : 13, weight: isCenter ? .bold : .medium))
                .foregroundColor(isCenter ? .white : (topic.title.isEmpty ? .secondary : .primary))
                .lineLimit(2)
            if hiddenCount > 0 {
                Text("+\(hiddenCount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(EdgeInsets(top: 2, leading: 7, bottom: 2, trailing: 7))
                    .background(Capsule().fill(color))
            }
        }
        .frame(maxWidth: isCenter ? 220 : 180)
        .padding(EdgeInsets(
            top: isCenter ? 14 : 8,
            leading: isCenter ? 20 : 12,
            bottom: isCenter ? 14 : 8,
            trailing: isCenter ? 20 : 12
        ))
        .background(RoundedRectangle(cornerRadius: radius).fill(isCenter ? color : Theme.bubble))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(isSelected ? Theme.selection : color, lineWidth: isSelected ? 3 : 1.5)
        )
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let start = dragStart ?? topic.point
                    if dragStart == nil {
                        dragStart = start
                        map.select(id)
                    }
                    map.move(id, to: Point(
                        x: start.x + value.translation.width,
                        y: start.y + value.translation.height
                    ))
                }
                .onEnded { _ in dragStart = nil }
        )
        .gesture(TapGesture(count: 2).onEnded {
            map.select(id)
            withAnimation(.snappy) { map.toggleCollapsed(id) }
        })
        // Without its own click, a click on a bubble would fall through to
        // the canvas's, which clears the selection.
        .gesture(TapGesture().onEnded {
            map.select(id)
            focus = .canvas
        })
    }
}

// MARK: - Branch

/// A soft S-curve from a parent's center to its child's, leaving and
/// arriving level. Both ends are its `animatableData`, so when Tidy Up
/// moves the topics under an animation the curve follows them all the way
/// instead of jumping to where they end up.
struct BranchShape: Shape {
    var from: Point
    var to: Point

    var animatableData: AnimatablePair<Point.AnimatableData, Point.AnimatableData> {
        get { AnimatablePair(from.animatableData, to.animatableData) }
        set {
            from.animatableData = newValue.first
            to.animatableData = newValue.second
        }
    }

    func path(in rect: Rect) -> Path {
        let start = Point(x: rect.minX + from.x, y: rect.minY + from.y)
        let end = Point(x: rect.minX + to.x, y: rect.minY + to.y)
        let bend = (end.x - start.x) / 2
        return Path { path in
            path.move(to: start)
            path.addCurve(
                to: end,
                control1: Point(x: start.x + bend, y: start.y),
                control2: Point(x: end.x - bend, y: end.y)
            )
        }
    }
}

// MARK: - Hints

@View
struct HintBar {
    var body: some View {
        Text("Drag topics or the canvas  ·  double-click folds  ·  Tab child  ·  Return sibling  ·  Delete removes  ·  arrows walk")
            .font(.system(size: 12))
            .foregroundColor(Color(white: 1, opacity: 0.92))
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .background(Capsule().fill(Color(white: 0, opacity: 0.55)))
            .allowsHitTesting(false)
    }
}

extension Point {
    func shifted(by offset: Size) -> Point {
        Point(x: x + offset.width, y: y + offset.height)
    }
}
