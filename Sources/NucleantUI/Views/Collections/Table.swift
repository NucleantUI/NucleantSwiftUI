//
//  Table.swift
//  NucleantUI
//

import Foundation

/// Rows of values in columns, under a row of headers.
///
/// ```swift
/// @State private var sortOrder = [KeyPathComparator(\Issue.number)]
///
/// Table(tracker.issues.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
///     TableColumn("#", value: \.number) { Text("\($0.number)") }
///         .width(50)
///     TableColumn("Title", value: \.title)
///     TableColumn("Assignee") { issue in Text(issue.assignee.name) }
/// }
/// ```
///
/// Each `TableColumn` gives a header and builds a cell per row. Given a
/// `sortOrder`, a click on the header of a column that sorts makes it the
/// first key of the order, and a second click flips it; the table only
/// changes the order — sorting the rows by it is the caller's, as in
/// SwiftUI. Columns share the width; a `.width(_:)` fixes one, a
/// `.width(min:ideal:max:)` bounds one, and dragging the edge between two
/// headers resizes the one on the left.
///
/// Rows are selected as a `List`'s are: a click, ⌘- and ⇧-click with a set
/// for the selection, ↑ and ↓ (⇧ to extend) while the table has the keys,
/// ⌘A. `.contextMenu(forSelectionType:menu:primaryAction:)` adds a menu to
/// the rows and an action for a double click or Return;
/// `.onDeleteCommand` runs on Delete.
@View
public struct Table<Value: Identifiable, Rows: TableRowContent, Columns: TableColumnContent>: View
where Rows.TableRowValue == Value, Columns.TableRowValue == Value {
    let rows: Rows
    let columns: Columns
    let selection: CollectionSelection<Value.ID>
    let sort: TableSortSource

    @Environment(\.tableStyleKind) private var style
    @Environment(\.tableColumnHeaders) private var headers
    @Environment(\.alternatingRowBackgrounds) private var alternates
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.selectionContextMenu) private var selectionMenu
    @Environment(\.deleteCommand) private var deleteCommand

    /// Widths the user dragged columns to, by column index.
    @State private var columnWidths: [Int: Double] = [:]
    @State private var cursor = SelectionCursor<Value.ID>()
    @State private var isFocused = false

    init(
        rows: Rows,
        columns: Columns,
        selection: CollectionSelection<Value.ID>,
        sort: TableSortState?,
        _viewID: ViewID
    ) {
        self.rows = rows
        self.columns = columns
        self.selection = selection
        self.sort = TableSortSource(state: sort)
        self._viewID = _viewID
    }

    public var body: some View {
        let specs = makeSpecs()
        let values = makeRows()
        let look = TableLook(kind: style, alternates: alternates)
        let layout = TableColumnLayout(
            widths: specs.map(\.width),
            userWidths: columnWidths,
            cellPadding: TableLook.cellPadding
        )
        let cells = TableCells<Value>(cells: specs.map(\.cell), layout: layout)
        let order = values.map(\.id)
        let actions = ListActions(
            selection: selection,
            order: order,
            cursor: cursor,
            menu: selectionMenu,
            isEnabled: isEnabled
        )
        let entries = values.enumerated().map { TableRowEntry(index: $0.offset, value: $0.element) }
        let isFocused = self.isFocused
        let focus = $isFocused
        let widths = $columnWidths
        _CollectionFocus(
            keys: CollectionKeys(
                isEnabled: isEnabled && selection.isSelectable,
                editCommands: selection.allowsMultiple ? [.selectAll] : [],
                onFocusChange: { focus.wrappedValue = $0 },
                onKeyDown: { event in handleKey(event, actions: actions) },
                onEditCommand: { command in
                    if command == .selectAll { actions.selection.selectAll(order) }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if headers != .hidden {
                    _TableHeader(
                        headers: specs.map(\.header),
                        sorts: specs.map(\.sort),
                        sortState: sort.state,
                        layout: layout,
                        widths: widths,
                        look: look
                    )
                    Rectangle()
                        .fill(Color.separator)
                        .frame(height: 1)
                }
                ZStack(alignment: .topLeading) {
                    _ListBackground(look: ListLook(kind: .plain, alternates: .disabled), actions: actions)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(entries) { entry in
                                _TableRow(entry: entry, cells: cells, look: look, actions: actions, isFocused: isFocused)
                            }
                        }
                        .padding(.horizontal, look.horizontalInset)
                        .padding(.vertical, look.verticalInset)
                    }
                }
            }
            // Columns that can't shrink to fit spill past the edge; they
            // are cut off there rather than drawn over what is beside.
            .clipped()
            .border(look.kind == .bordered ? Color.separator : Color.clear, width: 1)
        }
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func makeSpecs() -> [TableColumnSpec<Value>] {
        var specs: [TableColumnSpec<Value>] = []
        columns._tableColumns(into: &specs)
        return specs
    }

    private func makeRows() -> [Value] {
        var values: [Value] = []
        rows._tableRows(into: &values)
        return values
    }

    private func handleKey(_ event: KeyEvent, actions: ListActions<Value.ID>) {
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
        case CollectionKey.returnKey, CollectionKey.enter:
            actions.runPrimaryAction()
        case CollectionKey.delete, CollectionKey.forwardDelete:
            deleteCommand?.perform()
        default:
            break
        }
    }
}

