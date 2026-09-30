//
//  Layouts.swift
//  Bookmarks
//
//  The app's own containers, each a `Layout`:
//
//  * `ShelfLayout` — the cards as a masonry (columns of a set width, each
//    card dropped into whichever column is shortest, a card marked with
//    `ColumnSpan` 2 across two) or as a list, and anywhere in between. Its
//    `animatableData` is the column width and how far it is towards the
//    list, so zooming animates the cards growing and the columns reflowing,
//    and switching to the list moves every card from its place in the
//    masonry to its row, laid out afresh at each frame.
//  * `BookmarkTileLayout` — one bookmark's pieces as a card or a row, and
//    anywhere in between, the same way.
//  * `FlowLayout` — tags, left to right, wrapping onto a new line when the
//    next one wouldn't fit.
//  * `EqualWidthHStack` — a row of buttons all as wide as the widest.
//

import NucleantUI

/// How many of a `ShelfLayout`'s masonry columns a card spans.
struct ColumnSpan: LayoutValueKey {
    static let defaultValue = 1
}

struct ShelfLayout: Layout {
    /// The masonry's column width.
    var columnWidth: Double
    /// 0 for the masonry, 1 for the list, and in between while it morphs.
    var listness: Double
    var spacing: Double = 14
    var rowSpacing: Double = 6

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(columnWidth, listness) }
        set {
            columnWidth = newValue.first
            listness = newValue.second
        }
    }

    /// The last arrangement and what it was made for: a pass asks for the
    /// size and then places, both at the same width, and an arrangement
    /// measures every card twice.
    struct Cache {
        var key: [Double?] = []
        var arrangement = Arrangement()
    }

    struct Arrangement {
        var frames: [Rect] = []
        var size = Size.zero
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // A card changed, came or went: everything after it moves.
        cache = Cache()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> Size {
        arrangement(width: proposal.width, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: Rect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let arrangement = arrangement(width: bounds.width, subviews: subviews, cache: &cache)
        for (index, subview) in subviews.enumerated() {
            let frame = arrangement.frames[index]
            subview.place(
                at: Point(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: nil)
            )
        }
    }

    private func arrangement(width: Double?, subviews: Subviews, cache: inout Cache) -> Arrangement {
        let key = [width, columnWidth, listness, Double(subviews.count)]
        if cache.key == key { return cache.arrangement }
        let available = width ?? (columnWidth * 3 + spacing * 2)
        let columns = max(1, Int((available + spacing) / (columnWidth + spacing)))

        // Each card is measured once, at the width it has at this point
        // between its column and the full row, and that height stands for
        // it in both arrangements: the heights the positions are worked out
        // from are the ones drawn.
        var spans: [Int] = []
        var heights: [Double] = []
        for subview in subviews {
            let span = min(max(1, subview[ColumnSpan.self]), columns)
            let width = mix(columnSpanWidth(span), available)
            spans.append(span)
            heights.append(subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
        }

        let masonry = listness < 1 ? masonry(width: available, columns: columns, spans: spans, heights: heights) : nil
        let list = listness > 0 ? list(width: available, heights: heights) : nil
        let result: Arrangement
        if let masonry, let list {
            // Each card the same fraction of the way from its place in one
            // to its place in the other.
            result = Arrangement(
                frames: zip(masonry.frames, list.frames).map { mix($0, $1) },
                size: Size(width: available, height: mix(masonry.size.height, list.size.height))
            )
        } else {
            result = masonry ?? list!
        }
        cache.key = key
        cache.arrangement = result
        return result
    }

    /// Exactly `a` at 0 and exactly `b` at 1.
    private func mix(_ a: Double, _ b: Double) -> Double {
        a * (1 - listness) + b * listness
    }

    private func mix(_ a: Rect, _ b: Rect) -> Rect {
        Rect(x: mix(a.minX, b.minX), y: mix(a.minY, b.minY), width: mix(a.width, b.width), height: mix(a.height, b.height))
    }

    private func columnSpanWidth(_ span: Int) -> Double {
        Double(span) * columnWidth + Double(span - 1) * spacing
    }

    /// Columns of `columnWidth`, the block of them centred; each card in
    /// whichever run of columns is shortest, a `ColumnSpan` 2 card across
    /// two.
    private func masonry(width: Double, columns: Int, spans: [Int], heights: [Double]) -> Arrangement {
        let used = columnSpanWidth(columns)
        let left = max(0, (width - used) / 2)

        var tops = [Double](repeating: 0, count: columns)
        var frames: [Rect] = []
        for (span, height) in zip(spans, heights) {
            var best = 0
            var bestTop = Double.infinity
            for start in 0...(columns - span) {
                let top = tops[start..<(start + span)].max() ?? 0
                if top < bestTop {
                    best = start
                    bestTop = top
                }
            }
            frames.append(Rect(
                x: left + Double(best) * (columnWidth + spacing),
                y: bestTop,
                width: columnSpanWidth(span),
                height: height
            ))
            for column in best..<(best + span) {
                tops[column] = bestTop + height + spacing
            }
        }
        return Arrangement(frames: frames, size: Size(width: width, height: max(0, (tops.max() ?? 0) - spacing)))
    }

    /// One card under another, full width.
    private func list(width: Double, heights: [Double]) -> Arrangement {
        var y = 0.0
        var frames: [Rect] = []
        for height in heights {
            frames.append(Rect(x: 0, y: y, width: width, height: height))
            y += height + rowSpacing
        }
        return Arrangement(frames: frames, size: Size(width: width, height: max(0, y - rowSpacing)))
    }
}

struct FlowLayout: Layout {
    var spacing: Double = 6
    var lineSpacing: Double = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> Size {
        let lines = lines(width: proposal.width ?? .infinity, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.map(\.height).reduce(0, +) + lineSpacing * Double(max(0, lines.count - 1))
        return Size(width: width, height: height)
    }

    func placeSubviews(in bounds: Rect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in zip(line.indices, line.sizes) {
                // Each item centred on its line, so a smaller chip sits
                // level with a taller one beside it.
                subviews[index].place(
                    at: Point(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var sizes: [Size] = []
        var width = 0.0
        var height = 0.0
    }

    private func lines(width: Double, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            // One too wide for any line gets a line of its own, at the width.
            if size.width > width + 0.5 {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            let widthWithItem = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            // Half a point of slack: a flow proposed exactly the width it
            // asked for must not break its line over a rounding error.
            if widthWithItem > width + 0.5, !line.indices.isEmpty {
                lines.append(line)
                line = Line()
            }
            line.width = line.indices.isEmpty ? size.width : line.width + spacing + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
            line.sizes.append(size)
        }
        if !line.indices.isEmpty { lines.append(line) }
        return lines
    }
}

/// Buttons side by side, all the same width — the widest's when nothing
/// says otherwise, an equal share of the width offered when something
/// does — with the gap the buttons themselves ask for between them.
struct EqualWidthHStack: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> Size {
        guard !subviews.isEmpty else { return .zero }
        let widest = widest(subviews)
        let gaps = gaps(subviews).reduce(0, +)
        // All of an offered width, shared out in `placeSubviews`; with none
        // offered, each as wide as the widest.
        let ideal = widest.width * Double(subviews.count) + gaps
        let width = proposal.width.map { $0.isFinite ? $0 : ideal } ?? ideal
        return Size(width: width, height: widest.height)
    }

    func placeSubviews(in bounds: Rect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let gaps = gaps(subviews)
        // Share the bounds out equally, so the row can fill a wider pane.
        let width = (bounds.width - gaps.reduce(0, +)) / Double(subviews.count)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: Point(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: width, height: bounds.height)
            )
            x += width + (index < gaps.count ? gaps[index] : 0)
        }
    }

    private func widest(_ subviews: Subviews) -> Size {
        subviews.reduce(Size.zero) { result, subview in
            let size = subview.sizeThatFits(.unspecified)
            return Size(width: max(result.width, size.width), height: max(result.height, size.height))
        }
    }

    private func gaps(_ subviews: Subviews) -> [Double] {
        subviews.indices.dropLast().map { index in
            subviews[index].spacing.distance(to: subviews[index + 1].spacing, along: .horizontal)
        }
    }
}

/// One bookmark's pieces, arranged as a card, as a list row, or anywhere
/// in between: `compactness` 0 is the card, 1 the row. Each piece is placed
/// at the same fraction of the way from where the card puts it to where the
/// row does, worked out for the bounds it has this frame — so while the
/// card morphs, every piece travels with it, and a text proposed a width in
/// between wraps to that width.
///
/// The subviews, in order: badge, site, star, title, summary, tags,
/// reading time, unread mark. The row has no room for the summary; it is
/// placed over the title there, and the card fades it out.
struct BookmarkTileLayout: Layout {
    var compactness: Double

    private enum Piece: Int, CaseIterable {
        case badge, site, star, title, summary, tags, time, unread
    }

    private struct Arrangement {
        var frames: [Rect]
        var height: Double
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> Size {
        let width = proposal.width ?? 320
        let card = cardArrangement(width: width, subviews: subviews)
        let row = rowArrangement(width: width, subviews: subviews)
        return Size(width: width, height: mix(card.height, row.height))
    }

    func placeSubviews(in bounds: Rect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let card = cardArrangement(width: bounds.width, subviews: subviews)
        let row = rowArrangement(width: bounds.width, subviews: subviews)
        for piece in Piece.allCases where piece.rawValue < subviews.count {
            let from = card.frames[piece.rawValue]
            let to = row.frames[piece.rawValue]
            let width = mix(from.width, to.width)
            subviews[piece.rawValue].place(
                at: Point(x: bounds.minX + mix(from.minX, to.minX), y: bounds.minY + mix(from.minY, to.minY)),
                proposal: ProposedViewSize(width: width, height: nil)
            )
        }
    }

    /// Exactly `a` at 0 and exactly `b` at 1 — a width that is one ulp
    /// short of the one measured would wrap a line that fit.
    private func mix(_ a: Double, _ b: Double) -> Double {
        a * (1 - compactness) + b * compactness
    }

    private func size(_ subviews: Subviews, _ piece: Piece, width: Double? = nil) -> Size {
        guard piece.rawValue < subviews.count else { return .zero }
        return subviews[piece.rawValue].sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    /// Badge, site, unread mark and star across the top; the title,
    /// summary and tags under them at full width; the reading time at the
    /// foot, on the right. Each piece is on the side it has in the row, so
    /// on the way between the two nothing crosses anything else.
    private func cardArrangement(width: Double, subviews: Subviews) -> Arrangement {
        let pad = 14.0, gap = 9.0
        let inner = max(0, width - pad * 2)
        var frames = [Rect](repeating: .zero, count: Piece.allCases.count)

        let badge = size(subviews, .badge)
        let star = size(subviews, .star)
        let unread = size(subviews, .unread)
        let siteWidth = max(0, inner - badge.width - 8 - unread.width - 8 - star.width - 6)
        let site = size(subviews, .site, width: siteWidth)
        let top = max(badge.height, site.height, unread.height)
        func topRow(_ x: Double, _ size: Size, width: Double? = nil) -> Rect {
            Rect(x: x, y: pad + (top - size.height) / 2, width: width ?? size.width, height: size.height)
        }
        frames[Piece.badge.rawValue] = topRow(pad, badge)
        frames[Piece.site.rawValue] = topRow(pad + badge.width + 8, site, width: siteWidth)
        let starX = width - pad - star.width
        frames[Piece.star.rawValue] = topRow(starX, star)
        frames[Piece.unread.rawValue] = topRow(starX - 6 - unread.width, unread)
        var y = pad + top + gap

        for piece in [Piece.title, .summary, .tags] {
            let measured = size(subviews, piece, width: inner)
            frames[piece.rawValue] = Rect(x: pad, y: y, width: inner, height: measured.height)
            if measured.height > 0 { y += measured.height + gap }
        }

        let time = size(subviews, .time)
        frames[Piece.time.rawValue] = Rect(x: width - pad - time.width, y: y, width: time.width, height: time.height)
        return Arrangement(frames: frames, height: y + time.height + pad)
    }

    /// One line: the badge, the site over the title, then from the right
    /// edge in, the star, unread mark, reading time and tags.
    private func rowArrangement(width: Double, subviews: Subviews) -> Arrangement {
        let padX = 12.0, padY = 8.0, gap = 10.0
        var frames = [Rect](repeating: .zero, count: Piece.allCases.count)

        let badge = size(subviews, .badge)
        let unread = size(subviews, .unread)
        let time = size(subviews, .time)
        let star = size(subviews, .star)
        let tags = size(subviews, .tags)

        var right = width - padX
        let starX = right - star.width
        right = starX - 6
        let unreadX = right - unread.width
        right = unreadX - gap
        let timeX = right - time.width
        right = timeX - gap
        let tagsX = tags.width > 0 ? right - tags.width : right
        right = tags.width > 0 ? tagsX - gap : right

        let textX = padX + badge.width + gap
        let textWidth = max(0, right - textX)
        let title = size(subviews, .title, width: textWidth)
        let site = size(subviews, .site, width: textWidth)
        let text = title.height + 2 + site.height
        let content = max(badge.height, text, tags.height, time.height, unread.height)

        func centred(_ x: Double, _ size: Size, width: Double? = nil) -> Rect {
            Rect(x: x, y: padY + (content - size.height) / 2, width: width ?? size.width, height: size.height)
        }
        frames[Piece.badge.rawValue] = centred(padX, badge)
        // The site over the title, as on the card, so the two slide into
        // place without crossing.
        let textY = padY + (content - text) / 2
        frames[Piece.site.rawValue] = Rect(x: textX, y: textY, width: textWidth, height: site.height)
        frames[Piece.title.rawValue] = Rect(x: textX, y: textY + site.height + 2, width: textWidth, height: title.height)
        frames[Piece.summary.rawValue] = Rect(x: textX, y: textY + site.height + 2, width: textWidth, height: title.height)
        frames[Piece.tags.rawValue] = centred(tagsX, tags)
        frames[Piece.star.rawValue] = centred(starX, star)
        frames[Piece.time.rawValue] = centred(timeX, time)
        frames[Piece.unread.rawValue] = centred(unreadX, unread)
        return Arrangement(frames: frames, height: content + padY * 2)
    }
}
