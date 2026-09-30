//
//  Shelf.swift
//  Bookmarks
//
//  The bookmarks of the chosen scope, as cards or as a list.
//
//  Both are one `ShelfLayout` over the same `ForEach`, and switching
//  animates one number, how far the shelf is towards the list, which is
//  both the layout's `animatableData` and each card's (`compactness`). At
//  every frame the shelf is laid out at that point between masonry and
//  list, and each card at that point between card and row: the whole card
//  moves and changes shape as one, its pieces travelling inside it and its
//  text re-wrapping to the width it has on the way. The zoom buttons
//  animate the other half of the layout's `animatableData`, the column
//  width, the same way.
//
//  Every card sets a `ShelfTotals` preference for its own bookmark; the
//  sum over the cards on the shelf is what the status bar shows. The shelf
//  also names itself to the window bar with a `ScreenTitle`.
//

import NucleantUI

/// What the cards on the shelf add up to.
struct ShelfTotals: Equatable {
    var count = 0
    var unread = 0
    var minutes = 0
}

/// Summed over every card on the shelf.
struct ShelfTotalsKey: PreferenceKey {
    static let defaultValue = ShelfTotals()

    static func reduce(value: inout ShelfTotals, nextValue: () -> ShelfTotals) {
        let next = nextValue()
        value.count += next.count
        value.unread += next.unread
        value.minutes += next.minutes
    }
}

enum ShelfMode: Hashable, CaseIterable, Identifiable {
    case cards, list

    var id: Self { self }

    var name: String {
        switch self {
        case .cards: return "Cards"
        case .list:  return "List"
        }
    }
}

@View
struct Shelf {
    let library: Library
    let scope: Scope
    let query: String
    @Binding var selection: Bookmark.ID?

    @State private var mode: ShelfMode = .cards
    @State private var columnWidth = 250.0
    @State private var totals = ShelfTotals()

    private static let columnWidths = 190.0...430.0

