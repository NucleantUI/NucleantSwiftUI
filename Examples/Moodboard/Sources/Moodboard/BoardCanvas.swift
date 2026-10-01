//
//  BoardCanvas.swift
//  Moodboard
//
//  The board: its cards, and everything you do to them with a pointer, a
//  trackpad or the keys.
//
//  * A card is dragged to move it, pinched to size it and twisted to turn
//    it — `DragGesture`, `MagnifyGesture` and a `RotateGesture` alongside
//    (`.simultaneousGesture`), so a pinch can turn as it scales. Its own
//    pinch goes before the board's (`.gesture` on the card, inside the
//    board's), so pinching a card sizes the card, and pinching the empty
//    board zooms the board.
//  * A double click puts a card back to its own size, upright
//    (`TapGesture(count: 2)`); holding it pins it in place
//    (`.onLongPressGesture`), and the press that starts the hold selects
//    it and lifts it a little.
//  * With Lock Photos on, the photos stop taking input at all
//    (`.allowsHitTesting(false)`): clicks, drags and pinches go through to
//    the notes, stickers and board under them.
//  * A sticker takes presses only inside its circle (`.contentShape`).
//  * While presenting, a click anywhere — on a card too — shows the next
//    card: a `.highPriorityGesture` on the board, which goes before every
//    gesture of the cards inside it.
//  * The board is `.focusable()`, `.focused` through the window's
//    `@FocusState`, and handles its keys with `.onKeyPress`.
//

import Foundation
import NucleantUI

@View
struct BoardCanvas {
    let board: Board
    @FocusState.Binding var focus: Field?
    /// The board's own pinch, while it is in progress.
    @State private var pinch = 1.0

    var body: some View {
        let board = self.board
        ZStack(alignment: .topLeading) {
            ForEach(board.cards) { card in
                CardView(
                    board: board,
                    card: card,
                    isSelected: board.selectedCard?.id == card.id,
                    isLocked: board.photosLocked && card.isPhoto,
                    isDimmed: board.isPresenting && board.presentedCard?.id != card.id
                )
            }
        }
        .scaleEffect(board.zoom * pinch, anchor: .topLeading)
        .animation(.easeInOut(duration: 0.3), value: board.presentedCard?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(Theme.canvas)
        .overlay(alignment: .bottom) {
            HintBar(isPresenting: board.isPresenting, photosLocked: board.photosLocked)
                .padding(.bottom, 14)
        }
        .overlay(alignment: .top) {
            if let card = board.presentedCard, let index = board.cards.firstIndex(of: card) {
                SlideCaption(index: index, count: board.cards.count, card: card)
                    .padding(.top, 16)
            }
        }
        // A click on the empty board clears the selection; the cards'
        // own gestures go first.
        .gesture(TapGesture().onEnded { board.select(nil) })
        .gesture(
            MagnifyGesture()
                .onChanged { value in pinch = value.magnification }
                .onEnded { value in
                    board.zoom(by: value.magnification)
                    pinch = 1
                }
        )
        // Presenting: a click anywhere is "next" — before any card's
        // gestures, which wait for it and lose.
        .highPriorityGesture(
            TapGesture().onEnded { board.showNext() },
            isEnabled: board.isPresenting
        )
        .focusable()
        .focused($focus, equals: .board)
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            arrow(press)
        }
        .onKeyPress(.delete) {
            guard !board.isPresenting, board.selectedCard != nil else { return .ignored }
            board.deleteSelection()
            return .handled
        }
        .onKeyPress(.escape) {
            if board.isPresenting {
                board.stopPresenting()
            } else {
                board.select(nil)
            }
            return .handled
        }
        .onKeyPress(.space) {
            guard board.isPresenting else { return .ignored }
            board.showNext()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "[]+=-0n")) { press in
            character(press)
        }
    }

    /// Arrows nudge the selected card a point, ten with ⇧ — or, while
    /// presenting, step through the cards.
    private func arrow(_ press: KeyPress) -> KeyPress.Result {
        if board.isPresenting {
            if press.key == .leftArrow || press.key == .upArrow {
                board.showPrevious()
            } else {
                board.showNext()
            }
            return .handled
        }
        guard board.selectedCard != nil else { return .ignored }
        let step = press.modifiers.contains(.shift) ? 10.0 : 1.0
        switch press.key {
        case .upArrow: board.nudgeSelection(dx: 0, dy: -step)
        case .downArrow: board.nudgeSelection(dx: 0, dy: step)
        case .leftArrow: board.nudgeSelection(dx: -step, dy: 0)
        default: board.nudgeSelection(dx: step, dy: 0)
        }
        return .handled
    }

    /// `[` `]` turn the selected card, `+` `-` size it, `0` puts the zoom
    /// back, `n` goes to the new-note field.
    private func character(_ press: KeyPress) -> KeyPress.Result {
        if press.characters == "n" {
            focus = .newNote
            return .handled
        }
        if press.characters == "0" {
            withAnimation(.snappy) { board.resetZoom() }
            return .handled
        }
        guard !board.isPresenting, let card = board.selectedCard, !card.isPinned else { return .ignored }
        switch press.characters {
        case "[": board.rotate(card.id, by: .degrees(-15))
        case "]": board.rotate(card.id, by: .degrees(15))
        case "+", "=": board.scale(card.id, by: 1.1)
        case "-": board.scale(card.id, by: 1 / 1.1)
        default: return .ignored
        }
        return .handled
    }
}

