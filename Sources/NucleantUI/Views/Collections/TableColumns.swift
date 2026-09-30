//
//  TableColumns.swift
//  NucleantUI
//
//  A table's columns and rows as values: `TableColumn` and the
//  `TableColumnBuilder` that collects them, `TableRow` and the
//  `TableRowBuilder`. None of them are views — the table reads each column
//  once per build as a `TableColumnSpec`, and builds its cells from that.
//

import Foundation

// MARK: - Column content

/// A value that stands for one or more columns of a table.
@MainActor
public protocol TableColumnContent {
    /// The type of the rows the columns show.
    associatedtype TableRowValue: Identifiable = TableColumnBody.TableRowValue
    /// The comparator a column sorts by; `Never` for columns that don't.
    associatedtype TableColumnSortComparator: SortComparator = TableColumnBody.TableColumnSortComparator
    associatedtype TableColumnBody: TableColumnContent

    /// Columns made of other columns.
    var tableColumnBody: TableColumnBody { get }

    /// Add the columns this stands for, in order.
    func _tableColumns(into specs: inout [TableColumnSpec<TableRowValue>])
}

extension TableColumnContent where TableColumnBody.TableRowValue == TableRowValue {
    public func _tableColumns(into specs: inout [TableColumnSpec<TableRowValue>]) {
        tableColumnBody._tableColumns(into: &specs)
    }
}

extension Never {
    public typealias TableRowValue = Never
}

extension Never: TableColumnContent {
    public typealias TableColumnSortComparator = Never
    public typealias TableColumnBody = Never

    public var tableColumnBody: Never { fatalError("Never has no columns") }

    public func _tableColumns(into specs: inout [TableColumnSpec<Never>]) {}
}

/// One column as the table works with it: its header, width, sorting, and
/// how to build its cell for a row.
public struct TableColumnSpec<RowValue> {
    let header: AnyView
    let width: TableColumnWidth
    let sort: TableColumnSort?
    /// Build the cell for `row`. `owner` is the path of the view building
    /// the whole row, whose reads of the row's values these are.
    let cell: @MainActor (_ row: RowValue, _ owner: [Int], _ context: inout BuildContext) -> ViewNode
}

/// A column's sorting, typed away: what a click on its header does to the
/// table's sort order, and which way the order has it.
@MainActor
struct TableColumnSort {
    let toggle: @MainActor (TableSortState) -> Void
    let direction: @MainActor (TableSortState) -> SortOrder?
}

/// How wide a column is.
enum TableColumnWidth: Hashable {
    /// A share of what the fixed and ideal widths leave.
    case automatic
    case fixed(Double)
    case flexible(min: Double?, ideal: Double?, max: Double?)

    var minimum: Double {
        switch self {
        case .automatic: return 40
        case .fixed(let width): return width
        case .flexible(let min, _, _): return min ?? 40
        }
    }

    var maximum: Double {
        switch self {
        case .automatic: return .infinity
        case .fixed(let width): return width
        case .flexible(_, _, let max): return max ?? .infinity
        }
    }

    var isFixed: Bool {
        if case .fixed = self { return true }
        return false
    }
}

/// One column: a header, and a cell per row.
///
/// ```swift
/// TableColumn("Title", value: \.title)             // text, sortable
/// TableColumn("Points", value: \.points) { issue in
///     Text("\(issue.points)")
/// }
/// .width(60)
/// TableColumn("Assignee") { issue in              // not sortable
///     AvatarLabel(issue.assignee)
/// }
/// ```
public struct TableColumn<RowValue: Identifiable, Sort: SortComparator, Content: View, Label: View>: TableColumnContent {
    public typealias TableRowValue = RowValue
    public typealias TableColumnSortComparator = Sort
    public typealias TableColumnBody = Never

    let label: Label
    let content: (RowValue) -> Content
    let comparator: Sort?
    var width = TableColumnWidth.automatic

    init(label: Label, comparator: Sort?, content: @escaping (RowValue) -> Content) {
        self.label = label
        self.comparator = comparator
        self.content = content
    }

    public var tableColumnBody: Never { fatalError("TableColumn is a primitive column") }