/// The table's sort order as the table holds it — compared by the binding
/// it wraps, so a table over the same order is the same input.
struct TableSortSource: ViewInput {
    let state: TableSortState?

    func _isEquivalent(to other: TableSortSource) -> Bool {
        switch (state, other.state) {
        case (nil, nil): return true
        case let (mine?, theirs?): return mine.isEquivalent(to: theirs)
        default: return false
        }
    }
}

// MARK: - Initializers over data

extension Table {
    public init<Data: RandomAccessCollection>(
        _ data: Data,
        _viewID: ViewID = #viewID,
        @TableColumnBuilder<Value, Never> columns: () -> Columns
    ) where Rows == TableForEachContent<Data> {
        self.init(rows: TableForEachContent(data: data), columns: columns(), selection: CollectionSelection(storage: .none), sort: nil, _viewID: _viewID)
    }

    public init<Data: RandomAccessCollection>(
        _ data: Data,
        selection: Binding<Value.ID?>,
        _viewID: ViewID = #viewID,
        @TableColumnBuilder<Value, Never> columns: () -> Columns
    ) where Rows == TableForEachContent<Data> {
        self.init(rows: TableForEachContent(data: data), columns: columns(), selection: CollectionSelection(selection), sort: nil, _viewID: _viewID)
    }

    public init<Data: RandomAccessCollection>(
        _ data: Data,
        selection: Binding<Set<Value.ID>>,
        _viewID: ViewID = #viewID,
        @TableColumnBuilder<Value, Never> columns: () -> Columns
    ) where Rows == TableForEachContent<Data> {
        self.init(rows: TableForEachContent(data: data), columns: columns(), selection: CollectionSelection(selection), sort: nil, _viewID: _viewID)
    }

    public init<Data: RandomAccessCollection, Sort: SortComparator>(
        _ data: Data,
        sortOrder: Binding<[Sort]>,
        _viewID: ViewID = #viewID,
        @TableColumnBuilder<Value, Sort> columns: () -> Columns
    ) where Rows == TableForEachContent<Data>, Data.Element == Sort.Compared {
        self.init(
            rows: TableForEachContent(data: data),
            columns: columns(),
            selection: CollectionSelection(storage: .none),
            sort: TypedTableSortState(sortOrder),
            _viewID: _viewID
        )
    }

    public init<Data: RandomAccessCollection, Sort: SortComparator>(
        _ data: Data,
        selection: Binding<Value.ID?>,
        sortOrder: Binding<[Sort]>,
        _viewID: ViewID = #viewID,
        @TableColumnBuilder<Value, Sort> columns: () -> Columns
    ) where Rows == TableForEachContent<Data>, Data.Element == Sort.Compared {
        self.init(
            rows: TableForEachContent(data: data),
            columns: columns(),
            selection: CollectionSelection(selection),
            sort: TypedTableSortState(sortOrder),
            _viewID: _viewID
        )
    }

