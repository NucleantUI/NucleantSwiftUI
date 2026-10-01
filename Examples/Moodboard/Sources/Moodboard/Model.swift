//
//  Model.swift
//  Moodboard
//
//  The studio and its boards. `Studio` and `Board` are the `@Observable`
//  models — every move, pinch, twist, pin and edit changes a board through
//  its own methods; a `Card` is a record inside one. The boards are
//  generated from a fixed seed, so they are the same every launch; a photo
//  card's picture is a `Picture` — sky, sun and hills — drawn by
//  `PictureArt`.
//

import Foundation
import NucleantUI
import Observation

// MARK: - Values

/// What a photo card shows, drawn rather than decoded.
struct Picture: Hashable {
    let skyTop: Color
    let skyBottom: Color
    let sun: Color
    /// Where the sun sits, in the picture's unit square.
    let sunPosition: UnitPoint
    let farHills: Color
    let nearHills: Color
    /// Ridge heights, left to right, as fractions of the picture's height.
    let farRidge: [Double]
    let nearRidge: [Double]
}

/// What a card is.
enum CardKind: Hashable {
    /// A photo, with a white border and its caption under it.
    case photo(Picture)
    /// A paper note: its text and its paper.
    case note(String, Color)
    /// A round sticker in one colour, its caption written on it.
    case sticker(Color)
}

struct Card: Identifiable, Hashable {
    let id: Int
    var kind: CardKind
    var caption: String
    /// Where the card's centre sits on the board, in board points.
    var center: Point
    /// The card's size before `scale`.
    var size: Size
    var scale: Double
    var rotation: Angle
    /// A pinned card stays where it is: no moving, pinching or twisting
    /// until it is unpinned.
    var isPinned: Bool

    var isPhoto: Bool {
        if case .photo = kind { return true }
        return false
    }

    var kindName: String {
        switch kind {
        case .photo: return "Photo"
        case .note: return "Note"
        case .sticker: return "Sticker"
        }
    }
}

/// The colours the toolbar offers, for stickers and notes.
enum Palette {
    static let colors: [Color] = [
        Color(hex: 0xFF6B57), Color(hex: 0xFFB23F), Color(hex: 0xFFE066),
        Color(hex: 0x7BD389), Color(hex: 0x4FB3E8), Color(hex: 0x8C7CF0),
        Color(hex: 0xF2A7C3),
    ]

    /// The paper a note in `color` is written on: the colour, washed out.
    static func paper(_ color: Color) -> Color {
        Color(
            red: color.red + (1 - color.red) * 0.55,
            green: color.green + (1 - color.green) * 0.55,
            blue: color.blue + (1 - color.blue) * 0.55
        )
    }
}

extension Angle {
    static func + (a: Angle, b: Angle) -> Angle { .radians(a.radians + b.radians) }
}

// MARK: - Board

/// One board: its cards in paint order (the last on top), the selection,
/// the zoom, and a slideshow through the cards.
@MainActor
@Observable
final class Board: Identifiable {
    let id: Int
    var name: String
    private(set) var cards: [Card]
    private(set) var selection: Card.ID?
    /// How far the board is zoomed in, 1 being actual size.
    private(set) var zoom = 1.0
    /// Photos stay put while notes and stickers are arranged on them:
    /// clicks, pinches and drags go through a photo to what is under it.
    var photosLocked = false
    /// The card being presented, while presenting.
    private(set) var presented: Int?

    private var nextID: Int
    private var random: SeededRandom

    init(id: Int, name: String, cards: [Card], seed: UInt64) {
        self.id = id
        self.name = name
        self.cards = cards
        self.nextID = (cards.map(\.id).max() ?? 0) + 1
        self.random = SeededRandom(seed: seed)
    }

    func card(_ id: Card.ID) -> Card? {
        cards.first { $0.id == id }
    }

    var selectedCard: Card? {
        selection.flatMap(card)
    }

    var isPresenting: Bool { presented != nil }

    var presentedCard: Card? {
        presented.flatMap { cards.indices.contains($0) ? cards[$0] : nil }
    }

    // MARK: Selection

    /// Select `id` and bring it to the top — or select nothing.
    func select(_ id: Card.ID?) {
        selection = id
        guard let id, let index = cards.firstIndex(where: { $0.id == id }), index != cards.count - 1 else { return }
        cards.append(cards.remove(at: index))
    }

    // MARK: Arranging

    func move(_ id: Card.ID, by delta: Size) {
        update(id) { card in
            card.center = Point(x: card.center.x + delta.width, y: card.center.y + delta.height)
        }
    }

    func scale(_ id: Card.ID, by factor: Double) {
        update(id) { card in card.scale = Self.clampScale(card.scale * factor) }
    }

    func setScale(_ id: Card.ID, _ scale: Double) {
        update(id) { card in card.scale = Self.clampScale(scale) }
    }

    func rotate(_ id: Card.ID, by angle: Angle) {
        update(id) { card in card.rotation = Self.normalized(card.rotation + angle) }
    }

    func setRotation(_ id: Card.ID, _ angle: Angle) {
        update(id) { card in card.rotation = Self.normalized(angle) }
    }

