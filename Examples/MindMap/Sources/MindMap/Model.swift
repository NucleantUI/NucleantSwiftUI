//
//  Model.swift
//  MindMap
//
//  The maps and their topics. A map is an `@Observable` class changed only
//  through its own methods; a topic is a small value inside it — a title,
//  a colour, a parent, and the point its center sits at on the canvas.
//
//  The point is all the layout a topic has: the canvas puts each bubble
//  there with `.position`, and draws each branch from its parent's point
//  to its own. Dragging writes the point, Tidy Up writes every point at
//  once (under an animation, so the bubbles glide), and a new topic gets
//  one below its siblings.
//

import NucleantUI
import Observation

struct Topic: Identifiable, Hashable {
    let id: Int
    var title: String
    /// The bubble's center, in map space — before the canvas's pan.
    var point: Point
    /// `nil` for the central topic only.
    var parentID: Int?
    var colorIndex: Int
    /// Its branches folded away: hidden on the canvas, counted on the bubble.
    var isCollapsed = false
}

enum Palette {
    static let colors: [Color] = [
        Color(hex: 0xE5534B),
        Color(hex: 0xF0A23B),
        Color(hex: 0x3FB37F),
        Color(hex: 0x2F9ED8),
        Color(hex: 0x7A6FF0),
        Color(hex: 0xD45DB3),
    ]