    public init<Data: RandomAccessCollection, Sort: SortComparator>(
        _ data: Data,
        selection: Binding<Set<Value.ID>>,
        sortOrder: Binding<[Sort]>,
        _viewID: ViewID = #viewID,
        @TableColumnBuilder<Value, Sort> columns: () -> Columns
    ) where Rows == TableForEachContent<Data>, Data.Element == Sort.Compared {
        self.init(
            rows: TableForEachContent(data: data),
            columns: columns(),
            selection: CollectionSelection(selection),
            sort: TypedTableSortState(sortOrder),
            _viewID: _viewID
        )
    }
}

// MARK: - Initializers over rows

extension Table {
    public init(
        of valueType: Value.Type,
        _viewID: ViewID = #viewID,
        @TableColumnBuilder<Value, Never> columns: () -> Columns,
        @TableRowBuilder<Value> rows: () -> Rows
    ) {
        self.init(rows: rows(), columns: columns(), selection: CollectionSelection(storage: .none), sort: nil, _viewID: _viewID)
    }

    public init(
        of valueType: Value.Type,
        selection: Binding<Value.ID?>,
        _viewID: ViewID = #viewID,
        @TableColumnBuilder<Value, Never> columns: () -> Columns,
        @TableRowBuilder<Value> rows: () -> Rows
    ) {
        self.init(rows: rows(), columns: columns(), selection: CollectionSelection(selection), sort: nil, _viewID: _viewID)
    }

    public init(
        of valueType: Value.Type,
        selection: Binding<Set<Value.ID>>,
        _viewID: ViewID = #viewID,
        @TableColumnBuilder<Value, Never> columns: () -> Columns,
        @TableRowBuilder<Value> rows: () -> Rows
    ) {
        self.init(rows: rows(), columns: columns(), selection: CollectionSelection(selection), sort: nil, _viewID: _viewID)
    }

    public init<Sort: SortComparator>(
        of valueType: Value.Type,
        sortOrder: Binding<[Sort]>,
        _viewID: ViewID = #viewID,
        @TableColumnBuilder<Value, Sort> columns: () -> Columns,
        @TableRowBuilder<Value> rows: () -> Rows
    ) where Value == Sort.Compared {
        self.init(rows: rows(), columns: columns(), selection: CollectionSelection(storage: .none), sort: TypedTableSortState(sortOrder), _viewID: _viewID)
    }

    public init<Sort: SortComparator>(
        of valueType: Value.Type,
        selection: Binding<Value.ID?>,
        sortOrder: Binding<[Sort]>,
        _viewID: ViewID = #viewID,
        @TableColumnBuilder<Value, Sort> columns: () -> Columns,
        @TableRowBuilder<Value> rows: () -> Rows
    ) where Value == Sort.Compared {
        self.init(rows: rows(), columns: columns(), selection: CollectionSelection(selection), sort: TypedTableSortState(sortOrder), _viewID: _viewID)
    }

    public init<Sort: SortComparator>(
        of valueType: Value.Type,
        selection: Binding<Set<Value.ID>>,
        sortOrder: Binding<[Sort]>,
        _viewID: ViewID = #viewID,
        @TableColumnBuilder<Value, Sort> columns: () -> Columns,
        @TableRowBuilder<Value> rows: () -> Rows
    ) where Value == Sort.Compared {
        self.init(rows: rows(), columns: columns(), selection: CollectionSelection(selection), sort: TypedTableSortState(sortOrder), _viewID: _viewID)
    }
}

// MARK: - Styles

/// The appearance of the tables in a subtree.
///
/// As in SwiftUI, the styles are the ones listed here; the protocol's one
/// requirement is underscored and not meant to be implemented outside the
/// framework.
@MainActor
public protocol TableStyle {
    var _kind: _TableStyleKind { get }
}

