//
//  FinderApp.swift
//  Finder
//
//  A Finder window in list view: a sidebar of places, and a folder shown
//  in columns (Name, Date Modified, Size, Kind) where every folder is a
//  `DisclosureGroup` whose content is its own children — folders inside
//  folders, as deep as the tree goes. Tap the "›" to open or close a
//  folder, tap a row to select it, pick a place in the sidebar to show it,
//  and ‹ › walk back and forward through the places visited.
//
//  The tree is `@Observable` (Model.swift), and the rows read it directly:
//  "New Folder" and "Move to Trash" edit it, and a download in Downloads
//  grows from a timer — each change lands in the rows that show it. A
//  right click on a row opens its context menu (expand, new folder,
//  duplicate, trash, and a row of tag colours); on the empty rows below,
//  one for the folder shown.
//
//  Finder keeps its columns lined up however deep a row is: only the name
//  moves right. The automatic style indents the whole content under the
//  label, columns and all, so the list uses a style of its own,
//  `OutlineRowStyle`, that only stacks the label over the content. The row
//  indents its name by depth and draws its own chevron against the
//  node's `isExpanded`, which the group is bound to with
//  `$node.isExpanded`.
//

import NucleantUI

// MARK: - Sidebar model

enum Glyph: Equatable {
    case cloud, shared, home, recents, desktop, documents, applications, downloads, airdrop, disk, network
}

/// Somewhere the list can show: a folder, or — for Recents, AirDrop and
/// Network, which this tree has nothing for — nothing.
struct Location: Equatable {
    let title: String
    let folder: FileNode?

    static func == (a: Location, b: Location) -> Bool {
        a.title == b.title && a.folder === b.folder
    }
}

struct Place: Identifiable {
    let glyph: Glyph
    let location: Location
    var id: String { location.title }

    init(_ title: String, _ glyph: Glyph, _ folder: FileNode?) {
        self.glyph = glyph
        self.location = Location(title: title, folder: folder)
    }
}

struct PlaceSection: Identifiable {
    let title: String
    let places: [Place]
    var id: String { title }
}

@MainActor
let sidebar: [PlaceSection] = {
    let disk = FileSystem.shared
    return [
        PlaceSection(title: "iCloud", places: [
            Place("iCloud Drive", .cloud, disk.iCloudDrive),
            Place("Shared", .shared, disk.shared),
        ]),
        PlaceSection(title: "Favorites", places: [
            Place("codebuilder", .home, disk.home),
            Place("Recents", .recents, nil),
            Place("Desktop", .desktop, disk.desktop),
            Place("Documents", .documents, disk.documents),
            Place("Applications", .applications, disk.applications),
            Place("Downloads", .downloads, disk.downloads),
            Place("AirDrop", .airdrop, nil),
        ]),
        PlaceSection(title: "Locations", places: [
            Place("Macintosh HD", .disk, disk.root),
            Place("Network", .network, nil),
        ]),
    ]
}()

// MARK: - Theme

/// Everything here is dynamic, so the window follows light and dark.
struct Theme {
    static let content = Color.dynamic(light: .white, dark: Color(hex: 0x1E1E1E))
    static let sidebar = Color.dynamic(light: Color(hex: 0xE8E6EA), dark: Color(hex: 0x2B2A2E))
    static let stripe = Color.dynamic(light: Color(hex: 0xF4F5F5), dark: Color(hex: 0x282828))
    static let selection = Color.dynamic(light: Color(hex: 0x0A66E4), dark: Color(hex: 0x0A5CCB))
    static let sidebarSelection = Color.dynamic(light: Color(white: 0, opacity: 0.09), dark: Color(white: 1, opacity: 0.12))
    static let accent = Color.dynamic(light: Color(hex: 0x1D7AF2), dark: Color(hex: 0x3D8FF6))
    static let folder = Color.dynamic(light: Color(hex: 0x4BA3EE), dark: Color(hex: 0x3F97E4))
    static let folderTab = Color.dynamic(light: Color(hex: 0x3A8FD9), dark: Color(hex: 0x3284CE))
    static let page = Color.dynamic(light: .white, dark: Color(hex: 0xDADADF))
    static let separator = Color.separator
}