    static func color(_ index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

/// A line from a parent's center to its child's, for the canvas to draw.
struct Branch: Identifiable, Hashable {
    /// The child's id: every topic but the center has exactly one branch in.
    let id: Int
    let from: Point
    let to: Point
    let colorIndex: Int
}

@MainActor
@Observable
final class MindMap: Identifiable {
    /// How far a child sits from its parent, across.
    static let columnWidth = 220.0
    /// How far apart siblings sit, down.
    static let rowHeight = 54.0

    let id: Int
    var name: String
    private(set) var topics: [Topic]
    private(set) var selection: Topic.ID?
    /// How far the whole map has been dragged across the canvas.
    private(set) var pan = Size.zero
    private var nextID: Int

    init(id: Int, name: String, center: String) {
        self.id = id
        self.name = name
        topics = [Topic(id: 0, title: center, point: Point(x: 520, y: 340), parentID: nil, colorIndex: 4)]
        selection = 0
        nextID = 1
    }

    // MARK: - Reading

    var root: Topic { topics[0] }

    var selectedTopic: Topic? { selection.flatMap(topic) }

    func topic(_ id: Topic.ID) -> Topic? {
        topics.first { $0.id == id }
    }

    /// Children in the order they read on the canvas, top to bottom.
    func children(of id: Topic.ID) -> [Topic] {
        topics.filter { $0.parentID == id }.sorted { $0.point.y < $1.point.y }
    }

    /// Every topic not folded away under a collapsed one, parents first.
    var visibleTopics: [Topic] {
        var result: [Topic] = []
        func visit(_ topic: Topic) {
            result.append(topic)
            guard !topic.isCollapsed else { return }
            for child in children(of: topic.id) { visit(child) }
        }
        visit(root)
        return result
    }

    var branches: [Branch] {
        let visible = visibleTopics
        let points = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.point) })
        return visible.compactMap { topic in
            guard let parentID = topic.parentID, let from = points[parentID] else { return nil }
            return Branch(id: topic.id, from: from, to: topic.point, colorIndex: topic.colorIndex)
        }
    }

    /// How many topics hang under `id`, at any depth.
    func descendantCount(of id: Topic.ID) -> Int {
        children(of: id).reduce(0) { $0 + 1 + descendantCount(of: $1.id) }
    }

    /// +1 for a topic right of the center (and the center itself), -1 left.
    func side(of topic: Topic) -> Double {
        topic.parentID == nil || topic.point.x >= root.point.x ? 1 : -1
    }

    /// The topic and everything under it.
    private func branch(of id: Topic.ID) -> Set<Topic.ID> {
        var ids: Set = [id]
        var pending = [id]
        while let parentID = pending.popLast() {
            for topic in topics where topic.parentID == parentID {
                ids.insert(topic.id)
                pending.append(topic.id)
            }
        }
        return ids
    }

    private func index(of id: Topic.ID) -> Int? {
        topics.firstIndex { $0.id == id }
    }

    // MARK: - Selection

    func select(_ id: Topic.ID?) {
        selection = id
    }

    func selectParent() {
        guard let parentID = selectedTopic?.parentID else { return }
        selection = parentID
    }

    /// Into the first child — expanding the topic if it was folded.
    func selectFirstChild() {
        guard let id = selection, let first = children(of: id).first else { return }
        if topic(id)?.isCollapsed == true { toggleCollapsed(id) }
        selection = first.id
    }

    /// The sibling `step` places above (−) or below (+) on the same side.
    func selectSibling(_ step: Int) {
        guard let current = selectedTopic, let parentID = current.parentID else { return }
        let side = side(of: current)
        let siblings = children(of: parentID).filter { self.side(of: $0) == side }
        guard let at = siblings.firstIndex(of: current) else { return }
        let next = at + step
        guard siblings.indices.contains(next) else { return }
        selection = siblings[next].id
    }

    // MARK: - Editing

    /// A new, untitled child of `parentID`, put below its siblings, and
    /// selected. Children of the center go to whichever side has fewer.
    @discardableResult
    func addChild(to parentID: Topic.ID) -> Topic.ID? {
        guard let parent = topic(parentID) else { return nil }
        if parent.isCollapsed { toggleCollapsed(parentID) }
        let siblings = children(of: parentID)
        let side: Double
        let colorIndex: Int
        if parent.parentID == nil {
            let right = siblings.filter { self.side(of: $0) > 0 }.count
            side = right <= siblings.count - right ? 1 : -1
            colorIndex = siblings.count
        } else {
            side = self.side(of: parent)
            colorIndex = parent.colorIndex
        }
        let sameSide = siblings.filter { self.side(of: $0) == side }
        let y = sameSide.last.map { $0.point.y + Self.rowHeight } ?? parent.point.y
        let topic = Topic(
            id: nextID,
            title: "",
            point: Point(x: parent.point.x + side * Self.columnWidth, y: y),
            parentID: parentID,
            colorIndex: colorIndex
        )
        nextID += 1
        topics.append(topic)
        selection = topic.id
        return topic.id
    }

    /// A new topic beside `id`, under the same parent — or a child, for the
    /// center, which has no siblings.
    @discardableResult
    func addSibling(of id: Topic.ID) -> Topic.ID? {
        guard let topic = topic(id) else { return nil }
        guard let parentID = topic.parentID else { return addChild(to: id) }
        let added = addChild(to: parentID)
        // Straight under the one it was added beside, pushing the rest down.
        if let added, let at = index(of: added) {
            let side = side(of: topic)
            topics[at].point = Point(x: topic.point.x, y: topic.point.y + Self.rowHeight)
            for other in children(of: parentID) where other.id != added
                && self.side(of: other) == side && other.point.y > topic.point.y {
                move(other.id, to: Point(x: other.point.x, y: other.point.y + Self.rowHeight))
            }
        }
        return added
    }

    func rename(_ id: Topic.ID, _ title: String) {
        guard let at = index(of: id) else { return }
        topics[at].title = title
    }

    /// Recolours the topic and its whole branch.
    func setColor(_ id: Topic.ID, _ colorIndex: Int) {
        let ids = branch(of: id)
        for at in topics.indices where ids.contains(topics[at].id) {
            topics[at].colorIndex = colorIndex
        }
    }

    func toggleCollapsed(_ id: Topic.ID) {
        guard let at = index(of: id), !children(of: id).isEmpty else { return }
        topics[at].isCollapsed.toggle()
        // A selection folded out of sight moves up to the folded topic.
        if let selected = selection, !visibleTopics.contains(where: { $0.id == selected }) {
            selection = id
        }
    }

    /// Removes the topic and everything under it; its parent is selected.
    func delete(_ id: Topic.ID) {
        guard let topic = topic(id), let parentID = topic.parentID else { return }
        let doomed = branch(of: id)
        topics.removeAll { doomed.contains($0.id) }
        selection = parentID
    }

    /// Puts the topic's center at `point`, carrying its branches along.
    func move(_ id: Topic.ID, to point: Point) {
        guard let topic = topic(id) else { return }
        let dx = point.x - topic.point.x
        let dy = point.y - topic.point.y
        guard dx != 0 || dy != 0 else { return }
        let ids = branch(of: id)
        for at in topics.indices where ids.contains(topics[at].id) {
            topics[at].point = Point(x: topics[at].point.x + dx, y: topics[at].point.y + dy)
        }
    }

    func setPan(_ pan: Size) {
        self.pan = pan
    }

    // MARK: - Tidy Up

    /// Lays the branches out in neat columns either side of the center,
    /// keeping each topic on the side and in the order it is in now. The
    /// center stays where it is; every other point is rewritten.
    func tidy() {
        let center = root
        let all = children(of: center.id)
        for side in [1.0, -1.0] {
            let group = all.filter { self.side(of: $0) == side }
            let height = group.reduce(0) { $0 + rows(in: $1) } * Self.rowHeight
            var top = center.point.y - height / 2
            for child in group {
                place(child.id, x: center.point.x + side * Self.columnWidth, top: top, side: side)
                top += rows(in: child) * Self.rowHeight
            }
        }
    }

    /// Rows a topic's branch takes on the canvas: one for a leaf or a
    /// folded topic, its children's together otherwise.
    private func rows(in topic: Topic) -> Double {
        let children = children(of: topic.id)
        guard !topic.isCollapsed, !children.isEmpty else { return 1 }
        return children.reduce(0) { $0 + rows(in: $1) }
    }

    private func place(_ id: Topic.ID, x: Double, top: Double, side: Double) {
        guard let topic = topic(id) else { return }
        let height = rows(in: topic) * Self.rowHeight
        // `move` takes the folded-away branches along with it; open ones
        // are placed below in their turn.
        move(id, to: Point(x: x, y: top + height / 2))
        guard !topic.isCollapsed else { return }
        var childTop = top
        for child in children(of: id) {
            place(child.id, x: x + side * Self.columnWidth, top: childTop, side: side)
            childTop += rows(in: child) * Self.rowHeight
        }
    }
}

