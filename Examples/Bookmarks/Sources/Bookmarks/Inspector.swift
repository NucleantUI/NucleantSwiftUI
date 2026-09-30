//
//  Inspector.swift
//  Bookmarks
//
//  The selected bookmark: its title, flags and notes as controls bound
//  into the library; its tags as chips with a remove button, wrapping in a
//  `FlowLayout`, a field to add one and the library's other tags as
//  suggestions; and its actions as an `EqualWidthHStack`, the two buttons
//  the same width whatever their labels say.
//

import Foundation
import NucleantUI

@View
struct Inspector {
    let library: Library
    @Binding var selection: Bookmark.ID?

    var body: some View {
        if let id = selection, let bookmark = library.bookmark(id) {
            BookmarkEditor(library: library, bookmark: bookmark, selection: $selection)
        } else {
            VStack(spacing: 6) {
                Text("No Bookmark Selected")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Choose a card to see and edit it.")
                    .font(.system(size: 12))
                    .foregroundColor(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@View
struct BookmarkEditor {
    let library: Library
    let bookmark: Bookmark
    @Binding var selection: Bookmark.ID?
    @State private var newTag = ""

    var body: some View {
        let library = self.library
        let id = bookmark.id
        let suggestions = library.tags.map(\.name).filter { !bookmark.tags.contains($0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    SiteBadge(bookmark: bookmark, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bookmark.host)
                            .font(.system(size: 13, weight: .semibold))
                        Text(bookmark.url)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                TextField("Title", text: library.binding(id, \.title, default: ""), axis: .vertical)
                    .font(.system(size: 17, weight: .semibold))
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)

                Text(bookmark.summary)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Favorite", isOn: library.binding(id, \.isFavorite, default: false))
                    Toggle("Wide card", isOn: Binding(
                        get: { bookmark.isFeatured },
                        set: { _ in withAnimation(.smooth) { library.toggleFeatured(id) } }
                    ))
                }
                .toggleStyle(.switch)

                InspectorSection(title: "Tags") {
                    if bookmark.tags.isEmpty {
                        Text("No tags yet.")
                            .font(.system(size: 12))
                            .foregroundColor(.tertiary)
                    } else {
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            ForEach(bookmark.tags, id: \.self) { tag in
                                RemovableTag(name: tag) { library.removeTag(tag, from: id) }
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        TextField("Add a tag", text: $newTag)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addTag() }
                        Button("Add") { addTag() }
                            .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !suggestions.isEmpty {
                        Text("Suggestions")
                            .font(.system(size: 11))
                            .foregroundColor(.tertiary)
                        FlowLayout(spacing: 5, lineSpacing: 5) {
                            ForEach(suggestions, id: \.self) { tag in
                                TagChip(name: tag, size: 11)
                                    .opacity(0.7)
                                    .onTapGesture { library.addTag(tag, to: id) }
                            }
                        }
                    }
                }

                InspectorSection(title: "Notes") {
                    TextEditor(text: library.binding(id, \.notes, default: ""))
                        .frame(height: 96)
                }

                EqualWidthHStack {
                    ActionButton(title: bookmark.isRead ? "Mark Unread" : "Mark Read") { library.toggleRead(id) }
                    ActionButton(title: "Delete") {
                        selection = nil
                        library.delete(id)
                    }
                }
                .frame(maxWidth: .infinity)

                Text("Saved \(bookmark.added.formatted(date: .abbreviated, time: .shortened)) · \(bookmark.readingMinutes) min read")
                    .font(.system(size: 11))
                    .foregroundColor(.tertiary)
            }
            .padding(18)
        }
    }

    private func addTag() {
        library.addTag(newTag, to: bookmark.id)
        newTag = ""
    }
}

/// A button whose label fills the width it is given, on one line — so in
/// an `EqualWidthHStack` every button is visibly the same width.
@View
struct ActionButton {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
    }
}

/// A heading over a group of controls.
@View
struct InspectorSection<Content: View> {
    let title: String
    let content: Content

    init(title: String, _viewID: ViewID = #viewID, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        self._viewID = _viewID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            content
        }
    }
}

/// A tag chip with a × that removes it.
@View
struct RemovableTag {
    let name: String
    let remove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Text("#\(name)")
                .font(.system(size: 12, weight: .medium))
            Text("×")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(isHovered ? Theme.accent : .secondary)
                .onHover { isHovered = $0 }
                .onTapGesture { remove() }
        }
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Theme.accent.opacity(0.14))
        )
    }
}