    public func _tableColumns(into specs: inout [TableColumnSpec<RowValue>]) {
        let content = self.content
        specs.append(TableColumnSpec(
            header: AnyView(label),
            width: width,
            sort: comparator.map { comparator in
                TableColumnSort(
                    toggle: { $0.toggle(comparator) },
                    direction: { $0.direction(of: comparator) }
                )
            },
            cell: { row, owner, context in
                // The cell's reads of an `@Observable` row belong to the
                // whole row's view: rebuilding from there runs this again.
                let view = trackingObservation(at: owner) { content(row) }
                return buildNode(view, &context)
            }
        ))
    }

    /// A fixed width — or, with `nil`, the width the table gives it.
    public func width(_ width: Double? = nil) -> TableColumn {
        var copy = self
        copy.width = width.map { .fixed($0) } ?? .automatic
        return copy
    }

    /// A width the table keeps between `min` and `max`, starting at
    /// `ideal`. The user can drag it anywhere in that range.
    public func width(min: Double? = nil, ideal: Double? = nil, max: Double? = nil) -> TableColumn {
        var copy = self
        copy.width = .flexible(min: min, ideal: ideal, max: max)
        return copy
    }
}

extension TableColumn where Sort == Never, Label == Text {
    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(title), comparator: nil, content: content)
    }

    public init(_ text: Text, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: nil, content: content)
    }

    public init<S: StringProtocol>(_ title: S, value: KeyPath<RowValue, String>) where Content == Text {
        self.init(label: Text(title), comparator: nil) { Text($0[keyPath: value]) }
    }

    public init(_ text: Text, value: KeyPath<RowValue, String>) where Content == Text {
        self.init(label: text, comparator: nil) { Text($0[keyPath: value]) }
    }
}

extension TableColumn where RowValue == Sort.Compared, Label == Text {
    /// A column sorted by `comparator` when its header is clicked.
    public init<S: StringProtocol>(_ title: S, sortUsing comparator: Sort, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: Text(title), comparator: comparator, content: content)
    }

    public init(_ text: Text, sortUsing comparator: Sort, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: comparator, content: content)
    }
}

extension TableColumn where Sort == KeyPathComparator<RowValue>, Label == Text {
    /// A column sorted by `value` when its header is clicked.
    public init<S: StringProtocol, V: Comparable>(
        _ title: S,
        value: KeyPath<RowValue, V> & Sendable,
        @ViewBuilder content: @escaping (RowValue) -> Content
    ) {
        self.init(label: Text(title), comparator: KeyPathComparator(value), content: content)
    }

    public init<V: Comparable>(_ text: Text, value: KeyPath<RowValue, V> & Sendable, @ViewBuilder content: @escaping (RowValue) -> Content) {
        self.init(label: text, comparator: KeyPathComparator(value), content: content)
    }

    public init<S: StringProtocol, V, C: SortComparator>(
        _ title: S,
        value: KeyPath<RowValue, V> & Sendable,
        comparator: C,
        @ViewBuilder content: @escaping (RowValue) -> Content
    ) where V == C.Compared {
        self.init(label: Text(title), comparator: KeyPathComparator(value, comparator: comparator), content: content)
    }

    public init<V, C: SortComparator>(
        _ text: Text,
        value: KeyPath<RowValue, V> & Sendable,
        comparator: C,
        @ViewBuilder content: @escaping (RowValue) -> Content
    ) where V == C.Compared {
        self.init(label: text, comparator: KeyPathComparator(value, comparator: comparator), content: content)
    }

    /// A text column sorted by its text, the way Finder sorts names.
    public init<S: StringProtocol>(
        _ title: S,
        value: KeyPath<RowValue, String> & Sendable,
        comparator: String.StandardComparator = .localizedStandard
    ) where Content == Text {
        self.init(label: Text(title), comparator: KeyPathComparator(value, comparator: comparator)) {
            Text($0[keyPath: value])
        }
    }