    var body: some View {
        let library = self.library
        let items = library.bookmarks(in: scope, matching: query)
        let listness: Double = mode == .list ? 1 : 0
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("View as", selection: Binding(
                    get: { mode },
                    set: { newValue in withAnimation(.smooth(duration: 0.5)) { mode = newValue } }
                )) {
                    ForEach(ShelfMode.allCases) { mode in
                        Text(mode.name)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                Spacer()
                Text("Card size")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Button("−") { zoom(by: -60) }
                    .disabled(mode != .cards || columnWidth <= Self.columnWidths.lowerBound)
                Button("+") { zoom(by: 60) }
                    .disabled(mode != .cards || columnWidth >= Self.columnWidths.upperBound)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            if items.isEmpty {
                VStack(spacing: 6) {
                    Text(query.isEmpty ? "Nothing here yet" : "No matches")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(query.isEmpty ? "Bookmarks you save or tag land here." : "Try another word, or another tag.")
                        .font(.system(size: 12))
                        .foregroundColor(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    ShelfLayout(columnWidth: columnWidth, listness: listness) {
                        ForEach(items) { bookmark in
                            BookmarkCard(
                                bookmark: bookmark,
                                isSelected: selection == bookmark.id,
                                compactness: listness
                            )
                            .layoutValue(key: ColumnSpan.self, value: bookmark.isFeatured ? 2 : 1)
                            .preference(key: ShelfTotalsKey.self, value: ShelfTotals(
                                count: 1,
                                unread: bookmark.isRead ? 0 : 1,
                                minutes: bookmark.readingMinutes
                            ))
                            .onTapGesture { selection = bookmark.id }
                            .contextMenu {
                                Button(bookmark.isRead ? "Mark as Unread" : "Mark as Read") {
                                    library.toggleRead(bookmark.id)
                                }
                                Button(bookmark.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                                    library.toggleFavorite(bookmark.id)
                                }
                                Button(bookmark.isFeatured ? "Show as Narrow Card" : "Show as Wide Card") {
                                    withAnimation(.smooth) { library.toggleFeatured(bookmark.id) }
                                }
                                Divider()
                                Button("Delete") {
                                    if selection == bookmark.id { selection = nil }
                                    library.delete(bookmark.id)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onPreferenceChange(ShelfTotalsKey.self) { totals = $0 }
            }

            Divider()
            StatusBar(totals: items.isEmpty ? ShelfTotals() : totals)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preference(key: ScreenTitleKey.self, value: ScreenTitle(
            title: query.isEmpty ? scope.title : "Results for “\(query)”",
            subtitle: query.isEmpty ? subtitle(for: scope) : "in \(scope.title)"
        ))
    }

    private func zoom(by delta: Double) {
        withAnimation(.smooth(duration: 0.45)) {
            columnWidth = min(Self.columnWidths.upperBound, max(Self.columnWidths.lowerBound, columnWidth + delta))
        }
    }

    private func subtitle(for scope: Scope) -> String {
        switch scope {
        case .all:       return "Everything you've saved, newest first"
        case .unread:    return "Saved and not read yet"
        case .favorites: return "The ones worth keeping"
        case .tag:       return "Tagged bookmarks, newest first"
        }
    }
}

/// The sum of what's on the shelf.
@View
struct StatusBar {
    let totals: ShelfTotals

    var body: some View {
        let hours = totals.minutes / 60
        let minutes = totals.minutes % 60
        let reading = hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
        HStack(spacing: 6) {
            Text("\(totals.count) \(totals.count == 1 ? "bookmark" : "bookmarks")")
            Text("·").foregroundColor(.tertiary)
            Text("\(totals.unread) unread")
            Text("·").foregroundColor(.tertiary)
            Text("\(reading) of reading")
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundColor(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(Theme.bar)
    }
}

// MARK: - A card

/// One bookmark, as a card in the grid (`compactness` 0) or a row in the
/// list (1). The shelf changes `compactness` under the same animation, and
/// on the same curve, as the `ShelfLayout`'s own; since it is this view's
/// `animatableData`, the body is built at every value in between: the
/// fonts and the badge ease from one size to the other, the summary fades,
/// and `BookmarkTileLayout` puts every piece at that point between its two
/// places. Every piece is the same view throughout — nothing is swapped for
/// a different one mid-way.
@View
struct BookmarkCard: Animatable {
    let bookmark: Bookmark
    let isSelected: Bool
    var compactness: Double

    var animatableData: Double {
        get { compactness }
        set { compactness = newValue }
    }

    var body: some View {
        let p = min(1, max(0, compactness))
        BookmarkTileLayout(compactness: p) {
            SiteBadge(bookmark: bookmark, size: blend(20, 24, p))
            Text(bookmark.host)
                .font(.system(size: blend(12, 11, p)))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Star()
                .fill(Theme.accent)
                .frame(width: 13, height: 13)
                .opacity(bookmark.isFavorite ? 1 : 0)
            Text(bookmark.title)
                .font(.system(size: blend(bookmark.isFeatured ? 19 : 15, 13, p), weight: .semibold))
                // One line only once it has all but arrived in the row; on
                // the way it wraps to whatever width it has.
                .lineLimit(p < 0.99 ? nil : 1)
            Text(bookmark.summary)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                // Only there in the last quarter of the way to the card,
                // when the pieces around it are nearly in place — earlier,
                // the tags would still be sliding through where it goes.
                .opacity(max(0, 1 - p * 4))
            FlowLayout(spacing: 4, lineSpacing: 4) {
                ForEach(p < 0.5 ? bookmark.tags : Array(bookmark.tags.prefix(3)), id: \.self) { tag in
                    TagChip(name: tag, size: 11)
                }
            }
            Text("\(bookmark.readingMinutes) min read")
                .font(.system(size: 11))
                .foregroundColor(.tertiary)
            UnreadMark(isRead: bookmark.isRead)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Theme.accent : Color.separator, lineWidth: isSelected ? 2 : 1)
        )
    }

    /// `a` to `b` by `p`, in half points — a font is measured once per size,
    /// so the sizes in between are kept to a few.
    private func blend(_ a: Double, _ b: Double, _ p: Double) -> Double {
        ((a + (b - a) * p) * 2).rounded() / 2
    }
}

/// A dot and "Unread" — nothing at all, taking no room, once read.
@View
struct UnreadMark {
    let isRead: Bool

    var body: some View {
        if !isRead {
            HStack(spacing: 5) {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 7, height: 7)
                Text("Unread")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.accent)
            }
        }
    }
}