/// How a table draws its rows — the part of a `TableStyle` the table
/// reads.
public enum _TableStyleKind: Hashable, Sendable {
    /// Rows set in from the edges, rounded selection; `alternates` says
    /// whether every other row is shaded.
    case inset(alternates: Bool)
    /// Rows edge to edge inside a border, every other row shaded.
    case bordered
}

/// The platform's style: here, `.inset`.
public struct AutomaticTableStyle: TableStyle {
    public init() {}
    public var _kind: _TableStyleKind { .inset(alternates: true) }
}

public struct InsetTableStyle: TableStyle {
    let alternates: Bool

    public init() {
        self.alternates = true
    }

    init(alternates: Bool) {
        self.alternates = alternates
    }

    public var _kind: _TableStyleKind { .inset(alternates: alternates) }
}

public struct BorderedTableStyle: TableStyle {
    public init() {}
    public var _kind: _TableStyleKind { .bordered }
}

extension TableStyle where Self == AutomaticTableStyle {
    public static var automatic: AutomaticTableStyle { AutomaticTableStyle() }
}

extension TableStyle where Self == InsetTableStyle {
    public static var inset: InsetTableStyle { InsetTableStyle() }

    /// Rows set in from the edges, shaded every other row or not.
    public static func inset(alternatesRowBackgrounds: Bool) -> InsetTableStyle {
        InsetTableStyle(alternates: alternatesRowBackgrounds)
    }
}

extension TableStyle where Self == BorderedTableStyle {
    public static var bordered: BorderedTableStyle { BorderedTableStyle() }
}

private struct TableStyleKindKey: EnvironmentKey {
    static let defaultValue = _TableStyleKind.inset(alternates: true)
}

private struct TableColumnHeadersKey: EnvironmentKey {
    static let defaultValue = Visibility.automatic
}

extension EnvironmentValues {
    var tableStyleKind: _TableStyleKind {
        get { self[TableStyleKindKey.self] }
        set { self[TableStyleKindKey.self] = newValue }
    }

    var tableColumnHeaders: Visibility {
        get { self[TableColumnHeadersKey.self] }
        set { self[TableColumnHeadersKey.self] = newValue }
    }
}

extension View {
    /// Sets the style for tables within this view.
    public func tableStyle<S: TableStyle>(_ style: S) -> some View {
        environment(\.tableStyleKind, style._kind)
    }

    /// Shows or hides the row of column headers of the tables in this view.
    public func tableColumnHeaders(_ visibility: Visibility) -> some View {
        environment(\.tableColumnHeaders, visibility)
    }
}

/// The measurements and colours of one table style.
struct TableLook: Equatable {
    enum Kind: Equatable {
        case inset
        case bordered
    }

    let kind: Kind
    let alternates: Bool

    init(kind: _TableStyleKind, alternates: AlternatingRowBackgroundBehavior) {
        switch kind {
        case .inset(let styleAlternates):
            self.kind = .inset
            self.alternates = alternates == .automatic ? styleAlternates : alternates == .enabled
        case .bordered:
            self.kind = .bordered
            self.alternates = alternates != .disabled
        }
    }

    var horizontalInset: Double { kind == .inset ? 10 : 0 }
    var verticalInset: Double { kind == .inset ? 4 : 0 }
    var selectionRadius: Double { kind == .inset ? 5 : 0 }

    /// Space either side of a cell's content within its column.
    static let cellPadding = 6.0
    /// Above and below a row's cells.
    static let rowPadding = 4.0
}

// MARK: - Column widths

/// How wide each column is, for the width the table has: fixed columns
/// and those with an ideal or a dragged width first, the rest sharing what
/// is left, and whatever is still left going to the last column that can
/// grow. Every row and the header lay out against the same object, so the
/// columns line up.
@MainActor
final class TableColumnLayout {
    let widths: [TableColumnWidth]
    let userWidths: [Int: Double]
    let cellPadding: Double

    private var cached: (total: Double, widths: [Double])?