    public init(
        _ text: Text,
        value: KeyPath<RowValue, String> & Sendable,
        comparator: String.StandardComparator = .localizedStandard
    ) where Content == Text {
        self.init(label: text, comparator: KeyPathComparator(value, comparator: comparator)) {
            Text($0[keyPath: value])
        }
    }
}

// MARK: - Column builder

/// Collects the columns of a table.
@resultBuilder @MainActor
public struct TableColumnBuilder<RowValue: Identifiable, Sort: SortComparator> {

    public static func buildExpression<Content: View, Label: View>(
        _ column: TableColumn<RowValue, Sort, Content, Label>
    ) -> TableColumn<RowValue, Sort, Content, Label> {
        column
    }

    @_disfavoredOverload
    public static func buildExpression<Content: View, Label: View>(
        _ column: TableColumn<RowValue, Never, Content, Label>
    ) -> TableColumn<RowValue, Never, Content, Label> {
        column
    }

    public static func buildExpression<Column: TableColumnContent>(_ column: Column) -> Column
    where Column.TableRowValue == RowValue, Column.TableColumnSortComparator == Sort {
        column
    }

    @_disfavoredOverload
    public static func buildExpression<Column: TableColumnContent>(_ column: Column) -> Column
    where Column.TableRowValue == RowValue, Column.TableColumnSortComparator == Never {
        column
    }

    public static func buildPartialBlock<Column: TableColumnContent>(first column: Column) -> Column
    where Column.TableRowValue == RowValue {
        column
    }

    public static func buildPartialBlock<Accumulated: TableColumnContent, Next: TableColumnContent>(
        accumulated: Accumulated,
        next: Next
    ) -> TupleTableColumnContent<Sort, Accumulated, Next>
    where Accumulated.TableRowValue == RowValue, Next.TableRowValue == RowValue {
        TupleTableColumnContent(first: accumulated, second: next)
    }

    public static func buildIf<Column: TableColumnContent>(_ column: Column?) -> _OptionalTableColumnContent<Column>
    where Column.TableRowValue == RowValue {
        _OptionalTableColumnContent(wrapped: column)
    }

    public static func buildEither<T: TableColumnContent, F: TableColumnContent>(
        first: T
    ) -> _ConditionalTableColumnContent<T, F> where T.TableRowValue == RowValue, F.TableRowValue == RowValue {
        _ConditionalTableColumnContent(storage: .first(first))
    }

    public static func buildEither<T: TableColumnContent, F: TableColumnContent>(
        second: F
    ) -> _ConditionalTableColumnContent<T, F> where T.TableRowValue == RowValue, F.TableRowValue == RowValue {
        _ConditionalTableColumnContent(storage: .second(second))
    }
}

/// The columns of one builder block, two at a time: those before the
/// last, and the last.
public struct TupleTableColumnContent<Sort: SortComparator, First: TableColumnContent, Second: TableColumnContent>: TableColumnContent
where First.TableRowValue == Second.TableRowValue {
    public typealias TableRowValue = First.TableRowValue
    public typealias TableColumnSortComparator = Sort
    public typealias TableColumnBody = Never

    let first: First
    let second: Second

    public var tableColumnBody: Never { fatalError("TupleTableColumnContent is a primitive column") }

    public func _tableColumns(into specs: inout [TableColumnSpec<First.TableRowValue>]) {
        first._tableColumns(into: &specs)
        second._tableColumns(into: &specs)
    }
}

/// A column under an `if` without an `else`.
public struct _OptionalTableColumnContent<Wrapped: TableColumnContent>: TableColumnContent {
    public typealias TableRowValue = Wrapped.TableRowValue
    public typealias TableColumnSortComparator = Wrapped.TableColumnSortComparator
    public typealias TableColumnBody = Never

    let wrapped: Wrapped?

    public var tableColumnBody: Never { fatalError("_OptionalTableColumnContent is a primitive column") }

    public func _tableColumns(into specs: inout [TableColumnSpec<Wrapped.TableRowValue>]) {
        wrapped?._tableColumns(into: &specs)
    }
}