/// Column widths, shared by the header and every row so they line up.
enum Columns {
    static let modified = 185.0
    static let size = 70.0
    static let kind = 150.0
    /// Before each of the three fixed columns — where the header's
    /// separator sits.
    static let gap = 12.0
    /// How far each level of the tree moves the name right.
    static let indent = 16.0
    static let rowHeight = 20.0
    /// The chevron's slot plus the space after it, before the icon.
    static let chevron = 14.0
    /// Enough stripes to fill the window below a short listing.
    static let minimumRows = 30
}

// MARK: - Disclosure style

/// The outline's style: the label, then — while open — the content right
/// under it, full width and flush left. No chevron and no indent of its
/// own; the rows draw both, since only they know how deep they are.
struct OutlineRowStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            configuration.label
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

// MARK: - Icons

/// A folder: a tab on the back and a body in front.
@View
struct FolderIcon {
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.folderTab)
                .frame(width: 7, height: 4)
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.folder)
                .frame(width: 16, height: 11)
                .offset(y: 2)
        }
        .frame(width: 16, height: 14, alignment: .topLeading)
    }
}

/// A page with a turned-down corner and a band in the kind's color; an
/// application is a rounded tile instead.
@View
struct DocumentIcon {
    let kind: FileKind

    var body: some View {
        if kind == .application {
            RoundedRectangle(cornerRadius: 3.5)
                .fill(kind.color)
                .frame(width: 15, height: 15)
                .frame(width: 16)
        } else {
            ZStack(alignment: .bottom) {
                PathShape(Self.page).fill(Theme.page)
                PathShape(Self.page).stroke(Theme.separator, lineWidth: 1)
                Rectangle()
                    .fill(kind.color)
                    .frame(width: 12, height: 4)
            }
            .frame(width: 12, height: 15)
            .frame(width: 16)
        }
    }

