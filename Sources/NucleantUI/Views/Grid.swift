//
//  Grid.swift
//  NucleantUI
//

/// Arranges views in rows and columns, every cell of a column as wide as
/// its widest and every cell of a row as tall as its tallest.
///
/// ```swift
/// Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
///     GridRow {
///         Text("Kind:").gridColumnAlignment(.trailing)
///         Text(file.kind)
///     }
///     GridRow {
///         Text("Size:")
///         Text(file.size)
///     }
///     Divider().gridCellUnsizedAxes(.horizontal)
///     GridRow {
///         Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
///         Toggle("Locked", isOn: $file.isLocked)
///     }
/// }
/// ```
///
/// Each `GridRow` is a row and each of its views a cell; any other view is
/// a row of one cell spanning every column. The grid has as many columns as
/// its widest row. Cells that take whatever they are offered (a `Color`, a
/// `Spacer`) share the width or height left over by the rest; one marked
/// `.gridCellUnsizedAxes` takes part in neither, and is offered the size
/// the others made.
///
/// Every cell is built and measured up front — which is what lets a column
/// size to its widest cell. For thousands of cells in a scroll view, use a
/// `LazyVGrid`.
@View
public struct Grid<Content: View>: View {
    public let alignment: Alignment
    public let horizontalSpacing: Double?
    public let verticalSpacing: Double?
    public let content: Content

    public init(
        alignment: Alignment = .center,
        horizontalSpacing: Double? = nil,
        verticalSpacing: Double? = nil,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.content = content()
        self._viewID = _viewID
    }

    public var body: Never { bodyUnavailable() }
}

extension Grid: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        // A view that isn't a row is a row of its own, stacked with the
        // others: a `Divider` there is a horizontal rule.
        var inner = context
        inner.stackAxis = .vertical
        let child = inner.child(0) { ctx in buildNode(content, &ctx) }
        return ViewNode(
            content: GridContent(
                alignment: alignment,
                horizontalSpacing: horizontalSpacing,
                verticalSpacing: verticalSpacing
            ),
            children: [child]
        )
    }
}

/// One row of a `Grid`: each of its views is a cell, in column order.
///
/// `alignment` overrides the grid's vertical alignment for this row's
/// cells. Outside a `Grid` a row lays its cells out as an `HStack` would.
/// A modifier applied to a row applies to the row as a whole — it is then a
/// row of one full-width cell — so modify the cells instead.
@View
public struct GridRow<Content: View>: View {
    public let alignment: VerticalAlignment?
    public let content: Content

    public init(
        alignment: VerticalAlignment? = nil,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.content = content()
        self._viewID = _viewID
    }

    public var body: Never { bodyUnavailable() }
}

extension GridRow: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        // Across a row: a `Divider` in one is a vertical rule.
        var inner = context
        inner.stackAxis = .horizontal
        let child = inner.child(0) { ctx in buildNode(content, &ctx) }
        return ViewNode(content: GridRowContent(alignment: alignment), children: [child])
    }
}

// MARK: - Cell modifiers

/// What a view said about the grid cell it is: set by the `grid…`
/// modifiers, read by `Grid` (and ignored everywhere else).
struct GridCellTraits: Equatable {
    var columns: Int?
    var anchor: UnitPoint?
    var columnAlignment: HorizontalAlignment?
    var unsizedAxes: Axis.Set?

    /// These, with whatever `inner` said that these don't.
    func merged(over inner: GridCellTraits?) -> GridCellTraits {
        guard let inner else { return self }
        return GridCellTraits(
            columns: columns ?? inner.columns,
            anchor: anchor ?? inner.anchor,
            columnAlignment: columnAlignment ?? inner.columnAlignment,
            unsizedAxes: unsizedAxes ?? inner.unsizedAxes
        )
    }
}

/// A view with grid-cell traits: its own node, marked. A group's traits go
/// on each view in it, since each is a cell.
@View
struct _GridCellModifier<Content: View>: View {
    let content: Content
    let traits: GridCellTraits

    var body: Never { bodyUnavailable() }
}

extension _GridCellModifier: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let node = context.child(0) { ctx in buildNode(content, &ctx) }
        mark(node)
        return node
    }

    private func mark(_ node: ViewNode) {
        if node.content.isTransparent {
            for child in node.layoutChildren { mark(child) }
        } else {
            node.gridCellTraits = traits.merged(over: node.gridCellTraits)
        }
    }
}

extension View {
    /// Makes this cell of a `GridRow` span `count` columns.
    public func gridCellColumns(_ count: Int) -> some View {
        _GridCellModifier(content: self, traits: GridCellTraits(columns: max(1, count)))
    }

    /// Positions this cell's content in its cell by `anchor` — the point of
    /// the view at `anchor` sits on the point of the cell at `anchor` —
    /// instead of by the grid's and row's alignment.
    public func gridCellAnchor(_ anchor: UnitPoint) -> some View {
        _GridCellModifier(content: self, traits: GridCellTraits(anchor: anchor))
    }

    /// Aligns every cell in this cell's column horizontally by `guide`.
    /// Put it on one cell of the column.
    public func gridColumnAlignment(_ guide: HorizontalAlignment) -> some View {
        _GridCellModifier(content: self, traits: GridCellTraits(columnAlignment: guide))
    }

    /// Keeps this cell from sizing its column (`.horizontal`) or its row
    /// (`.vertical`): a flexible view — a `Divider`, a `Color` — then takes
    /// the size the other cells made, rather than widening the grid to
    /// everything it is offered.
    public func gridCellUnsizedAxes(_ axes: Axis.Set) -> some View {
        _GridCellModifier(content: self, traits: GridCellTraits(unsizedAxes: axes))
    }
}