    /// The widths of the last layout, if there has been one.
    var lastWidths: [Double]? { cached?.widths }

    init(widths: [TableColumnWidth], userWidths: [Int: Double], cellPadding: Double) {
        self.widths = widths
        self.userWidths = userWidths
        self.cellPadding = cellPadding
    }

    /// The column widths when the table has no width to fill.
    var idealWidths: [Double] {
        widths.enumerated().map { index, width in
            if let user = userWidths[index] { return clamp(user, width) }
            switch width {
            case .automatic: return 100
            case .fixed(let value): return value
            case .flexible(let min, let ideal, _): return ideal ?? min ?? 100
            }
        }
    }

    /// The widths that fill `total`.
    func widths(for total: Double) -> [Double] {
        if let cached, cached.total == total { return cached.widths }
        var result = [Double?](repeating: nil, count: widths.count)
        for (index, width) in widths.enumerated() {
            if let user = userWidths[index], !width.isFixed {
                result[index] = clamp(user, width)
                continue
            }
            switch width {
            case .automatic: break
            case .fixed(let value): result[index] = value
            case .flexible(let min, let ideal, _): result[index] = ideal ?? min
            }
        }
        let taken = result.compactMap { $0 }.reduce(0, +)
        let open = result.indices.filter { result[$0] == nil }
        var left = total - taken
        if !open.isEmpty {
            let share = max(0, left) / Double(open.count)
            for index in open {
                result[index] = clamp(share, widths[index])
            }
            left = total - result.compactMap { $0 }.reduce(0, +)
        }
        var final = result.map { $0 ?? 0 }
        // What is left over widens the last column that can take it.
        if left > 0.5, let last = final.indices.last(where: { !widths[$0].isFixed && final[$0] < widths[$0].maximum }) {
            final[last] = min(final[last] + left, widths[last].maximum)
        }
        // Too wide: the columns that can give take the difference, each in
        // proportion to how far it is above its minimum — a dragged or
        // fixed width is left as it is.
        if left < -0.5 {
            let shrinkable = final.indices.filter { !widths[$0].isFixed && userWidths[$0] == nil }
            let slack = shrinkable.reduce(0) { $0 + max(0, final[$1] - widths[$1].minimum) }
            if slack > 0 {
                let fraction = min(1, -left / slack)
                for index in shrinkable {
                    final[index] -= max(0, final[index] - widths[index].minimum) * fraction
                }
            }
        }
        cached = (total, final)
        return final
    }

    /// Where each column starts, from the table's leading edge.
    func offsets(for total: Double) -> [Double] {
        var x = 0.0
        return widths(for: total).map { width in
            defer { x += width }
            return x
        }
    }

    private func clamp(_ value: Double, _ width: TableColumnWidth) -> Double {
        min(max(value, width.minimum), width.maximum)
    }
}

/// How to build a row's cells, one closure per column, with the layout
/// they are placed by. Made fresh by every build of the table and compared
/// by identity: a row rebuilt within one build of the table keeps its
/// cells when its value is unchanged.
@MainActor
final class TableCells<Value> {
    let cells: [@MainActor (Value, [Int], inout BuildContext) -> ViewNode]
    let layout: TableColumnLayout

    init(cells: [@MainActor (Value, [Int], inout BuildContext) -> ViewNode], layout: TableColumnLayout) {
        self.cells = cells
        self.layout = layout
    }
}

// MARK: - Rows

struct TableRowEntry<Value: Identifiable>: Identifiable {
    let index: Int
    let value: Value

    var id: Value.ID { value.id }
}

/// One row: its cells in their columns, on its highlight when selected.
@View
struct _TableRow<Value: Identifiable> {
    let entry: TableRowEntry<Value>
    let cells: TableCells<Value>
    let look: TableLook
    let actions: ListActions<Value.ID>
    let isFocused: Bool

    @Environment(\.tint) private var tint