    /// The page outline, its top-right corner cut off.
    static func page(_ size: Size) -> Path {
        let fold = size.width * 0.35
        var path = Path()
        path.move(to: Point(x: 0, y: 0))
        path.addLine(to: Point(x: size.width - fold, y: 0))
        path.addLine(to: Point(x: size.width, y: fold))
        path.addLine(to: Point(x: size.width, y: size.height))
        path.addLine(to: Point(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }
}

/// An open "›": points right while closed, turned down while open. Also
/// the toolbar's back and forward arrows, mirrored for back.
@View
struct Chevron {
    let isOpen: Bool
    let color: Color
    var size: Double = 8
    var lineWidth: Double = 1.5

    var body: some View {
        PathShape { size in
            var path = Path()
            path.move(to: Point(x: size.width * 0.3, y: size.height * 0.1))
            path.addLine(to: Point(x: size.width * 0.72, y: size.height * 0.5))
            path.addLine(to: Point(x: size.width * 0.3, y: size.height * 0.9))
            return path
        }
        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        .frame(width: size, height: size)
        .rotationEffect(.degrees(isOpen ? 90 : 0))
    }
}

// MARK: - Rows

/// One row of the outline — a file, or a folder with its children in a
/// `DisclosureGroup` under it. The children are `FileRow`s again, one
/// level deeper, so the tree nests as far as the data does.
///
/// `node` is `@Bindable` for `$node.isExpanded`; everything else is read
/// straight off it, so a rename, a new child or a growing size rebuilds
/// this row and not its neighbours.
@View
struct FileRow {
    @Bindable var node: FileNode
    let depth: Int
    /// This row's position among all visible rows, for the stripes.
    let index: Int
    @Binding var selection: FileNode.ID?

    var body: some View {
        if node.isFolder {
            DisclosureGroup(isExpanded: $node.isExpanded) {
                // Only called while open — a closed folder builds no rows.
                ForEach(placedChildren) { child in
                    FileRow(node: child.node, depth: depth + 1, index: child.index, selection: $selection)
                }
            } label: {
                row
            }
        } else {
            row
        }
    }

    var row: some View {
        let isSelected = selection == node.id
        let text = isSelected ? Color.white : Color.primary
        let secondary = isSelected ? Color.white : Color.secondary
        return HStack(spacing: 0) {
            // The name cell takes whatever the fixed columns leave, so
            // indenting it never moves them.
            HStack(spacing: 4) {
                if node.isFolder {
                    Chevron(isOpen: node.isExpanded, color: secondary)
                        .frame(width: Columns.chevron, height: Columns.rowHeight)
                        .onTapGesture { node.isExpanded.toggle() }
                    FolderIcon()
                } else {
                    Color.clear.frame(width: Columns.chevron, height: 1)
                    DocumentIcon(kind: node.kind)
                }
                Text(node.name)
                    .font(.system(size: 13))
                    .foregroundColor(text)
                    .lineLimit(1)
                if let tag = node.tag {
                    Circle()
                        .fill(tag.color)
                        .frame(width: 8, height: 8)
                        .padding(.leading, 2)
                }
            }
            .padding(.leading, 4 + Double(depth) * Columns.indent)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(node.modified)
                .font(.system(size: 12))
                .foregroundColor(secondary)
                .lineLimit(1)
                .padding(.leading, Columns.gap)
                .frame(width: Columns.gap + Columns.modified, alignment: .leading)
            Text(formattedSize(node.size))
                .font(.system(size: 12))
                .foregroundColor(secondary)
                .lineLimit(1)
                .padding(.trailing, Columns.gap)
                .frame(width: Columns.gap + Columns.size, alignment: .trailing)
            Text(kindText)
                .font(.system(size: 12))
                .foregroundColor(secondary)
                .lineLimit(1)
                .padding(.leading, Columns.gap)
                .frame(width: Columns.gap + Columns.kind, alignment: .leading)
        }
        .frame(height: Columns.rowHeight)
        .background(isSelected ? Theme.selection : StripedRow.color(index))
        .cornerRadius(5)
        .onTapGesture { selection = node.id }
        .contextMenu { menu }
    }

    /// What a right click on the row offers. The actions write to the
    /// model, and the rows showing what they touched rebuild from it.
    @ViewBuilder
    var menu: some View {
        let disk = FileSystem.shared
        if node.isFolder {
            Button(node.isExpanded ? "Collapse" : "Expand") { node.isExpanded.toggle() }
            Button("Expand All Inside") { node.setExpanded(true) }
            Divider()
            Button("New Folder Inside") { selection = disk.newFolder(in: node).id }
        }
        Button("Duplicate") {
            if let copy = disk.duplicate(node) { selection = copy.id }
        }
        .disabled(node.isLocked || node.progress != nil)
        Button("Move to Trash") {
            if selection == node.id { selection = nil }
            disk.moveToTrash(node)
        }
        .disabled(node.isLocked)
        Divider()
        TagPicker(node: node)
    }

    var kindText: String {
        guard let progress = node.progress else { return node.kind.name }
        return "Downloading… \(Int(progress * 100))%"
    }

    /// The children, each with the row index it lands on: right after this
    /// row, then after every row the previous sibling shows.
    var placedChildren: [PlacedNode] {
        place(node.children ?? [], from: index + 1)
    }
}

/// Finder's row of tag colours at the bottom of a context menu. Tapping
/// a colour tags the node with it — or, on the colour it already has,
/// untags it — and closes the menu.
@View
struct TagPicker {
    @Bindable var node: FileNode
    @Environment(\.contextMenu) private var menu

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Tag.allCases) { tag in
                TagSwatch(tag: tag, isOn: node.tag == tag)
                    .onTapGesture {
                        node.tag = node.tag == tag ? nil : tag
                        menu?.dismiss()
                    }
            }
        }
        .padding(horizontal: 10, vertical: 6)
    }
}

/// One colour: a dot, ringed while it is the node's tag.
@View
struct TagSwatch {
    let tag: Tag
    let isOn: Bool

    var body: some View {
        ZStack {
            if isOn {
                Circle().stroke(Color.primary, lineWidth: 1.5)
            }
            Circle()
                .fill(tag.color)
                .frame(width: 14, height: 14)
        }
        .frame(width: 20, height: 20)
    }
}

struct PlacedNode: Identifiable {
    let node: FileNode
    let index: Int
    var id: FileNode.ID { node.id }
}

@MainActor
func place(_ nodes: [FileNode], from start: Int) -> [PlacedNode] {
    var next = start
    return nodes.map { node in
        defer { next += visibleRowCount(node) }
        return PlacedNode(node: node, index: next)
    }
}

/// An empty row under the listing, so the stripes run to the bottom the
/// way Finder's do.
@View
struct StripedRow {
    let index: Int

    var body: some View {
        StripedRow.color(index)
            .frame(height: Columns.rowHeight)
            .frame(maxWidth: .infinity)
            .cornerRadius(5)
    }

    static func color(_ index: Int) -> Color {
        index % 2 == 1 ? Theme.stripe : .clear
    }
}

// MARK: - Sidebar

/// The small line drawings beside each place, in the accent color.
@View
struct PlaceGlyph {
    let glyph: Glyph

