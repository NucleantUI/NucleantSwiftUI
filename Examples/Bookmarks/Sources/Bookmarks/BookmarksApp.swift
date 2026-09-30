//
//  BookmarksApp.swift
//  Bookmarks
//
//  A reading list: pages saved to read later, tagged, starred and noted.
//
//  * The sidebar: the library's views with counts, and every tag in use —
//    as a cloud of chips wrapping in a `FlowLayout`, or as a list in a
//    `VStackLayout`. The two are one `AnyLayout`, so switching keeps every
//    chip and moves each from its place in one to its place in the other.
//  * The shelf: the bookmarks in a `ShelfLayout`, as a masonry of cards (a
//    featured card spans two columns through a `ColumnSpan` layout value)
//    or as a list. Switching morphs every card into its row — the card's
//    own layout, `BookmarkTileLayout`, moving its pieces along the way —
//    through the layouts' `animatableData`; the zoom buttons animate the
//    column width the same way.
//  * The inspector: the selected bookmark's fields, its tags as removable
//    chips in a `FlowLayout` with suggestions under them, and a row of
//    actions in an `EqualWidthHStack`.
//
//  Two things travel *up* the tree as preferences. Whatever the shelf is
//  showing names itself with a `ScreenTitle`, which the window bar above it
//  displays; and every card on the shelf contributes its bookmark to a
//  `ShelfTotals` sum — count, unread, minutes to read — that the status
//  bar under the cards shows.
//

import Foundation
import NucleantUI

enum Theme {
    static let sidebar = Color.dynamic(light: Color(hex: 0xEFEDE8), dark: Color(hex: 0x17181C))
    static let bar = Color.dynamic(light: Color(hex: 0xF8F7F4), dark: Color(hex: 0x1C1D22))
    static let shelf = Color.dynamic(light: Color(hex: 0xF3F1EC), dark: Color(hex: 0x111215))
    static let card = Color.dynamic(light: Color.white, dark: Color(hex: 0x22242A))
    static let accent = Color(hex: 0xE0663D)
}

// MARK: - Preferences

/// What the pane under the window bar is showing.
struct ScreenTitle: Equatable {
    var title: String
    var subtitle: String
}

/// The title of whatever the main pane shows — the outermost screen that
/// names itself wins.
struct ScreenTitleKey: PreferenceKey {
    static let defaultValue: ScreenTitle? = nil

    static func reduce(value: inout ScreenTitle?, nextValue: () -> ScreenTitle?) {
        if value == nil { value = nextValue() }
    }
}

// MARK: - The window

@View
struct BookmarksView {
    @State private var library = Library()
    @State private var scope: Scope = .all
    @State private var selection: Bookmark.ID? = nil
    @State private var query = ""
    /// Set from below: whatever the shelf says it is showing.
    @State private var screenTitle: ScreenTitle? = nil
    @Environment(\.colorScheme) private var system

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(library: library, scope: $scope)
                .frame(width: 224)
                .frame(maxHeight: .infinity)
                .background(Theme.sidebar)
            Divider()
            VStack(spacing: 0) {
                WindowBar(
                    title: screenTitle ?? ScreenTitle(title: "Bookmarks", subtitle: ""),
                    query: $query,
                    add: { address in
                        guard let id = library.add(address) else { return false }
                        scope = .all
                        query = ""
                        selection = id
                        return true
                    }
                )
                Divider()
                HStack(spacing: 0) {
                    Shelf(library: library, scope: scope, query: query, selection: $selection)
                    Divider()
                    Inspector(library: library, selection: $selection)
                        .frame(width: 340)
                        .frame(maxHeight: .infinity)
                        .background(Theme.bar)
                }
            }
            .onPreferenceChange(ScreenTitleKey.self) { screenTitle = $0 }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.shelf)
        .tint(Theme.accent)
        .colorScheme(AppearanceModel.shared.appearance.scheme ?? system)
    }
}

/// The bar across the top: the shelf's title, search, and a field to save
/// a new page.
@View
struct WindowBar {
    let title: ScreenTitle
    @Binding var query: String
    /// Saves an address; false when it isn't one.
    let add: (String) -> Bool
    @State private var address = ""
    @State private var rejected = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.title)
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(1)
                Text(title.subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            TextField("Paste an address to save", text: $address)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
                .onSubmit { save() }
            Button("Save") { save() }
            if rejected {
                Text("Not an address")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Theme.bar)
    }

    private func save() {
        if add(address) {
            address = ""
            rejected = false
        } else {
            rejected = true
        }
    }
}

@main
struct BookmarksApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Bookmarks", width: 1320, height: 840) {
            BookmarksView()
        }
        .commands { AppearanceCommands() }
    }
}

// MARK: - Small shared pieces

/// A site's first letter on its colour.
@View
struct SiteBadge {
    let bookmark: Bookmark
    var size: Double = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26)
                .fill(bookmark.siteColor)
            Text(bookmark.initial)
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

/// A tag as a rounded chip: `#name`, and a count when given one.
@View
struct TagChip {
    let name: String
    var count: Int? = nil
    var isSelected: Bool = false
    var size: Double = 12

    var body: some View {
        HStack(spacing: 4) {
            Text("#\(name)")
                .font(.system(size: size, weight: .medium))
                .foregroundColor(isSelected ? .white : .primary)
            if let count {
                Text("\(count)")
                    .font(.system(size: size - 1))
                    .foregroundColor(isSelected ? Color.white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, size * 0.7)
        .padding(.vertical, size * 0.3)
        .background(
            Capsule()
                .fill(isSelected ? Theme.accent : Color.fill)
        )
    }
}

/// A five-pointed star, for favourites — the bundled face has no "★".
@View
struct Star: Shape {
    func path(in rect: Rect) -> Path {
        var path = Path()
        let center = Point(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.45
        for point in 0..<10 {
            let radius = point.isMultiple(of: 2) ? outer : inner
            let angle = Double(point) * .pi / 5 - .pi / 2
            let vertex = Point(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if point == 0 { path.move(to: vertex) } else { path.addLine(to: vertex) }
        }
        path.closeSubpath()
        return path
    }
}