    var body: some View {
        let id = entry.value.id
        let actions = self.actions
        let isSelected = actions.selection.contains(id)
        let inverted = isSelected && isFocused
        let row = _TableRowCells(value: entry.value, cells: cells)
            .foregroundColor(inverted ? Color.white : Color.primary)
            .environment(\.backgroundProminence, inverted ? .increased : .standard)
            .background(ZStack {
                if look.alternates && entry.index % 2 == 1 {
                    Rectangle().fill(SelectionColors.alternate)
                }
                if isSelected {
                    RoundedRectangle(cornerRadius: look.selectionRadius)
                        .fill(isFocused ? tint : SelectionColors.unfocused)
                }
            })
            ._hitTarget(HitTarget(
                isEnabled: actions.isEnabled && actions.selection.isSelectable,
                onPress: { _ in actions.press(id) }
            ))
        if let menu = actions.menuItems(for: id) {
            row.contextMenu { menu }
        } else {
            row
        }
    }
}

/// A row's cells, built as nodes of their own so they can be placed in
/// the table's columns.
@View
struct _TableRowCells<Value: Identifiable> {
    let value: Value
    let cells: TableCells<Value>

    init(value: Value, cells: TableCells<Value>, _viewID: ViewID = #viewID) {
        self.value = value
        self.cells = cells
        self._viewID = _viewID
    }

    var body: Never { bodyUnavailable() }
}

extension _TableRowCells: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        var inner = context
        inner.stackAxis = nil
        // One line per cell, as in a table on the desktop.
        inner.environment.lineLimit = 1
        let owner = context.path
        let children = cells.cells.enumerated().map { index, cell in
            inner.child(index) { ctx in cell(value, owner, &ctx) }
        }
        return ViewNode(
            content: TableCellsContent(layout: cells.layout, verticalPadding: TableLook.rowPadding, minimumHeight: 22),
            children: children
        )
    }
}

/// Cells side by side in the table's columns, each inset by the cell
/// padding, centred in the row's height and clipped to its column.
struct TableCellsContent: NodeContent {
    let layout: TableColumnLayout
    let verticalPadding: Double
    let minimumHeight: Double

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        let total = proposal.width ?? layout.idealWidths.reduce(0, +)
        let widths = layout.widths(for: total)
        var height = minimumHeight
        for (index, child) in node.children.enumerated() where index < widths.count {
            let size = child.sizeThatFits(cellProposal(widths[index]))
            height = max(height, size.height + 2 * verticalPadding)
        }
        return Size(width: total, height: height)
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        let widths = layout.widths(for: rect.width)
        var x = rect.minX
        for (index, child) in node.children.enumerated() where index < widths.count {
            let width = widths[index]
            let cellProposal = cellProposal(width)
            let size = child.sizeThatFits(cellProposal)
            let cellWidth = min(size.width, max(0, width - 2 * layout.cellPadding))
            let column = Rect(x: x, y: rect.minY, width: width, height: rect.height)
            child.place(
                in: Rect(
                    x: x + layout.cellPadding,
                    y: rect.minY + (rect.height - size.height) / 2,
                    width: cellWidth,
                    height: size.height
                ),
                proposal: cellProposal,
                context: context.clipped(to: column),
                into: &list
            )
            x += width
        }
    }

    private func cellProposal(_ width: Double) -> ProposedSize {
        ProposedSize(width: max(0, width - 2 * layout.cellPadding), height: nil)
    }
}

// MARK: - Header

/// The row of column headers: each column's title, the sort arrow on the
/// column the order sorts by first, a rule between columns, and the edge
/// to drag for resizing.
@View
struct _TableHeader {
    let headers: [AnyView]
    let sorts: [TableColumnSort?]
    let sortState: TableSortState?
    let layout: TableColumnLayout
    let widths: Binding<[Int: Double]>
    let look: TableLook

    var body: some View {
        _TableHeaderCells(
            cells: headers.indices.map { index in
                AnyView(_TableHeaderCell(
                    index: index,
                    header: headers[index],
                    sort: sorts[index],
                    sortState: sortState,
                    layout: layout,
                    widths: widths,
                    isLast: index == headers.count - 1
                ))
            },
            layout: layout
        )
        .padding(.horizontal, look.horizontalInset)
        .background(Color.secondaryBackground)
    }
}

