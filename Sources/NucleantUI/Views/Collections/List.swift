//
//  List.swift
//  NucleantUI
//

/// Rows in a column that scrolls, optionally selectable.
///
/// ```swift
/// List(mailboxes, selection: $selected) { mailbox in
///     Text(mailbox.name)
/// }
///
/// List(selection: $selection) {
///     Section("Library") {
///         Text("Songs").tag(Page.songs)
///         Text("Albums").tag(Page.albums)
///     }
///     Section("Playlists") {
///         OutlineGroup(folders, children: \.children) { Text($0.name) }
///     }
/// }
/// .listStyle(.sidebar)
/// ```
///
/// Every view in `content` is a row — `ForEach` makes one per element,
/// `Section` groups rows under a header, `OutlineGroup` and
/// `DisclosureGroup` add rows that open to show more rows one level in (see
/// `ListContent.swift` for how they are found).
///
/// A row is selectable when it has a value of the selection's type: its
/// `.tag(_:)`, or the id of the `ForEach` or `OutlineGroup` element it was
/// built for. A click selects a row; with a set for a selection, ⌘-click
/// adds or removes one and ⇧-click selects a run. While the list has the
/// keys, ↑ and ↓ move the selection (⇧ to extend it), ← and → close and
/// open outline rows, ⌘A selects every row, Return runs the
/// `primaryAction` of `.contextMenu(forSelectionType:menu:primaryAction:)`
/// — as does a double click — and Delete runs `.onDeleteCommand`.
///
/// How it looks is the `.listStyle(_:)` around it: `.inset` (the desktop
/// default), `.plain`, `.sidebar`, `.bordered`, `.insetGrouped` (the phone
/// default) or `.grouped`.
@View
public struct List<SelectionValue: Hashable, Content: View>: View {
    let selection: CollectionSelection<SelectionValue>
    let content: Content