// MARK: - A card

/// One card on the board, with its gestures. What a gesture is doing right
/// now — how far the drag has gone, the pinch, the twist, whether a press
/// is down — is this view's own state; what it ends as goes to the board.
@View
struct CardView {
    let board: Board
    let card: Card
    let isSelected: Bool
    /// Photos are locked: this card lets every press through.
    let isLocked: Bool
    /// Another card is being presented.
    let isDimmed: Bool

    @State private var drag = Size.zero
    @State private var pinch = 1.0
    @State private var twist = Angle.zero
    @State private var isLifted = false
    /// The pointer the drag follows — on a touch screen, a second finger
    /// on the card is the pinch's, not the drag's.
    @State private var dragPointer: Int? = nil

    var body: some View {
        let board = self.board
        let id = card.id
        let editable = !card.isPinned && !board.isPresenting
        // The drag is measured in the card's own space — scaled and turned
        // with it — as it was when the press began.
        let scale = card.scale
        let turn = card.rotation
        let round: Bool = {
            if case .sticker = card.kind { return true }
            return false
        }()

        CardFace(card: card, isSelected: isSelected)
            .contentShape(CardShape(isRound: round))
            .gesture(
                MagnifyGesture()
                    .onChanged { value in pinch = value.magnification }
                    .onEnded { value in
                        board.scale(id, by: value.magnification)
                        pinch = 1
                    },
                isEnabled: editable
            )
            .simultaneousGesture(
                RotateGesture()
                    .onChanged { value in twist = value.rotation }
                    .onEnded { value in
                        board.rotate(id, by: value.rotation)
                        twist = .zero
                    },
                isEnabled: editable
            )
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if dragPointer == nil { dragPointer = value.id }
                        guard value.id == dragPointer else { return }
                        drag = Self.onBoard(value.translation, scale: scale, turn: turn)
                    }
                    .onEnded { value in
                        guard value.id == dragPointer else { return }
                        board.move(id, by: Self.onBoard(value.translation, scale: scale, turn: turn))
                        drag = .zero
                        dragPointer = nil
                    },
                isEnabled: editable
            )
            .gesture(
                TapGesture(count: 2).onEnded {
                    withAnimation(.snappy) { board.resetTransform(id) }
                },
                isEnabled: editable
            )
            // The card's own click — without it, a single click that is no
            // double click would fall through to the board's, which clears
            // the selection.
            .gesture(TapGesture().onEnded { board.select(id) }, isEnabled: editable)
            .onLongPressGesture(minimumDuration: 0.45) {
                guard !board.isPresenting else { return }
                withAnimation(.bouncy) { board.togglePin(id) }
            } onPressingChanged: { pressing in
                guard !board.isPresenting else { return }
                isLifted = pressing
                if pressing { board.select(id) }
            }
            .allowsHitTesting(!isLocked)
            .scaleEffect(scale * pinch * (isLifted ? 1.04 : 1))
            .rotationEffect(turn + twist)
            .opacity(isDimmed ? 0.12 : (isLocked ? 0.85 : 1))
            .offset(
                x: card.center.x - card.size.width / 2 + drag.width,
                y: card.center.y - card.size.height / 2 + drag.height
            )
    }

    /// A translation in the card's own space — scaled by `scale`, turned
    /// by `turn` — as a move on the board.
    private static func onBoard(_ translation: Size, scale: Double, turn: Angle) -> Size {
        let c = cos(turn.radians)
        let s = sin(turn.radians)
        return Size(
            width: scale * (translation.width * c - translation.height * s),
            height: scale * (translation.width * s + translation.height * c)
        )
    }
}

// MARK: - Overlays

/// What you can do, along the bottom of the board. Drawn only — it takes
/// no input.
@View
struct HintBar {
    let isPresenting: Bool
    let photosLocked: Bool

    var body: some View {
        Text(hint)
            .font(.system(size: 12))
            .foregroundColor(Color(white: 1, opacity: 0.92))
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .background(Capsule().fill(Color(white: 0, opacity: 0.55)))
    }

    private var hint: String {
        if isPresenting {
            return "Click anywhere or Space: next card  ·  arrow keys step  ·  Esc stops"
        }
        let base = "Drag · pinch · twist  ·  double-click resets  ·  hold pins  ·  arrows nudge  ·  [ ] turn  ·  + − size  ·  n note"
        return photosLocked ? "Photos locked  ·  " + base : base
    }
}

/// "3 of 10 — Harbour at dawn", over the board while presenting.
@View
struct SlideCaption {
    let index: Int
    let count: Int
    let card: Card

    var body: some View {
        let title: String = {
            switch card.kind {
            case .note(let text, _): return text
            default: return card.caption
            }
        }()
        Text("\(index + 1) of \(count)  —  \(title)")
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .padding(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .background(Capsule().fill(Color(white: 0, opacity: 0.6)))
    }
}