    /// Back to its own size, upright.
    func resetTransform(_ id: Card.ID) {
        update(id) { card in
            card.scale = 1
            card.rotation = .zero
        }
    }

    func togglePin(_ id: Card.ID) {
        update(id) { card in card.isPinned.toggle() }
    }

    func setPinned(_ id: Card.ID, _ pinned: Bool) {
        update(id) { card in card.isPinned = pinned }
    }

    func setCaption(_ id: Card.ID, _ caption: String) {
        update(id) { card in card.caption = caption }
    }

    func setNoteText(_ id: Card.ID, _ text: String) {
        update(id) { card in
            if case .note(_, let paper) = card.kind { card.kind = .note(text, paper) }
        }
    }

    /// The selected card, moved by the arrow keys.
    func nudgeSelection(dx: Double, dy: Double) {
        guard let id = selection, card(id)?.isPinned == false else { return }
        move(id, by: Size(width: dx, height: dy))
    }

    func deleteSelection() {
        guard let id = selection else { return }
        cards.removeAll { $0.id == id }
        selection = nil
    }

    // MARK: Adding

    /// A note with `text`, near the middle of the board, selected.
    func addNote(_ text: String, color: Color = Palette.colors[2]) {
        add(Card(
            id: takeID(), kind: .note(text, Palette.paper(color)), caption: "",
            center: scatteredPoint(), size: Size(width: 190, height: 130),
            scale: 1, rotation: .degrees(random.nextDouble(in: -5...5)), isPinned: false
        ))
    }

    func addPhoto() {
        let portrait = random.nextInt(3) == 0
        add(Card(
            id: takeID(), kind: .photo(Self.makePicture(&random)), caption: Self.placeNames[random.nextInt(Self.placeNames.count)],
            center: scatteredPoint(), size: portrait ? Size(width: 170, height: 230) : Size(width: 240, height: 190),
            scale: 1, rotation: .degrees(random.nextDouble(in: -6...6)), isPinned: false
        ))
    }

    func addSticker(_ color: Color) {
        add(Card(
            id: takeID(), kind: .sticker(color), caption: Self.stickerWords[random.nextInt(Self.stickerWords.count)],
            center: scatteredPoint(), size: Size(width: 110, height: 110),
            scale: 1, rotation: .degrees(random.nextDouble(in: -12...12)), isPinned: false
        ))
    }

    /// A swatch from the toolbar: recolours the selected note or sticker,
    /// or puts a new sticker down.
    func applySwatch(_ color: Color) {
        if let id = selection, let card = card(id) {
            switch card.kind {
            case .note(let text, _):
                update(id) { $0.kind = .note(text, Palette.paper(color)) }
                return
            case .sticker:
                update(id) { $0.kind = .sticker(color) }
                return
            case .photo:
                break
            }
        }
        addSticker(color)
    }

    // MARK: Zoom

    func zoom(by factor: Double) {
        zoom = min(max(zoom * factor, 0.35), 3)
    }

    func resetZoom() {
        zoom = 1
    }

    // MARK: Presenting

    /// Show the cards one at a time, bottom to top.
    func startPresenting() {
        guard !cards.isEmpty else { return }
        selection = nil
        presented = 0
    }

    func stopPresenting() {
        presented = nil
    }

    func showNext() {
        guard let presented, !cards.isEmpty else { return }
        self.presented = (presented + 1) % cards.count
    }

    func showPrevious() {
        guard let presented, !cards.isEmpty else { return }
        self.presented = (presented + cards.count - 1) % cards.count
    }

    // MARK: Helpers

    private func update(_ id: Card.ID, _ change: (inout Card) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        change(&cards[index])
    }

    private func add(_ card: Card) {
        cards.append(card)
        selection = card.id
    }

    private func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private func scatteredPoint() -> Point {
        Point(x: random.nextDouble(in: 300...620), y: random.nextDouble(in: 200...420))
    }

    private static func clampScale(_ scale: Double) -> Double {
        min(max(scale, 0.3), 4)
    }

    /// Within ±180°.
    private static func normalized(_ angle: Angle) -> Angle {
        var degrees = angle.degrees.truncatingRemainder(dividingBy: 360)
        if degrees > 180 { degrees -= 360 }
        if degrees < -180 { degrees += 360 }
        return .degrees(degrees)
    }

    // MARK: Generating

    static let placeNames = [
        "Harbour at dawn", "North ridge", "Salt flats", "Lake house", "Fjord road",
        "Olive grove", "Dune walk", "Pine valley", "Cliff path", "Evening ferry",
    ]
    static let stickerWords = ["yes!", "warm", "calm", "more", "this", "soft", "bold", "keep"]