/// One of the two branches of an `if`/`else` among columns.
public struct _ConditionalTableColumnContent<T: TableColumnContent, F: TableColumnContent>: TableColumnContent
where T.TableRowValue == F.TableRowValue {
    public typealias TableRowValue = T.TableRowValue
    public typealias TableColumnSortComparator = T.TableColumnSortComparator
    public typealias TableColumnBody = Never

    enum Storage {
        case first(T)
        case second(F)
    }

    let storage: Storage

    public var tableColumnBody: Never { fatalError("_ConditionalTableColumnContent is a primitive column") }

    public func _tableColumns(into specs: inout [TableColumnSpec<T.TableRowValue>]) {
        switch storage {
        case .first(let column): column._tableColumns(into: &specs)
        case .second(let column): column._tableColumns(into: &specs)
        }
    }
}

// MARK: - Row content

/// A value that stands for rows of a table.
@MainActor
public protocol TableRowContent {
    associatedtype TableRowValue: Identifiable = TableRowBody.TableRowValue
    associatedtype TableRowBody: TableRowContent

    /// Rows made of other rows.
    var tableRowBody: TableRowBody { get }

    /// Add the values of the rows this stands for, in order.
    func _tableRows(into rows: inout [TableRowValue])
}

extension TableRowContent where TableRowBody.TableRowValue == TableRowValue {
    public func _tableRows(into rows: inout [TableRowValue]) {
        tableRowBody._tableRows(into: &rows)
    }
}

extension Never: TableRowContent {
    public typealias TableRowBody = Never

    public var tableRowBody: Never { fatalError("Never has no rows") }

    public func _tableRows(into rows: inout [Never]) {}
}

/// One row of a table, for one value.
public struct TableRow<Value: Identifiable>: TableRowContent {
    public typealias TableRowValue = Value
    public typealias TableRowBody = Never

    let value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public var tableRowBody: Never { fatalError("TableRow is a primitive row") }

    public func _tableRows(into rows: inout [Value]) {
        rows.append(value)
    }
}

/// A row per element of a collection — what `Table(_:columns:)` shows.
public struct TableForEachContent<Data: RandomAccessCollection>: TableRowContent where Data.Element: Identifiable {
    public typealias TableRowValue = Data.Element
    public typealias TableRowBody = Never

    let data: Data

    public var tableRowBody: Never { fatalError("TableForEachContent is a primitive row") }

    public func _tableRows(into rows: inout [Data.Element]) {
        rows.append(contentsOf: data)
    }
}

/// Collects the rows of a table.
@resultBuilder @MainActor
public struct TableRowBuilder<Value: Identifiable> {

    public static func buildExpression<Content: TableRowContent>(_ content: Content) -> Content
    where Content.TableRowValue == Value {
        content
    }

    public static func buildPartialBlock<Content: TableRowContent>(first content: Content) -> Content
    where Content.TableRowValue == Value {
        content
    }

    public static func buildPartialBlock<Accumulated: TableRowContent, Next: TableRowContent>(
        accumulated: Accumulated,
        next: Next
    ) -> TupleTableRowContent<Accumulated, Next>
    where Accumulated.TableRowValue == Value, Next.TableRowValue == Value {
        TupleTableRowContent(first: accumulated, second: next)
    }

    public static func buildIf<Content: TableRowContent>(_ content: Content?) -> _OptionalTableRowContent<Content>
    where Content.TableRowValue == Value {
        _OptionalTableRowContent(wrapped: content)
    }

    public static func buildEither<T: TableRowContent, F: TableRowContent>(
        first: T
    ) -> _ConditionalTableRowContent<T, F> where T.TableRowValue == Value, F.TableRowValue == Value {
        _ConditionalTableRowContent(storage: .first(first))
    }

    public static func buildEither<T: TableRowContent, F: TableRowContent>(
        second: F
    ) -> _ConditionalTableRowContent<T, F> where T.TableRowValue == Value, F.TableRowValue == Value {
        _ConditionalTableRowContent(storage: .second(second))
    }

    /// A `for` loop over rows.
    public static func buildArray<Content: TableRowContent>(_ content: [Content]) -> _TableRowArray<Content>
    where Content.TableRowValue == Value {
        _TableRowArray(elements: content)
    }
}