/// The header cells, placed in the columns like a row's cells.
@View
struct _TableHeaderCells {
    let cells: [AnyView]
    let layout: TableColumnLayout

    init(cells: [AnyView], layout: TableColumnLayout, _viewID: ViewID = #viewID) {
        self.cells = cells
        self.layout = layout
        self._viewID = _viewID
    }

    var body: Never { bodyUnavailable() }
}

extension _TableHeaderCells: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        var inner = context
        inner.stackAxis = nil
        let children = cells.enumerated().map { index, cell in
            inner.child(index) { buildNode(cell, &$0) }
        }
        return ViewNode(
            content: TableHeaderContent(layout: layout),
            children: children
        )
    }
}

/// Header cells fill their whole column — the title's padding is their
/// own, so the rule and the drag edge can sit on the column's edge.
struct TableHeaderContent: NodeContent {
    let layout: TableColumnLayout

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        let total = proposal.width ?? layout.idealWidths.reduce(0, +)
        let widths = layout.widths(for: total)
        var height = 0.0
        for (index, child) in node.children.enumerated() where index < widths.count {
            height = max(height, child.sizeThatFits(ProposedSize(width: widths[index], height: nil)).height)
        }
        return Size(width: total, height: height)
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        let widths = layout.widths(for: rect.width)
        var x = rect.minX
        for (index, child) in node.children.enumerated() where index < widths.count {
            let proposal = ProposedSize(width: widths[index], height: rect.height)
            child.place(
                in: Rect(x: x, y: rect.minY, width: widths[index], height: rect.height),
                proposal: proposal,
                context: context,
                into: &list
            )
            x += widths[index]
        }
    }
}

/// One column's header.
@View
struct _TableHeaderCell {
    let index: Int
    let header: AnyView
    let sort: TableColumnSort?
    let sortState: TableSortState?
    let layout: TableColumnLayout
    let widths: Binding<[Int: Double]>
    let isLast: Bool

    var body: some View {
        let sort = self.sort
        let sortState = self.sortState
        let direction = sortState.flatMap { state in sort?.direction(state) }
        HStack(spacing: 4) {
            header
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(direction == nil ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let direction {
                Text("›")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(direction == .forward ? -90 : 90))
            }
        }
        .padding(.horizontal, TableLook.cellPadding)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onTapGesture {
            if let sort, let sortState { sort.toggle(sortState) }
        }
        .overlay(alignment: .trailing) {
            if !isLast {
                _TableColumnEdge(index: index, layout: layout, widths: widths)
            }
        }
    }
}

/// The edge between two headers: a rule, and a strip either side of it
/// that resizes the column to its left when dragged.
@View
struct _TableColumnEdge {
    let index: Int
    let layout: TableColumnLayout
    let widths: Binding<[Int: Double]>

    @State private var dragStart: Double? = nil

    var body: some View {
        let index = self.index
        let layout = self.layout
        let widths = self.widths
        let start = $dragStart
        ZStack {
            Rectangle()
                .fill(Color.separator)
                .frame(width: 1)
                .padding(.vertical, 4)
        }
        .frame(width: 7)
        .frame(maxHeight: .infinity)
        .offset(x: 3)
        ._hitTarget(HitTarget(
            minimumDragDistance: 1,
            onDragChanged: { value in
                let from = start.wrappedValue ?? layout.lastWidth(of: index)
                if start.wrappedValue == nil { start.wrappedValue = from }
                widths.wrappedValue[index] = max(layout.widths[index].minimum, from + value.translation.width)
            },
            onDragEnded: { _ in start.wrappedValue = nil }
        ))
    }
}

extension TableColumnLayout {
    /// The width column `index` was last laid out at.
    func lastWidth(of index: Int) -> Double {
        guard let widths = lastWidths, index < widths.count else { return idealWidths[index] }
        return widths[index]
    }
}
