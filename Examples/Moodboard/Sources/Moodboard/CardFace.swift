//
//  CardFace.swift
//  Moodboard
//
//  What a card looks like: a bordered photo with its caption, a paper
//  note, or a round sticker — and the shape a press must land in to reach
//  it, which for a sticker is its circle, not its square.
//

import NucleantUI

/// One card, drawn at its own size, before any scale or turn.
@View
struct CardFace {
    let card: Card
    let isSelected: Bool

    var body: some View {
        face
            .frame(width: card.size.width, height: card.size.height)
            .overlay(
                CardShape(isRound: isRound)
                    .stroke(isSelected ? Theme.accent : Color.clear, lineWidth: 3)
            )
            .overlay(alignment: .topTrailing) {
                if card.isPinned {
                    Pin().padding(isRound ? 12 : 6)
                }
            }
    }

    private var isRound: Bool {
        if case .sticker = card.kind { return true }
        return false
    }

    @ViewBuilder
    private var face: some View {
        switch card.kind {
        case .photo(let picture):
            VStack(spacing: 6) {
                PictureArt(picture: picture)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(card.caption)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(white: 0.25))
                    .lineLimit(1)
            }
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 8, trailing: 10))
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.98)))
            .border(Color(white: 0, opacity: 0.12), width: 1, cornerRadius: 4)
        case .note(let text, let paper):
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Color(white: 0.18))
                if !card.caption.isEmpty {
                    Text(card.caption)
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.35))
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 3).fill(paper))
            .border(Color(white: 0, opacity: 0.10), width: 1, cornerRadius: 3)
        case .sticker(let color):
            ZStack {
                Circle().fill(color)
                Circle().stroke(Color.white, lineWidth: 4)
                Text(card.caption)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }
}

/// A card's outline: a slightly rounded rectangle, or a circle for a
/// sticker. Drawn as the selection ring, and used as the card's
/// `.contentShape` — a click on a sticker's corner reaches whatever is
/// under it.
@View
struct CardShape: Shape {
    let isRound: Bool

    func path(in rect: Rect) -> Path {
        var path = Path()
        if isRound {
            path.addEllipse(in: rect)
        } else {
            path.addRoundedRect(rect, radiusX: 4, radiusY: 4)
        }
        return path
    }
}

/// The red pin on a pinned card.
@View
struct Pin {
    var body: some View {
        ZStack {
            Circle().fill(Color(hex: 0xE5484D))
            Circle().fill(Color(white: 1, opacity: 0.55))
                .frame(width: 5, height: 5)
                .offset(x: -2, y: -2)
        }
        .frame(width: 14, height: 14)
    }
}

// MARK: - Pictures

/// A picture drawn to fill whatever frame it is given.
@View
struct PictureArt {
    let picture: Picture

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.linearGradient(colors: [picture.skyTop, picture.skyBottom]))
            Sun(position: picture.sunPosition)
                .fill(picture.sun)
            Ridge(heights: picture.farRidge)
                .fill(picture.farHills)
            Ridge(heights: picture.nearRidge)
                .fill(picture.nearHills)
        }
        .clipped()
    }
}

/// A disc a tenth of the picture's shorter side across, at `position`.
@View
struct Sun: Shape {
    let position: UnitPoint

    func path(in rect: Rect) -> Path {
        let radius = min(rect.width, rect.height) * 0.1
        let center = position.resolved(in: rect)
        var path = Path()
        path.addEllipse(in: Rect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        return path
    }
}

/// Hills through `heights` (fractions of the height, from the top), left
/// to right, smoothed, filled down to the bottom edge.
@View
struct Ridge: Shape {
    let heights: [Double]

    func path(in rect: Rect) -> Path {
        var path = Path()
        guard heights.count > 1 else { return path }
        let step = rect.width / Double(heights.count - 1)
        func point(_ index: Int) -> Point {
            Point(x: rect.minX + step * Double(index), y: rect.minY + rect.height * heights[index])
        }
        path.move(to: Point(x: rect.minX, y: rect.maxY))
        path.addLine(to: point(0))
        for index in 1..<heights.count {
            let from = point(index - 1)
            let to = point(index)
            path.addCurve(
                to: to,
                control1: Point(x: from.x + step / 2, y: from.y),
                control2: Point(x: to.x - step / 2, y: to.y)
            )
        }
        path.addLine(to: Point(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