    var body: some View {
        ZStack {
            switch glyph {
            case .cloud:
                PathShape { s in
                    var path = Path()
                    path.addEllipse(in: Rect(x: 0, y: s.height * 0.35, width: s.width * 0.5, height: s.height * 0.5))
                    path.addEllipse(in: Rect(x: s.width * 0.22, y: s.height * 0.12, width: s.width * 0.55, height: s.height * 0.6))
                    path.addEllipse(in: Rect(x: s.width * 0.5, y: s.height * 0.35, width: s.width * 0.5, height: s.height * 0.5))
                    return path
                }
                .stroke(Theme.accent, lineWidth: 1.3)
            case .shared, .documents, .applications, .desktop, .downloads:
                RoundedRectangle(cornerRadius: 2.5)
                    .stroke(Theme.accent, lineWidth: 1.3)
                    .frame(width: 13, height: glyph == .desktop ? 10 : 14)
            case .home:
                PathShape { s in
                    var path = Path()
                    path.move(to: Point(x: s.width * 0.1, y: s.height * 0.5))
                    path.addLine(to: Point(x: s.width * 0.5, y: s.height * 0.12))
                    path.addLine(to: Point(x: s.width * 0.9, y: s.height * 0.5))
                    path.move(to: Point(x: s.width * 0.22, y: s.height * 0.42))
                    path.addLine(to: Point(x: s.width * 0.22, y: s.height * 0.9))
                    path.addLine(to: Point(x: s.width * 0.78, y: s.height * 0.9))
                    path.addLine(to: Point(x: s.width * 0.78, y: s.height * 0.42))
                    return path
                }
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            case .recents, .airdrop, .network:
                Circle().stroke(Theme.accent, lineWidth: 1.3).frame(width: 13, height: 13)
            case .disk:
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Theme.accent, lineWidth: 1.3)
                    .frame(width: 15, height: 9)
            }
        }
        .frame(width: 16, height: 16)
    }
}

@View
struct SidebarRow {
    let place: Place
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 7) {
            PlaceGlyph(glyph: place.glyph)
            Text(place.location.title)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(horizontal: 8)
        .frame(height: 24)
        .background(isSelected ? Theme.sidebarSelection : Color.clear)
        .cornerRadius(6)
    }
}

@View
struct SidebarHeading {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.tertiary)
            .padding(.leading, 8)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@View
struct Sidebar {
    let current: Location
    let onSelect: (Location) -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sidebar) { section in
                    SidebarHeading(title: section.title)
                    ForEach(section.places) { place in
                        SidebarRow(place: place, isSelected: place.location == current)
                            .onTapGesture { onSelect(place.location) }
                    }
                }
                SidebarHeading(title: "Tags")
                ForEach(Tag.allCases) { tag in
                    HStack(spacing: 9) {
                        Circle().fill(tag.color).frame(width: 10, height: 10)
                            .frame(width: 14)
                        Text(tag.name)
                            .font(.system(size: 13))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(horizontal: 8)
                    .frame(height: 24)
                }
            }
            .padding(horizontal: 10, vertical: 6)
        }
        .frame(width: 190)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }
}

// MARK: - Window

@View
struct ColumnHeader {
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Name")
                    .frame(maxWidth: .infinity, alignment: .leading)
                // The sort indicator: by name, ascending.
                Chevron(isOpen: false, color: .secondary, size: 8, lineWidth: 1.3)
                    .rotationEffect(.degrees(-90))
                    .padding(.trailing, 8)
            }
            .padding(.leading, 4 + Columns.chevron + 4)
            .frame(maxWidth: .infinity)
            Divider().frame(height: 14)
            Text("Date Modified")
                .padding(.leading, Columns.gap - 1)
                .frame(width: Columns.gap - 1 + Columns.modified, alignment: .leading)
            Divider().frame(height: 14)
            Text("Size")
                .padding(.trailing, Columns.gap)
                .frame(width: Columns.gap - 1 + Columns.size, alignment: .trailing)
            Divider().frame(height: 14)
            Text("Kind")
                .padding(.leading, Columns.gap - 1)
                .frame(width: Columns.gap - 1 + Columns.kind, alignment: .leading)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.secondary)
        .frame(height: 26)
        .padding(horizontal: 10)
    }
}

/// A small pill, the size of Finder's toolbar controls.
@View
struct ToolbarButton {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(isEnabled ? .primary : .tertiary)
            .padding(horizontal: 10, vertical: 4)
            .background(Theme.sidebarSelection)
            .cornerRadius(6)
            .onTapGesture { if isEnabled { action() } }
    }
}