// MARK: - The library

@MainActor
@Observable
final class Library {
    private(set) var maps: [MindMap]
    var currentID: MindMap.ID?
    private var nextID = 0

    init() {
        maps = []
        maps.append(Self.launchPlan(id: takeID()))
        maps.append(Self.trip(id: takeID()))
        maps.append(Self.reading(id: takeID()))
        currentID = maps.first?.id
    }

    var current: MindMap? {
        maps.first { $0.id == currentID }
    }

    func addMap() {
        let map = MindMap(id: takeID(), name: "Untitled Map", center: "Central Idea")
        maps.append(map)
        currentID = map.id
    }

    func delete(_ id: MindMap.ID) {
        maps.removeAll { $0.id == id }
        if currentID == id { currentID = maps.first?.id }
    }

    private func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    // MARK: Sample maps

    /// Builds a map from an outline: each entry a title and its children.
    private static func map(id: Int, name: String, center: String, _ outline: [(String, [String])]) -> MindMap {
        let map = MindMap(id: id, name: name, center: center)
        for (title, children) in outline {
            guard let branch = map.addChild(to: map.root.id) else { continue }
            map.rename(branch, title)
            for child in children {
                guard let leaf = map.addChild(to: branch) else { continue }
                map.rename(leaf, child)
            }
        }
        map.tidy()
        map.select(map.root.id)
        return map
    }

    private static func launchPlan(id: Int) -> MindMap {
        map(id: id, name: "Spring Launch", center: "Spring Launch", [
            ("Product", ["Feature freeze Mar 3", "Beta to 200 users", "Pricing page"]),
            ("Marketing", ["Launch video", "Press kit", "Newsletter"]),
            ("Support", ["Help center refresh", "On-call rota"]),
            ("Risks", ["Payment provider migration", "Translations late"]),
            ("Metrics", ["Activation rate", "Week-1 retention", "Refund rate"]),
        ])
    }

    private static func trip(id: Int) -> MindMap {
        map(id: id, name: "Lisbon Trip", center: "Lisbon, 5 days", [
            ("Stay", ["Alfama apartment", "Check-in after 3pm"]),
            ("Eat", ["Pastéis de Belém", "Time Out Market", "Seafood in Cascais"]),
            ("See", ["Tram 28", "Sintra day trip", "LX Factory"]),
            ("Pack", ["Walking shoes", "Light jacket"]),
        ])
    }

    private static func reading(id: Int) -> MindMap {
        map(id: id, name: "Reading Notes", center: "Thinking in Systems", [
            ("Stocks & flows", ["A stock changes only through its flows", "Delays cause oscillation"]),
            ("Feedback loops", ["Balancing loops seek a goal", "Reinforcing loops compound"]),
            ("Traps", ["Policy resistance", "Tragedy of the commons", "Drift to low performance"]),
            ("Leverage points", ["Paradigms", "Rules", "Information flows"]),
        ])
    }
}