    static func makePicture(_ random: inout SeededRandom) -> Picture {
        let hour = random.nextDouble(in: 5...21)
        let daylight = max(0, sin((hour - 6) / 12 * .pi))
        let warmth = max(0, 1 - abs(hour - 18.5) / 2.5) + max(0, 1 - abs(hour - 6.5) / 2)
        let hue = random.nextDouble(in: 0...0.08)
        let green = random.nextDouble(in: 0.22...0.40)
        func ridge(_ low: Double, _ high: Double) -> [Double] {
            (0..<6).map { _ in random.nextDouble(in: low...high) }
        }
        return Picture(
            skyTop: hsb(0.60 - hue, 0.55, 0.25 + 0.65 * daylight),
            skyBottom: hsb(0.58 - 0.5 * warmth * 0.55, 0.30 + 0.45 * warmth, 0.35 + 0.6 * max(daylight, warmth * 0.8)),
            sun: hsb(0.12 - 0.08 * warmth, 0.25 + 0.6 * warmth, 1),
            sunPosition: UnitPoint(x: random.nextDouble(in: 0.15...0.85), y: 0.75 - 0.5 * daylight),
            farHills: hsb(green + 0.05, 0.35, 0.25 + 0.35 * daylight),
            nearHills: hsb(green, 0.55, 0.15 + 0.3 * daylight),
            farRidge: ridge(0.45, 0.65),
            nearRidge: ridge(0.62, 0.82)
        )
    }
}

// MARK: - Studio

/// Every board, and the one open.
@MainActor
@Observable
final class Studio {
    private(set) var boards: [Board]
    var currentID: Board.ID?

    init() {
        let names = ["Coastal Cabin", "Night Market", "Spring Launch"]
        boards = names.enumerated().map { index, name in
            Self.makeBoard(id: index + 1, name: name, seed: UInt64(41 + index * 977))
        }
        currentID = boards.first?.id
    }

    var current: Board? {
        boards.first { $0.id == currentID }
    }

    func addBoard() {
        let id = (boards.map(\.id).max() ?? 0) + 1
        let board = Board(id: id, name: "Untitled Board", cards: [], seed: UInt64(id * 7919))
        boards.append(board)
        currentID = id
    }

    /// A board seeded with photos, notes and stickers scattered over it.
    private static func makeBoard(id: Int, name: String, seed: UInt64) -> Board {
        var random = SeededRandom(seed: seed)
        var cards: [Card] = []
        var nextID = 1
        func place(_ x: ClosedRange<Double>, _ y: ClosedRange<Double>) -> Point {
            Point(x: random.nextDouble(in: x), y: random.nextDouble(in: y))
        }
        for _ in 0..<5 {
            let portrait = random.nextInt(3) == 0
            cards.append(Card(
                id: nextID, kind: .photo(Board.makePicture(&random)),
                caption: Board.placeNames[random.nextInt(Board.placeNames.count)],
                center: place(160...820, 150...520),
                size: portrait ? Size(width: 170, height: 230) : Size(width: 240, height: 190),
                scale: random.nextDouble(in: 0.85...1.2), rotation: .degrees(random.nextDouble(in: -8...8)),
                isPinned: false
            ))
            nextID += 1
        }
        let notes = ["Weathered oak, nothing glossy", "Linen + rope textures", "Light from the left, late afternoon", "Keep the palette to three colours"]
        for note in notes.shuffled(using: &random).prefix(3) {
            let color = Palette.colors[random.nextInt(Palette.colors.count)]
            cards.append(Card(
                id: nextID, kind: .note(note, Palette.paper(color)), caption: "",
                center: place(180...800, 160...540), size: Size(width: 190, height: 130),
                scale: 1, rotation: .degrees(random.nextDouble(in: -5...5)), isPinned: false
            ))
            nextID += 1
        }
        for _ in 0..<2 {
            cards.append(Card(
                id: nextID, kind: .sticker(Palette.colors[random.nextInt(Palette.colors.count)]),
                caption: Board.stickerWords[random.nextInt(Board.stickerWords.count)],
                center: place(200...780, 140...520), size: Size(width: 110, height: 110),
                scale: 1, rotation: .degrees(random.nextDouble(in: -12...12)), isPinned: false
            ))
            nextID += 1
        }
        return Board(id: id, name: name, cards: cards, seed: seed &+ 1)
    }
}

// MARK: - Helpers

/// A small deterministic generator, so the boards come out the same every
/// launch.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E3779B97F4A7C15 | 1
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextDouble()
    }

    mutating func nextInt(_ upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }
}

/// A colour from hue, saturation and brightness, each 0…1.
func hsb(_ hue: Double, _ saturation: Double, _ brightness: Double) -> Color {
    let h = (hue - hue.rounded(.down)) * 6
    let s = min(max(saturation, 0), 1)
    let v = min(max(brightness, 0), 1)
    let sector = Int(h) % 6
    let f = h - Double(Int(h))
    let p = v * (1 - s)
    let q = v * (1 - s * f)
    let t = v * (1 - s * (1 - f))
    let (r, g, b): (Double, Double, Double)
    switch sector {
    case 0: (r, g, b) = (v, t, p)
    case 1: (r, g, b) = (q, v, p)
    case 2: (r, g, b) = (p, v, t)
    case 3: (r, g, b) = (p, q, v)
    case 4: (r, g, b) = (t, p, v)
    default: (r, g, b) = (v, p, q)
    }
    return Color(red: r, green: g, blue: b)
}