    @Environment(\.listStyleKind) private var style
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.alternatingRowBackgrounds) private var alternates
    @Environment(\.selectionContextMenu) private var selectionMenu
    @Environment(\.deleteCommand) private var deleteCommand

    /// The outline rows and disclosure groups opened without a binding of
    /// their own, by row id.
    @State private var expanded: Set<Int> = []
    /// The sidebar sections closed without a binding of their own, by
    /// header id.
    @State private var collapsed: Set<Int> = []
    @State private var cursor = SelectionCursor<SelectionValue>()
    @State private var isFocused = false

    init(selection: CollectionSelection<SelectionValue>, content: Content, _viewID: ViewID) {
        self.selection = selection
        self.content = content
        self._viewID = _viewID
    }

    /// Any number of rows selectable — ⌘- and ⇧-click, ⇧-arrows, ⌘A.
    public init(
        selection: Binding<Set<SelectionValue>>?,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: () -> Content
    ) {
        self.init(selection: CollectionSelection(selection), content: content(), _viewID: _viewID)
    }

    /// At most one row selectable; ⌘-click on it deselects it.
    public init(
        selection: Binding<SelectionValue?>?,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: () -> Content
    ) {
        self.init(selection: CollectionSelection(selection), content: content(), _viewID: _viewID)
    }

    /// Always exactly one row selected.
    @_disfavoredOverload
    public init(
        selection: Binding<SelectionValue>,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: () -> Content
    ) {
        self.init(selection: CollectionSelection(selection), content: content(), _viewID: _viewID)
    }

    public var body: some View {
        let items = makeItems()
        let order = items.compactMap { item in
            item.kind == .row && !item.traits.selectionDisabled ? item.tag : nil
        }
        let look = ListLook(kind: style, alternates: alternates)
        let actions = ListActions(
            selection: selection,
            order: order,
            cursor: cursor,
            menu: selectionMenu,
            isEnabled: isEnabled
        )
        let isFocused = self.isFocused
        let focus = $isFocused
        _CollectionFocus(
            keys: CollectionKeys(
                isEnabled: isEnabled && selection.isSelectable,
                editCommands: selection.allowsMultiple ? [.selectAll] : [],
                onFocusChange: { focused in focus.wrappedValue = focused },
                onKeyDown: { event in handleKey(event, items: items, actions: actions) },
                onEditCommand: { command in
                    if command == .selectAll { actions.selection.selectAll(order) }
                }
            )
        ) {
            if look.isGrouped {
                _GroupedListBody(items: items, look: look, actions: actions, isFocused: isFocused)
            } else {
                _ListBody(items: items, look: look, actions: actions, isFocused: isFocused)
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func makeItems() -> [ListItem<SelectionValue>] {
        var walk = ListWalk<SelectionValue>(
            expanded: $expanded,
            collapsed: $collapsed,
            sectionsCollapse: style == .sidebar
        )
        listItems(of: content, into: &walk)
        return walk.items
    }

    /// The keys a list takes while it has them.
    private func handleKey(_ event: KeyEvent, items: [ListItem<SelectionValue>], actions: ListActions<SelectionValue>) {
        let selection = actions.selection
        let shift = event.modifiers.contains(.shift)
        let jump = event.modifiers.contains(.option) || event.modifiers.contains(.command)
        switch event.keyCode {
        case CollectionKey.upArrow:
            selection.move(by: -1, toEnd: jump, extending: shift, order: actions.order, cursor: cursor)
        case CollectionKey.downArrow:
            selection.move(by: 1, toEnd: jump, extending: shift, order: actions.order, cursor: cursor)
        case CollectionKey.home:
            selection.move(by: -1, toEnd: true, extending: shift, order: actions.order, cursor: cursor)
        case CollectionKey.end:
            selection.move(by: 1, toEnd: true, extending: shift, order: actions.order, cursor: cursor)
        case CollectionKey.rightArrow, CollectionKey.leftArrow:
            // Open or close the row at the cursor; ← on a row that is
            // closed, or has nothing to close, goes up to its parent.
            guard let current = cursor.cursor ?? selection.values.first,
                  let index = items.firstIndex(where: { $0.kind == .row && $0.tag == current }) else { return }
            let item = items[index]
            if event.keyCode == CollectionKey.rightArrow {
                if let disclosure = item.disclosure, !disclosure.isExpanded { disclosure.binding.wrappedValue = true }
            } else if let disclosure = item.disclosure, disclosure.isExpanded {
                disclosure.binding.wrappedValue = false
            } else if item.depth > 0,
                      let parent = items[..<index].last(where: { $0.kind == .row && $0.depth == item.depth - 1 }),
                      let tag = parent.tag {
                selection.press(tag, modifiers: [], order: actions.order, cursor: cursor)
            }
        case CollectionKey.returnKey, CollectionKey.enter:
            actions.runPrimaryAction()
        case CollectionKey.delete, CollectionKey.forwardDelete:
            deleteCommand?.perform()
        default:
            break
        }
    }
}

// MARK: - Initializers over data

extension List {
    public init<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data,
        selection: Binding<Set<SelectionValue>>?,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == ForEach<Data, Data.Element.ID, RowContent>, Data.Element: Identifiable {
        self.init(selection: CollectionSelection(selection), content: ForEach(data, content: rowContent), _viewID: _viewID)
    }

    public init<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data,
        selection: Binding<SelectionValue?>?,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == ForEach<Data, Data.Element.ID, RowContent>, Data.Element: Identifiable {
        self.init(selection: CollectionSelection(selection), content: ForEach(data, content: rowContent), _viewID: _viewID)
    }

    @_disfavoredOverload
    public init<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data,
        selection: Binding<SelectionValue>,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == ForEach<Data, Data.Element.ID, RowContent>, Data.Element: Identifiable {
        self.init(selection: CollectionSelection(selection), content: ForEach(data, content: rowContent), _viewID: _viewID)
    }

    public init<Data: RandomAccessCollection, ID: Hashable, RowContent: View>(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        selection: Binding<Set<SelectionValue>>?,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == ForEach<Data, ID, RowContent> {
        self.init(selection: CollectionSelection(selection), content: ForEach(data, id: id, content: rowContent), _viewID: _viewID)
    }

    public init<Data: RandomAccessCollection, ID: Hashable, RowContent: View>(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        selection: Binding<SelectionValue?>?,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == ForEach<Data, ID, RowContent> {
        self.init(selection: CollectionSelection(selection), content: ForEach(data, id: id, content: rowContent), _viewID: _viewID)
    }

    @_disfavoredOverload
    public init<Data: RandomAccessCollection, ID: Hashable, RowContent: View>(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        selection: Binding<SelectionValue>,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == ForEach<Data, ID, RowContent> {
        self.init(selection: CollectionSelection(selection), content: ForEach(data, id: id, content: rowContent), _viewID: _viewID)
    }

    public init<RowContent: View>(
        _ data: Range<Int>,
        selection: Binding<Set<SelectionValue>>?,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Int) -> RowContent
    ) where Content == ForEach<Range<Int>, Int, RowContent> {
        self.init(selection: CollectionSelection(selection), content: ForEach(data, content: rowContent), _viewID: _viewID)
    }

    public init<RowContent: View>(
        _ data: Range<Int>,
        selection: Binding<SelectionValue?>?,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Int) -> RowContent
    ) where Content == ForEach<Range<Int>, Int, RowContent> {
        self.init(selection: CollectionSelection(selection), content: ForEach(data, content: rowContent), _viewID: _viewID)
    }

    @_disfavoredOverload
    public init<RowContent: View>(
        _ data: Range<Int>,
        selection: Binding<SelectionValue>,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Int) -> RowContent
    ) where Content == ForEach<Range<Int>, Int, RowContent> {
        self.init(selection: CollectionSelection(selection), content: ForEach(data, content: rowContent), _viewID: _viewID)
    }
}

// MARK: - Initializers over a tree

extension List {
    public init<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data,
        children: KeyPath<Data.Element, Data?>,
        selection: Binding<Set<SelectionValue>>?,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == OutlineGroup<Data, Data.Element.ID, RowContent, RowContent, DisclosureGroup<RowContent, OutlineSubgroupChildren>>,
            Data.Element: Identifiable {
        self.init(selection: CollectionSelection(selection), content: OutlineGroup(data, children: children, content: rowContent), _viewID: _viewID)
    }

    public init<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data,
        children: KeyPath<Data.Element, Data?>,
        selection: Binding<SelectionValue?>?,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == OutlineGroup<Data, Data.Element.ID, RowContent, RowContent, DisclosureGroup<RowContent, OutlineSubgroupChildren>>,
            Data.Element: Identifiable {
        self.init(selection: CollectionSelection(selection), content: OutlineGroup(data, children: children, content: rowContent), _viewID: _viewID)
    }

    @_disfavoredOverload
    public init<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data,
        children: KeyPath<Data.Element, Data?>,
        selection: Binding<SelectionValue>,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == OutlineGroup<Data, Data.Element.ID, RowContent, RowContent, DisclosureGroup<RowContent, OutlineSubgroupChildren>>,
            Data.Element: Identifiable {
        self.init(selection: CollectionSelection(selection), content: OutlineGroup(data, children: children, content: rowContent), _viewID: _viewID)
    }

    public init<Data: RandomAccessCollection, ID: Hashable, RowContent: View>(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        children: KeyPath<Data.Element, Data?>,
        selection: Binding<Set<SelectionValue>>?,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == OutlineGroup<Data, ID, RowContent, RowContent, DisclosureGroup<RowContent, OutlineSubgroupChildren>> {
        self.init(selection: CollectionSelection(selection), content: OutlineGroup(data, id: id, children: children, content: rowContent), _viewID: _viewID)
    }

    public init<Data: RandomAccessCollection, ID: Hashable, RowContent: View>(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        children: KeyPath<Data.Element, Data?>,
        selection: Binding<SelectionValue?>?,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == OutlineGroup<Data, ID, RowContent, RowContent, DisclosureGroup<RowContent, OutlineSubgroupChildren>> {
        self.init(selection: CollectionSelection(selection), content: OutlineGroup(data, id: id, children: children, content: rowContent), _viewID: _viewID)
    }

    @_disfavoredOverload
    public init<Data: RandomAccessCollection, ID: Hashable, RowContent: View>(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        children: KeyPath<Data.Element, Data?>,
        selection: Binding<SelectionValue>,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == OutlineGroup<Data, ID, RowContent, RowContent, DisclosureGroup<RowContent, OutlineSubgroupChildren>> {
        self.init(selection: CollectionSelection(selection), content: OutlineGroup(data, id: id, children: children, content: rowContent), _viewID: _viewID)
    }
}

// MARK: - Without a selection

extension List where SelectionValue == Never {
    public init(_viewID: ViewID = #viewID, @ViewBuilder content: () -> Content) {
        self.init(selection: CollectionSelection(storage: .none), content: content(), _viewID: _viewID)
    }

    public init<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == ForEach<Data, Data.Element.ID, RowContent>, Data.Element: Identifiable {
        self.init(selection: CollectionSelection(storage: .none), content: ForEach(data, content: rowContent), _viewID: _viewID)
    }

    public init<Data: RandomAccessCollection, ID: Hashable, RowContent: View>(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == ForEach<Data, ID, RowContent> {
        self.init(selection: CollectionSelection(storage: .none), content: ForEach(data, id: id, content: rowContent), _viewID: _viewID)
    }

    public init<RowContent: View>(
        _ data: Range<Int>,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Int) -> RowContent
    ) where Content == ForEach<Range<Int>, Int, RowContent> {
        self.init(selection: CollectionSelection(storage: .none), content: ForEach(data, content: rowContent), _viewID: _viewID)
    }

    public init<Data: RandomAccessCollection, RowContent: View>(
        _ data: Data,
        children: KeyPath<Data.Element, Data?>,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == OutlineGroup<Data, Data.Element.ID, RowContent, RowContent, DisclosureGroup<RowContent, OutlineSubgroupChildren>>,
            Data.Element: Identifiable {
        self.init(selection: CollectionSelection(storage: .none), content: OutlineGroup(data, children: children, content: rowContent), _viewID: _viewID)
    }

    public init<Data: RandomAccessCollection, ID: Hashable, RowContent: View>(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        children: KeyPath<Data.Element, Data?>,
        _viewID: ViewID = #viewID,
        @ViewBuilder rowContent: @escaping (Data.Element) -> RowContent
    ) where Content == OutlineGroup<Data, ID, RowContent, RowContent, DisclosureGroup<RowContent, OutlineSubgroupChildren>> {
        self.init(selection: CollectionSelection(storage: .none), content: OutlineGroup(data, id: id, children: children, content: rowContent), _viewID: _viewID)
    }
}

// MARK: - Styles

/// The appearance of the lists in a subtree.
///
/// As in SwiftUI, the styles are the ones listed here; the protocol's one
/// requirement is underscored and not meant to be implemented outside the
/// framework.
@MainActor
public protocol ListStyle {
    var _kind: _ListStyleKind { get }
}

/// How a list draws its rows — the part of a `ListStyle` the list reads.
public enum _ListStyleKind: Hashable, Sendable {
    case plain
    case inset
    case sidebar
    case bordered
    case grouped
    case insetGrouped
}

/// The platform's style: `.inset` on the desktop, `.insetGrouped` on a
/// phone.
public struct DefaultListStyle: ListStyle {
    public init() {}
    public var _kind: _ListStyleKind { .platformDefault }
}

/// Rows edge to edge, a rule between each two.
public struct PlainListStyle: ListStyle {
    public init() {}
    public var _kind: _ListStyleKind { .plain }
}

/// Rows set in from the edges, a selected row drawn as a rounded
/// highlight.
public struct InsetListStyle: ListStyle {
    public init() {}
    public var _kind: _ListStyleKind { .inset }
}

/// A window's sidebar: no background of its own, no rules, small headings
/// over sections that can be collapsed.
public struct SidebarListStyle: ListStyle {
    public init() {}
    public var _kind: _ListStyleKind { .sidebar }
}

/// Inset rows inside a border.
public struct BorderedListStyle: ListStyle {
    public init() {}
    public var _kind: _ListStyleKind { .bordered }
}

/// Each section's rows in a band across the list, headings above.
public struct GroupedListStyle: ListStyle {
    public init() {}
    public var _kind: _ListStyleKind { .grouped }
}

/// Each section's rows in a rounded group set in from the edges, headings
/// above.
public struct InsetGroupedListStyle: ListStyle {
    public init() {}
    public var _kind: _ListStyleKind { .insetGrouped }
}

extension ListStyle where Self == DefaultListStyle {
    public static var automatic: DefaultListStyle { DefaultListStyle() }
}

extension ListStyle where Self == PlainListStyle {
    public static var plain: PlainListStyle { PlainListStyle() }
}

extension ListStyle where Self == InsetListStyle {
    public static var inset: InsetListStyle { InsetListStyle() }
}

extension ListStyle where Self == SidebarListStyle {
    public static var sidebar: SidebarListStyle { SidebarListStyle() }
}

extension ListStyle where Self == BorderedListStyle {
    public static var bordered: BorderedListStyle { BorderedListStyle() }
}

extension ListStyle where Self == GroupedListStyle {
    public static var grouped: GroupedListStyle { GroupedListStyle() }
}

extension ListStyle where Self == InsetGroupedListStyle {
    public static var insetGrouped: InsetGroupedListStyle { InsetGroupedListStyle() }
}

private struct ListStyleKindKey: EnvironmentKey {
    static var defaultValue: _ListStyleKind { _ListStyleKind.platformDefault }
}

extension _ListStyleKind {
    /// What `.automatic` is here.
    static var platformDefault: _ListStyleKind {
        #if os(iOS) || os(Android)
        .insetGrouped
        #else
        .inset
        #endif
    }
}

extension EnvironmentValues {
    /// How the lists in this subtree draw their rows.
    var listStyleKind: _ListStyleKind {
        get { self[ListStyleKindKey.self] }
        set { self[ListStyleKindKey.self] = newValue }
    }
}

extension View {
    /// Sets the style for lists within this view.
    public func listStyle<S: ListStyle>(_ style: S) -> some View {
        environment(\.listStyleKind, style._kind)
    }
}

// MARK: - How a style draws

/// The measurements and colours of one list style.
struct ListLook: Equatable {
    let kind: _ListStyleKind
    let alternates: Bool

    init(kind: _ListStyleKind, alternates: AlternatingRowBackgroundBehavior) {
        self.kind = kind
        self.alternates = alternates == .enabled
    }

    var isGrouped: Bool { kind == .grouped || kind == .insetGrouped }
    var isSidebar: Bool { kind == .sidebar }

    /// Around each row's content, unless the row sets its own.
    var rowInsets: EdgeInsets {
        switch kind {
        case .plain, .inset, .bordered: return EdgeInsets(top: 5, leading: 8, bottom: 5, trailing: 8)
        case .sidebar: return EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
        case .grouped, .insetGrouped: return EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
        }
    }

    /// Between the list's edges and its rows.
    var contentInsets: EdgeInsets {
        switch kind {
        case .plain: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        case .inset, .bordered: return EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        case .sidebar: return EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        case .grouped: return EdgeInsets(top: 16, leading: 0, bottom: 16, trailing: 0)
        case .insetGrouped: return EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)
        }
    }

    /// The corners of a selected row's highlight.
    var selectionRadius: Double {
        switch kind {
        case .plain, .grouped, .insetGrouped: return 0
        case .inset, .bordered: return 5
        case .sidebar: return 6
        }
    }

    /// Whether rows have a rule between them.
    var hasSeparators: Bool {
        !alternates && kind != .sidebar
    }

    var background: Color {
        switch kind {
        case .plain, .inset, .bordered: return .secondaryBackground
        case .sidebar: return .clear
        case .grouped, .insetGrouped: return .background
        }
    }

    /// How far each outline level is set in.
    static let indent: Double = 16
    /// The chevron's column.
    static let chevronWidth: Double = 12

    func selectionFill(isFocused: Bool, tint: Color) -> Color {
        if isSidebar { return isFocused ? SelectionColors.sidebarFocused : SelectionColors.sidebar }
        return isFocused ? tint : SelectionColors.unfocused
    }

    /// Whether a selected row's content turns white on the highlight.
    func invertsSelected(isFocused: Bool) -> Bool {
        isFocused && !isSidebar
    }
}

/// What the rows of one build of a list do when pressed — made fresh by
/// every build, so a row always acts on what that build saw.
@MainActor
final class ListActions<SelectionValue: Hashable> {
    let selection: CollectionSelection<SelectionValue>
    /// The selectable rows' values, top to bottom.
    let order: [SelectionValue]
    let cursor: SelectionCursor<SelectionValue>
    let menu: SelectionContextMenuBox?
    let isEnabled: Bool

    init(
        selection: CollectionSelection<SelectionValue>,
        order: [SelectionValue],
        cursor: SelectionCursor<SelectionValue>,
        menu: SelectionContextMenuBox?,
        isEnabled: Bool
    ) {
        self.selection = selection
        self.order = order
        self.cursor = cursor
        self.menu = menu
        self.isEnabled = isEnabled
    }

    /// A press on the row `value`; a second in quick succession runs the
    /// primary action on the selection.
    func press(_ value: SelectionValue) {
        selection.press(value, modifiers: PointerPress.modifiers, order: order, cursor: cursor)
        if cursor.click(value) {
            runPrimaryAction()
        }
    }

    func runPrimaryAction() {
        let values = selection.values
        guard !values.isEmpty else { return }
        menu?.storage.runPrimaryAction(values)
    }

    /// The items of the menu for a right click on the row `value`: the
    /// selection's, when the row is part of it, and the row's alone
    /// otherwise.
    func menuItems(for value: SelectionValue?) -> AnyView? {
        guard let menu else { return nil }
        let values: Set<SelectionValue>
        if let value {
            values = selection.contains(value) ? selection.values : [value]
        } else {
            values = []
        }
        return menu.storage.items(for: values)
    }
}

// MARK: - Plain, inset, sidebar, bordered

/// One item of the list's column, with what drawing it needs to know about
/// its neighbours.
struct ListEntry<SelectionValue: Hashable>: Identifiable {
    let item: ListItem<SelectionValue>
    /// The row's place among rows, for alternating backgrounds.
    let rowIndex: Int
    /// Whether a rule goes under this row.
    let showsSeparator: Bool
    /// Whether this is the first item of the list.
    let isFirst: Bool

    var id: Int { item.id }
}

/// Lay out `items` as the column of a list: which rows get a rule under
/// them, and each row's index among rows.
@MainActor
func listEntries<SelectionValue: Hashable>(_ items: [ListItem<SelectionValue>], look: ListLook) -> [ListEntry<SelectionValue>] {
    var entries: [ListEntry<SelectionValue>] = []
    var rowIndex = 0
    for (index, item) in items.enumerated() {
        var separator = false
        if item.kind == .row, look.hasSeparators, index + 1 < items.count {
            let next = items[index + 1]
            separator = next.kind == .row
                && next.section == item.section
                && item.traits.bottomSeparator != .hidden
                && next.traits.topSeparator != .hidden
        }
        entries.append(ListEntry(item: item, rowIndex: rowIndex, showsSeparator: separator, isFirst: index == 0))
        if item.kind == .row { rowIndex += 1 }
    }
    return entries
}

/// The list's column, scrolling, for the styles that aren't grouped.
@View
struct _ListBody<SelectionValue: Hashable> {
    let items: [ListItem<SelectionValue>]
    let look: ListLook
    let actions: ListActions<SelectionValue>
    let isFocused: Bool

    var body: some View {
        let entries = listEntries(items, look: look)
        let actions = self.actions
        let look = self.look
        let isFocused = self.isFocused
        ZStack(alignment: .topLeading) {
            // A press below the rows selects nothing; a right click there
            // opens the menu for no rows.
            _ListBackground(look: look, actions: actions)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        if entry.item.kind == .row {
                            _ListRow(entry: entry, look: look, actions: actions, isFocused: isFocused)
                        } else {
                            _ListSectionItem(item: entry.item, look: look, isFirst: entry.isFirst)
                        }
                    }
                }
                .padding(look.contentInsets)
            }
        }
        .border(look.kind == .bordered ? Color.separator : Color.clear, width: 1)
    }
}

/// Behind the rows: the style's background, taking the presses that miss
/// every row.
@View
struct _ListBackground<SelectionValue: Hashable> {
    let look: ListLook
    let actions: ListActions<SelectionValue>

    var body: some View {
        let actions = self.actions
        if let items = actions.menuItems(for: nil) {
            Rectangle()
                .fill(look.background)
                ._hitTarget(HitTarget(isEnabled: actions.isEnabled, onPress: { _ in actions.selection.clear() }))
                .contextMenu { items }
        } else {
            Rectangle()
                .fill(look.background)
                ._hitTarget(HitTarget(isEnabled: actions.isEnabled, onPress: { _ in actions.selection.clear() }))
        }
    }
}

/// One row: indented to its outline level, a chevron if it opens, its
/// content, its badge — on its highlight when selected.
@View
struct _ListRow<SelectionValue: Hashable> {
    let entry: ListEntry<SelectionValue>
    let look: ListLook
    let actions: ListActions<SelectionValue>
    let isFocused: Bool

    @Environment(\.tint) private var tint

    var body: some View {
        let item = entry.item
        let actions = self.actions
        let isSelected = item.tag.map { actions.selection.contains($0) } ?? false
        let inverted = isSelected && look.invertsSelected(isFocused: isFocused)
        let insets = item.traits.insets ?? look.rowInsets
        let row = _ListRowContent(item: item, inverted: inverted, look: look)
            .padding(insets)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(_ListRowBackground(
                item: item,
                isSelected: isSelected,
                isAlternate: look.alternates && entry.rowIndex % 2 == 1,
                fill: look.selectionFill(isFocused: isFocused, tint: tint),
                radius: look.selectionRadius
            ))
            .overlay(alignment: .bottom) {
                if entry.showsSeparator {
                    Rectangle()
                        .fill(item.traits.separatorTint ?? Color.separator)
                        .frame(height: 1)
                        .padding(.leading, insets.leading)
                }
            }
            ._hitTarget(HitTarget(
                isEnabled: actions.isEnabled && item.tag != nil && !item.traits.selectionDisabled,
                onPress: { _ in
                    if let tag = item.tag { actions.press(tag) }
                }
            ))
        if let menu = actions.menuItems(for: item.tag), item.tag != nil {
            row.contextMenu { menu }
        } else {
            row
        }
    }
}

/// A row's content line: the indent, the chevron, the label, the badge.
@View
struct _ListRowContent<SelectionValue: Hashable> {
    let item: ListItem<SelectionValue>
    let inverted: Bool
    let look: ListLook

    var body: some View {
        let item = self.item
        HStack(spacing: 4) {
            if item.depth > 0 {
                Spacer()
                    .frame(width: Double(item.depth) * ListLook.indent)
            }
            if let disclosure = item.disclosure {
                _ListChevron(isExpanded: disclosure.isExpanded, inverted: inverted)
                    .onTapGesture { disclosure.binding.wrappedValue = !disclosure.isExpanded }
            } else if item.isInOutline {
                Spacer()
                    .frame(width: ListLook.chevronWidth)
            }
            if inverted {
                item.label
                    .foregroundColor(.white)
                    .environment(\.backgroundProminence, .increased)
            } else {
                item.label
            }
            if let badge = item.traits.badge {
                Spacer(minLength: 8)
                badge
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(inverted ? .white : .secondary)
            }
        }
    }
}

/// A row's backdrop: its own background, and over it the highlight when
/// the row is selected.
@View
struct _ListRowBackground<SelectionValue: Hashable> {
    let item: ListItem<SelectionValue>
    let isSelected: Bool
    let isAlternate: Bool
    let fill: Color
    let radius: Double

    var body: some View {
        ZStack {
            if let background = item.traits.background {
                background
            } else if isAlternate {
                Rectangle().fill(SelectionColors.alternate)
            }
            if isSelected {
                RoundedRectangle(cornerRadius: radius)
                    .fill(fill)
            }
        }
    }
}

/// The "›" before a row that opens, turned down while it is open.
@View
struct _ListChevron {
    let isExpanded: Bool
    let inverted: Bool

    var body: some View {
        Text("›")
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(inverted ? .white : .secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: ListLook.chevronWidth)
            .animation(.snappy(duration: 0.2), value: isExpanded)
    }
}

/// A section's header or footer in a list that isn't grouped.
@View
struct _ListSectionItem<SelectionValue: Hashable> {
    let item: ListItem<SelectionValue>
    let look: ListLook
    let isFirst: Bool

    @State private var isHovered = false

    var body: some View {
        let item = self.item
        let insets = look.rowInsets
        if item.kind == .header {
            HStack(spacing: 4) {
                item.label
                    .font(.system(size: look.isSidebar ? 11 : 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer(minLength: 4)
                // A sidebar shows the chevron while the pointer is over the
                // header, or while the section is closed; another list
                // shows it whenever the section can close. The chevron,
                // not the header, opens and closes it.
                if let disclosure = item.disclosure {
                    _ListChevron(isExpanded: disclosure.isExpanded, inverted: false)
                        .opacity(!look.isSidebar || isHovered || !disclosure.isExpanded ? 1 : 0)
                        .onTapGesture { disclosure.binding.wrappedValue = !disclosure.isExpanded }
                }
            }
            .padding(.horizontal, insets.leading)
            .padding(.top, isFirst ? 4 : 14)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onHover { isHovered = $0 }
        } else {
            item.label
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(.horizontal, insets.leading)
                .padding(.top, 4)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Grouped, inset grouped

/// One section of a grouped list: its header, its rows, its footer.
struct ListGroup<SelectionValue: Hashable>: Identifiable {
    let id: Int
    var header: ListItem<SelectionValue>?
    var rows: [ListEntry<SelectionValue>] = []
    var footer: ListItem<SelectionValue>?
}

/// Split a grouped list's items into its sections.
@MainActor
func listGroups<SelectionValue: Hashable>(_ items: [ListItem<SelectionValue>], look: ListLook) -> [ListGroup<SelectionValue>] {
    var groups: [ListGroup<SelectionValue>] = []
    for entry in listEntries(items, look: look) {
        let item = entry.item
        if groups.last?.id != item.section {
            groups.append(ListGroup(id: item.section))
        }
        switch item.kind {
        case .header: groups[groups.count - 1].header = item
        case .row: groups[groups.count - 1].rows.append(entry)
        case .footer: groups[groups.count - 1].footer = item
        }
    }
    return groups
}

/// The list's sections as bands (`.grouped`) or rounded groups
/// (`.insetGrouped`) down a scrolling column.
@View
struct _GroupedListBody<SelectionValue: Hashable> {
    let items: [ListItem<SelectionValue>]
    let look: ListLook
    let actions: ListActions<SelectionValue>
    let isFocused: Bool

    var body: some View {
        let groups = listGroups(items, look: look)
        let actions = self.actions
        let look = self.look
        let isFocused = self.isFocused
        let radius: Double = look.kind == .insetGrouped ? 10 : 0
        ZStack(alignment: .topLeading) {
            _ListBackground(look: look, actions: actions)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            if let header = group.header {
                                _GroupedSectionHeader(item: header)
                            }
                            if !group.rows.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(group.rows) { entry in
                                        _ListRow(entry: entry, look: look, actions: actions, isFocused: isFocused)
                                    }
                                }
                                .background(Color.secondaryBackground)
                                .cornerRadius(radius)
                            }
                            if let footer = group.footer {
                                footer.label
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                }
                .padding(look.contentInsets)
            }
        }
    }
}

/// A grouped section's heading: small, above its group, with a chevron
/// when it can be closed.
@View
struct _GroupedSectionHeader<SelectionValue: Hashable> {
    let item: ListItem<SelectionValue>

    var body: some View {
        let item = self.item
        HStack(spacing: 4) {
            item.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer(minLength: 4)
            if let disclosure = item.disclosure {
                _ListChevron(isExpanded: disclosure.isExpanded, inverted: false)
                    .onTapGesture { disclosure.binding.wrappedValue = !disclosure.isExpanded }
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Keys

/// What a list or table does with the keys, made fresh by every build — a
/// class so `@View` compares it by identity and never keeps a stale one.
@MainActor
final class CollectionKeys {
    let isEnabled: Bool
    let editCommands: Set<EditCommand>
    let onFocusChange: @MainActor (Bool) -> Void
    let onKeyDown: @MainActor (KeyEvent) -> Void
    let onEditCommand: @MainActor (EditCommand) -> Void

    init(
        isEnabled: Bool,
        editCommands: Set<EditCommand>,
        onFocusChange: @escaping @MainActor (Bool) -> Void,
        onKeyDown: @escaping @MainActor (KeyEvent) -> Void,
        onEditCommand: @escaping @MainActor (EditCommand) -> Void
    ) {
        self.isEnabled = isEnabled
        self.editCommands = editCommands
        self.onFocusChange = onFocusChange
        self.onKeyDown = onKeyDown
        self.onEditCommand = onEditCommand
    }
}

/// Puts a list's or table's `FocusTarget` on a node around it: a press
/// anywhere on it that no view inside takes the keys for gives them to the
/// collection, and Tab stops on it.
@View
struct _CollectionFocus<Content: View> {
    let keys: CollectionKeys
    let content: Content

    init(keys: CollectionKeys, _viewID: ViewID = #viewID, @ViewBuilder content: () -> Content) {
        self.keys = keys
        self.content = content()
        self._viewID = _viewID
    }

    var body: Never { bodyUnavailable() }
}

extension _CollectionFocus: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let keys = self.keys
        let target = FocusTarget(
            path: context.path,
            isEnabled: keys.isEnabled,
            onFocusChange: { keys.onFocusChange($0) },
            onKeyDown: { keys.onKeyDown($0) },
            editCommands: keys.editCommands,
            onEditCommand: { keys.onEditCommand($0) },
            isTabStop: true
        )
        let child = context.child(0) { ctx in buildNode(content, &ctx) }
        return ViewNode(content: CollectionFocusContent(focus: target), children: [child])
    }
}

/// Lays out as what it wraps; holds the keys for it.
struct CollectionFocusContent: NodeContent {
    let focus: FocusTarget

    var focusTarget: FocusTarget? { focus }
}
