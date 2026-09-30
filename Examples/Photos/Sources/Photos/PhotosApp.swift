//
//  PhotosApp.swift
//  Photos
//
//  A photo library of twenty thousand photos, in the panes of a desktop
//  photos app — each built on a lazy container or a grid:
//
//  * Library and Favorites: a `LazyVGrid` of square tiles with adaptive
//    columns (the zoom slider sets their minimum width), one `Section` per
//    month with its header pinned while the month scrolls under it;
//  * Days: the library as a sideways timeline — a `LazyHGrid` of three
//    rows in a horizontal scroll view, each day's header a pinned column;
//  * Albums: pinned albums as a `LazyHStack` strip of covers, and every
//    album as a `LazyVStack` of rows under pinned group headers; opening
//    one shows it in the library grid;
//  * the info pane for the selected photo, laid out by a `Grid`.
//
//  Clicking a tile selects it and opens the info pane; its Favorite toggle
//  puts a heart on the tile.
//

import NucleantUI

enum Theme {
    static let sidebar = Color.dynamic(light: Color(hex: 0xEEEEF2), dark: Color(hex: 0x16181D))
    static let bar = Color.dynamic(light: Color(hex: 0xF7F7F9), dark: Color(hex: 0x1B1D23))
    static let accent = Color(hex: 0x2F7CF6)
}

/// Where the main pane is.
enum Scope: Hashable {
    case library
    case favorites
    case days
    case albums
    case album(Album.ID)
}

@View
struct PhotosView {
    @State private var library = Library()
    @State private var scope: Scope? = .library
    @Environment(\.colorScheme) private var system

    var body: some View {
        let library = self.library
        HStack(spacing: 0) {
            Sidebar(library: library, scope: $scope)
                .frame(width: 220)
                .frame(maxHeight: .infinity)
                .background(Theme.sidebar)
            Divider()
            screen
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let photo = library.selectedPhoto {
                Divider()
                Inspector(library: library, photo: photo)
                    .frame(width: 330)
                    .frame(maxHeight: .infinity)
                    .background(Theme.bar)
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondaryBackground)
        .tint(Theme.accent)
        .colorScheme(AppearanceModel.shared.appearance.scheme ?? system)
    }

    @ViewBuilder
    private var screen: some View {
        let library = self.library
        switch scope ?? .library {
        case .library:
            PhotoGridScreen(library: library, title: "Library", months: library.months)
        case .favorites:
            PhotoGridScreen(library: library, title: "Favorites", months: library.favoriteMonths)
        case .days:
            DaysScreen(library: library)
        case .albums:
            AlbumsScreen(library: library, open: { [$scope] id in $scope.wrappedValue = .album(id) })
        case .album(let id):
            if let album = library.album(id) {
                PhotoGridScreen(library: library, title: album.name, months: library.months(in: album))
            }
        }
    }
}

@main
struct PhotosApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Photos", width: 1320, height: 840) {
            PhotosView()
        }
        .commands { AppearanceCommands() }
    }
}

// MARK: - Sidebar

/// The places in the library, and the pinned albums, as a sidebar list.
@View
struct Sidebar {
    let library: Library
    @Binding var scope: Scope?

    var body: some View {
        let library = self.library
        List(selection: $scope) {
            Section("Photos") {
                SidebarRow(title: "Library", color: Theme.accent)
                    .tag(Scope.library)
                    .badge(library.photos.count)
                SidebarRow(title: "Favorites", color: Color(hex: 0xFF4F6D))
                    .tag(Scope.favorites)
                    .badge(library.favorites.count)
                SidebarRow(title: "Days", color: Color(hex: 0xF5A623))
                    .tag(Scope.days)
            }
            Section("Albums") {
                SidebarRow(title: "All Albums", color: Color(hex: 0x8E8E93))
                    .tag(Scope.albums)
                ForEach(library.albums.filter(\.isPinned)) { album in
                    SidebarRow(title: album.name, color: album.isShared ? Color(hex: 0x34C759) : Color(hex: 0x5E6AD2))
                        .tag(Scope.album(album.id))
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// A coloured square and a title.
@View
struct SidebarRow {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 12, height: 12)
            Text(title)
                .lineLimit(1)
        }
    }
}

/// `12345` as "12,345".
func grouped(_ value: Int) -> String {
    let digits = String(value)
    var result = ""
    for (index, digit) in digits.enumerated() {
        if index > 0, (digits.count - index) % 3 == 0 { result.append(",") }
        result.append(digit)
    }
    return result
}