/// The rows of one builder block, two at a time.
public struct TupleTableRowContent<First: TableRowContent, Second: TableRowContent>: TableRowContent
where First.TableRowValue == Second.TableRowValue {
    public typealias TableRowValue = First.TableRowValue
    public typealias TableRowBody = Never

    let first: First
    let second: Second

    public var tableRowBody: Never { fatalError("TupleTableRowContent is a primitive row") }

    public func _tableRows(into rows: inout [First.TableRowValue]) {
        first._tableRows(into: &rows)
        second._tableRows(into: &rows)
    }
}

/// Rows under an `if` without an `else`.
public struct _OptionalTableRowContent<Wrapped: TableRowContent>: TableRowContent {
    public typealias TableRowValue = Wrapped.TableRowValue
    public typealias TableRowBody = Never

    let wrapped: Wrapped?

    public var tableRowBody: Never { fatalError("_OptionalTableRowContent is a primitive row") }

    public func _tableRows(into rows: inout [Wrapped.TableRowValue]) {
        wrapped?._tableRows(into: &rows)
    }
}

/// One of the two branches of an `if`/`else` among rows.
public struct _ConditionalTableRowContent<T: TableRowContent, F: TableRowContent>: TableRowContent
where T.TableRowValue == F.TableRowValue {
    public typealias TableRowValue = T.TableRowValue
    public typealias TableRowBody = Never

    enum Storage {
        case first(T)
        case second(F)
    }

    let storage: Storage

    public var tableRowBody: Never { fatalError("_ConditionalTableRowContent is a primitive row") }

    public func _tableRows(into rows: inout [T.TableRowValue]) {
        switch storage {
        case .first(let content): content._tableRows(into: &rows)
        case .second(let content): content._tableRows(into: &rows)
        }
    }
}

/// The rows of a `for` loop.
public struct _TableRowArray<Content: TableRowContent>: TableRowContent {
    public typealias TableRowValue = Content.TableRowValue
    public typealias TableRowBody = Never

    let elements: [Content]

    public var tableRowBody: Never { fatalError("_TableRowArray is a primitive row") }

    public func _tableRows(into rows: inout [Content.TableRowValue]) {
        for element in elements {
            element._tableRows(into: &rows)
        }
    }
}

// MARK: - Sorting

/// A table's sort order, typed away so a column can change it without
/// knowing the table's comparator type.
@MainActor
class TableSortState {
    /// Make `comparator` the first key — or, when it already is, flip its
    /// order.
    func toggle<C: SortComparator>(_ comparator: C) {}

    /// Which way the order sorts by `comparator`, when it is the first key.
    func direction<C: SortComparator>(of comparator: C) -> SortOrder? { nil }

    /// Whether `other` edits the same sort order.
    func isEquivalent(to other: TableSortState) -> Bool { self === other }
}

final class TypedTableSortState<Sort: SortComparator>: TableSortState {
    let order: Binding<[Sort]>

    init(_ order: Binding<[Sort]>) {
        self.order = order
    }

    override func toggle<C: SortComparator>(_ comparator: C) {
        guard let comparator = comparator as? Sort else { return }
        var order = self.order.wrappedValue
        if let first = order.first, Self.sameKey(first, comparator) {
            order[0].order = first.order == .forward ? .reverse : .forward
        } else {
            order.removeAll { Self.sameKey($0, comparator) }
            order.insert(comparator, at: 0)
        }
        self.order.wrappedValue = order
    }

    override func direction<C: SortComparator>(of comparator: C) -> SortOrder? {
        guard let comparator = comparator as? Sort,
              let first = order.wrappedValue.first,
              Self.sameKey(first, comparator) else { return nil }
        return first.order
    }

    override func isEquivalent(to other: TableSortState) -> Bool {
        guard let other = other as? TypedTableSortState<Sort> else { return false }
        return order._isEquivalent(to: other.order)
    }

    /// Whether two comparators sort by the same thing, whichever way.
    private static func sameKey(_ a: Sort, _ b: Sort) -> Bool {
        var a = a
        var b = b
        a.order = .forward
        b.order = .forward
        return a == b
    }
}
