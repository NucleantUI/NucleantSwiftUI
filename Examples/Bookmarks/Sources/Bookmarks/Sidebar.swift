//
//  Sidebar.swift
//  Bookmarks
//
//  The library's views, each with its count, and under them every tag in
//  use: as a cloud of chips — a `FlowLayout` that wraps to the sidebar's
//  width — or as a list, one under another in a `VStackLayout`. The two
//  are one `AnyLayout`, so switching changes only the arrangement: each
//  chip is the same view throughout, and under the switch's animation it
//  travels from its place in the cloud to its place in the list. Choosing
//  a chip shows that tag's bookmarks; the chosen one is filled.
//

import NucleantUI

@View
struct Sidebar {
    let library: Library
    @Binding var scope: Scope
    @State private var tagsAsList = false

    var body: some View {
        let library = self.library
        let tagLayout = tagsAsList
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(FlowLayout(spacing: 6, lineSpacing: 6))
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.accent)
                    BookmarkGlyph()
                        .fill(Color.white)
                        .frame(width: 9, height: 12)
                }
                .frame(width: 24, height: 24)
                Text("Bookmarks")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            SidebarRow(title: "All Bookmarks", count: library.count(in: .all), isSelected: scope == .all) {
                scope = .all
            }
            SidebarRow(title: "Unread", count: library.count(in: .unread), isSelected: scope == .unread) {
                scope = .unread
            }
            SidebarRow(title: "Favorites", count: library.count(in: .favorites), isSelected: scope == .favorites) {
                scope = .favorites
            }

            HStack(spacing: 8) {
                Text("TAGS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                LayoutChoice(title: "Cloud", isChosen: !tagsAsList) {
                    withAnimation(.smooth(duration: 0.5)) { tagsAsList = false }
                }
                LayoutChoice(title: "List", isChosen: tagsAsList) {
                    withAnimation(.smooth(duration: 0.5)) { tagsAsList = true }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 8)

            ScrollView {
                tagLayout {
                    ForEach(library.tags) { tag in
                        TagChip(name: tag.name, count: tag.count, isSelected: scope == .tag(tag.name))
                            .onTapGesture { scope = .tag(tag.name) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One of the library's views: a title and a count, filled when chosen.
@View
struct SidebarRow {
    let title: String
    let count: Int
    let isSelected: Bool
    let choose: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(count)")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.accent.opacity(0.18) : (isHovered ? Color.fill : Color.clear))
        )
        .padding(.horizontal, 8)
        .onHover { isHovered = $0 }
        .onTapGesture { choose() }
    }
}

/// A small text switch in a section header.
@View
struct LayoutChoice {
    let title: String
    let isChosen: Bool
    let choose: () -> Void

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: isChosen ? .semibold : .regular))
            .foregroundColor(isChosen ? Theme.accent : .secondary)
            .onTapGesture { choose() }
    }
}

/// A ribbon bookmark: a rectangle with a notch cut up into its foot.
@View
struct BookmarkGlyph: Shape {
    func path(in rect: Rect) -> Path {
        var path = Path()
        path.move(to: Point(x: rect.minX, y: rect.minY))
        path.addLine(to: Point(x: rect.maxX, y: rect.minY))
        path.addLine(to: Point(x: rect.maxX, y: rect.maxY))
        path.addLine(to: Point(x: rect.midX, y: rect.maxY - rect.height * 0.3))
        path.addLine(to: Point(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