@View
struct FinderWindow {
    @State private var history = [Location(title: "Macintosh HD", folder: FileSystem.shared.root)]
    @State private var position = 0
    @State private var selection: FileNode.ID? = nil

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(current: location) { go(to: $0) }
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                ColumnHeader()
                Divider()
                list
                Divider()
                statusBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.content)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.content)
        .onAppear { FileSystem.shared.startDownload() }
    }

    var toolbar: some View {
        let canGoBack = position > 0
        let canGoForward = position < history.count - 1
        return HStack(spacing: 8) {
            Chevron(isOpen: false, color: canGoBack ? .primary : .tertiary, size: 14, lineWidth: 1.8)
                .scaleEffect(x: -1, y: 1)
                .frame(width: 20, height: 24)
                .onTapGesture { if canGoBack { position -= 1; selection = nil } }
            Chevron(isOpen: false, color: canGoForward ? .primary : .tertiary, size: 14, lineWidth: 1.8)
                .frame(width: 20, height: 24)
                .onTapGesture { if canGoForward { position += 1; selection = nil } }
            Text(location.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .padding(.leading, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            ToolbarButton(title: "New Folder", isEnabled: location.folder != nil) { newFolder() }
            ToolbarButton(title: "Move to Trash", isEnabled: selected.map { !$0.isLocked } ?? false) { trash() }
            ToolbarButton(title: "Expand All") { location.folder?.children?.forEach { $0.setExpanded(true) } }
            ToolbarButton(title: "Collapse All") { location.folder?.children?.forEach { $0.setExpanded(false) } }
        }
        .padding(horizontal: 14)
        .frame(height: 52)
    }

    var list: some View {
        let rows = place(location.folder?.children ?? [], from: 0)
        let shown = rows.last.map { $0.index + visibleRowCount($0.node) } ?? 0
        return ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(rows) { placed in
                    FileRow(node: placed.node, depth: 0, index: placed.index, selection: $selection)
                }
                ForEach(shown..<max(shown, Columns.minimumRows)) { index in
                    StripedRow(index: index)
                        .onTapGesture { selection = nil }
                        .contextMenu {
                            Button("New Folder") { newFolder(in: location.folder) }
                                .disabled(location.folder == nil)
                            Button("Expand All") { location.folder?.children?.forEach { $0.setExpanded(true) } }
                            Button("Collapse All") { location.folder?.children?.forEach { $0.setExpanded(false) } }
                        }
                }
            }
            .padding(horizontal: 10, vertical: 2)
            .frame(maxWidth: .infinity)
            // Every folder in the tree inherits this.
            .disclosureGroupStyle(OutlineRowStyle())
        }
        .frame(maxHeight: .infinity)
    }

    var statusBar: some View {
        Text(statusText)
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
    }

    var statusText: String {
        let count = location.folder?.children?.count ?? 0
        let items = count == 1 ? "1 item" : "\(count) items"
        return "\(items), \(formattedSize(FileSystem.shared.available)) available"
    }

    var location: Location { history[position] }

    var selected: FileNode? {
        selection.flatMap { location.folder?.find($0) }
    }

    /// Shows a place, dropping anything ahead of it in the history the
    /// way a browser does.
    func go(to location: Location) {
        guard location != self.location else { return }
        history = Array(history[...position]) + [location]
        position += 1
        selection = nil
    }

    /// Into the selected folder, next to the selected file, or else at the
    /// top of the list — and selected, the way Finder leaves it.
    func newFolder() {
        guard let top = location.folder else { return }
        newFolder(in: selected.flatMap { $0.isFolder ? $0 : $0.parent } ?? top)
    }

    func newFolder(in parent: FileNode?) {
        guard let parent else { return }
        selection = FileSystem.shared.newFolder(in: parent).id
    }

    func trash() {
        guard let node = selected else { return }
        FileSystem.shared.moveToTrash(node)
        selection = nil
    }
}

/// Applies the chosen appearance under itself.
@View
struct RootView {
    @Environment(\.colorScheme) private var system

    var body: some View {
        FinderWindow()
            .colorScheme(AppearanceModel.shared.appearance.scheme ?? system)
    }
}

@main
struct FinderApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Finder", width: 940, height: 540) {
            RootView()
        }
        .commands { AppearanceCommands() }
    }
}
