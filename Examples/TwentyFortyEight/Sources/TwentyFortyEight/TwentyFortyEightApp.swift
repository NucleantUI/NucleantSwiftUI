//
//  TwentyFortyEightApp.swift
//  TwentyFortyEight
//
//  The sliding-tile game. A DragGesture over the board turns a swipe into
//  a move (direction from `translation` on release); arrow buttons do the
//  same for a mouse. The board is a value type the view rebuilds from, so
//  the whole game is one `@State`.
//

import Foundation
import NucleantSwiftUI

// MARK: - Game

enum Direction { case up, down, left, right }

struct Board: Equatable {
    static let size = 4

    /// Row-major, 0 for an empty cell.
    private(set) var cells = [Int](repeating: 0, count: size * size)
    private(set) var score = 0
    private(set) var best = 0

    var isWon: Bool { cells.contains(2048) }

    var isStuck: Bool {
        if cells.contains(0) { return false }
        for d in [Direction.left, .up] where slid(d).cells != cells { return false }
        return true
    }

    subscript(row: Int, column: Int) -> Int {
        cells[row * Board.size + column]
    }

    static func fresh(best: Int = 0) -> Board {
        var board = Board()
        board.best = best
        board.spawn()
        board.spawn()
        return board
    }

    /// Slide and merge in `direction`; a move that changes nothing is
    /// ignored so no tile spawns for it.
    mutating func move(_ direction: Direction) {
        let next = slid(direction)
        guard next.cells != cells else { return }
        self = next
        spawn()
        best = max(best, score)
    }

    private func slid(_ direction: Direction) -> Board {
        var result = self
        let n = Board.size
        for line in 0..<n {
            // Read one row or column in the slide direction.
            var indices: [Int] = (0..<n).map { i in
                switch direction {
                case .left:  return line * n + i
                case .right: return line * n + (n - 1 - i)
                case .up:    return i * n + line
                case .down:  return (n - 1 - i) * n + line
                }
            }
            var values = indices.map { cells[$0] }.filter { $0 != 0 }
            var merged: [Int] = []
            var i = 0
            while i < values.count {
                if i + 1 < values.count, values[i] == values[i + 1] {
                    merged.append(values[i] * 2)
                    result.score += values[i] * 2
                    i += 2
                } else {
                    merged.append(values[i])
                    i += 1
                }
            }
            values = merged + [Int](repeating: 0, count: n - merged.count)
            for (k, index) in indices.enumerated() {
                result.cells[index] = values[k]
            }
            indices.removeAll()
        }
        return result
    }

    private mutating func spawn() {
        let empty = cells.indices.filter { cells[$0] == 0 }
        guard let slot = empty.randomElement() else { return }
        cells[slot] = Int.random(in: 0..<10) == 0 ? 4 : 2
    }
}

// MARK: - Look

/// The board and the low tiles have a light and a dark face — the light
/// ones are the game's classic beige — while the warm high tiles are the
/// same in both.
struct Theme {
    static let background = Color.background
    static let board = Color.dynamic(light: Color(hex: 0xBBADA0), dark: Color(hex: 0x2A2E38))
    static let empty = Color.dynamic(light: Color(hex: 0xCDC1B4), dark: Color(hex: 0x363B47))
    static let accent = Color(hex: 0xFF9F0A)
    static let muted = Color.dynamic(light: Color(white: 0.55), dark: Color(white: 0.3))

    static func tile(_ value: Int) -> Color {
        switch value {
        case 2:    return Color.dynamic(light: Color(hex: 0xEEE4DA), dark: Color(hex: 0x4A5568))
        case 4:    return Color.dynamic(light: Color(hex: 0xEDE0C8), dark: Color(hex: 0x5A6A85))
        case 8:    return Color(hex: 0xF2B179)
        case 16:   return Color(hex: 0xF59563)
        case 32:   return Color(hex: 0xF67C5F)
        case 64:   return Color(hex: 0xF65E3B)
        case 128:  return Color(hex: 0xEDCF72)
        case 256:  return Color(hex: 0xEDCC61)
        case 512:  return Color(hex: 0xEDC850)
        case 1024: return Color(hex: 0xEDC53F)
        case 2048: return Color(hex: 0xEDC22E)
        default:   return Color(hex: 0x3C3A32)
        }
    }

    static func tileText(_ value: Int) -> Color {
        value <= 4 ? Color.dynamic(light: Color(hex: 0x776E65), dark: Color(hex: 0xE6E9EF)) : Color(hex: 0x1C1F26)
    }
}

@View
struct Tile {
    let value: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(value == 0 ? Theme.empty : Theme.tile(value))
            if value != 0 {
                Text("\(value)")
                    .font(.system(size: value < 100 ? 30 : (value < 1000 ? 26 : 22), weight: .bold))
                    .foregroundColor(Theme.tileText(value))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@View
struct BoardView {
    let board: Board
    let onMove: (Direction) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(0..<Board.size) { row in
                HStack(spacing: 10) {
                    ForEach(0..<Board.size) { column in
                        Tile(value: board[row, column])
                    }
                }
            }
        }
        .padding(10)
        .background(Theme.board)
        .cornerRadius(12)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > 20 || abs(dy) > 20 else { return }
                    if abs(dx) > abs(dy) {
                        onMove(dx > 0 ? .right : .left)
                    } else {
                        onMove(dy > 0 ? .down : .up)
                    }
                }
        )
    }
}

@View
struct ScoreBox {
    let title: String
    let value: Int

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Text("\(value)")
                .font(.system(size: 20, weight: .bold, design: .monospaced))
        }
        .frame(width: 84)
        .padding(vertical: 8)
        .background(Theme.board)
        .cornerRadius(8)
    }
}

// MARK: - Screen

@View
struct GameView {
    @State private var board = Board.fresh()
    @Environment(\.colorScheme) private var system

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                Text("2048").font(.system(size: 36, weight: .bold))
                Spacer()
                ScoreBox(title: "SCORE", value: board.score)
                ScoreBox(title: "BEST", value: board.best)
            }
            HStack {
                Text(status).font(.footnote).foregroundColor(.secondary)
                Spacer()
            }
            .frame(width: 400)

            BoardView(board: board) { direction in board.move(direction) }
                .frame(width: 400, height: 400)

            HStack(spacing: 10) {
                Button("New game") { board = Board.fresh(best: board.best) }
                    .tint(Theme.accent)
                Spacer()
                arrows
            }
            .frame(width: 400)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .colorScheme(AppearanceModel.shared.appearance.scheme ?? system)
    }

    var status: String {
        if board.isWon { return "You made 2048 — keep going or start over." }
        if board.isStuck { return "No moves left." }
        return "Swipe, or use the arrows."
    }

    var arrows: some View {
        HStack(spacing: 6) {
            Button("←") { board.move(.left) }
            Button("↑") { board.move(.up) }
            Button("↓") { board.move(.down) }
            Button("→") { board.move(.right) }
        }
        .tint(Theme.muted)
        .disabled(board.isStuck)
    }
}

@main
struct TwentyFortyEightApp: NucleantApp {
    var body: some Scene {
        WindowGroup("2048", width: 460, height: 660) {
            GameView()
        }
        .commands { AppearanceCommands() }
    }
}
