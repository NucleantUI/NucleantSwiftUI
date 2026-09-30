//
//  GridContent.swift
//  NucleantUI
//
//  The `Grid` layout: a table sized from its cells. A column is as wide as
//  the widest cell that sizes it, a row as tall as its tallest; cells that
//  grow with whatever they are offered (a `Color`) don't have a size to
//  give, so their columns and rows split what the others leave over. A
//  cell is "greedy" along an axis when offering it infinity there gets
//  back infinity — that is the whole test, so a `.frame(maxWidth:
//  .infinity)` counts and a `Text` doesn't.
//
//  A `GridRow` is placed as a node of its own, in its row's rect, and puts
//  its cells where the grid planned — so a row that is a render boundary,
//  or animates, stays one piece.
//

struct GridContent: NodeContent {
    let alignment: Alignment
    let horizontalSpacing: Double?
    let verticalSpacing: Double?

    static let defaultSpacing: Double = 8

    private var hSpacing: Double { horizontalSpacing ?? Self.defaultSpacing }
    private var vSpacing: Double { verticalSpacing ?? Self.defaultSpacing }

    /// As flexible as its most flexible row.
    func flexibility(along axis: Axis, node: ViewNode) -> LayoutPriorityClass {
        node.layoutChildren.map { $0.flexibility(along: axis) }.max() ?? .content
    }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        let rows = gridRows(of: node)
        guard !rows.isEmpty else { return .zero }
        let layout = self.layout(rows, proposal: proposal)
        return layout.size
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        let rows = gridRows(of: node)
        guard !rows.isEmpty else { return }
        let layout = self.layout(rows, proposal: ProposedSize(rect.size))
        // A grid smaller than its rect sits in it by its alignment.
        let origin = alignment.position(layout.size, in: rect).origin

        var y = origin.y
        for (rowIndex, row) in rows.enumerated() {
            let height = layout.heights[rowIndex]
            switch row.kind {
            case .spanning:
                // A lone view is a cell as wide as the grid.
                let cell = Rect(x: origin.x, y: y, width: layout.size.width, height: height)
                let cellProposal = ProposedSize(cell.size)
                let size = row.node.sizeThatFits(cellProposal)
                let traits = row.node.gridCellTraits
                let placed = position(size, in: cell, anchor: traits?.anchor, alignment: alignment)
                row.node.place(in: placed, proposal: cellProposal, context: context, into: &list)

            case .cells(let cells, let rowContent, let rowAlignment):
                // The row node takes the row's rect; its cells go where
                // the plan says, relative to it.
                let rowRect = Rect(x: origin.x, y: y, width: layout.size.width, height: height)
                var placements: [ObjectIdentifier: GridRowPlan.Placement] = [:]
                for cell in cells {
                    let x = layout.columnOffsets[cell.column]
                    let width = layout.spannedWidth(from: cell.column, span: cell.span, spacing: hSpacing)
                    let frame = Rect(x: x, y: 0, width: width, height: height)
                    let cellProposal = ProposedSize(frame.size)
                    let size = cell.node.sizeThatFits(cellProposal)
                    let cellAlignment = Alignment(
                        horizontal: layout.columnAlignments[cell.column] ?? alignment.horizontal,
                        vertical: rowAlignment ?? alignment.vertical
                    )
                    placements[ObjectIdentifier(cell.node)] = GridRowPlan.Placement(
                        rect: position(size, in: frame, anchor: cell.traits.anchor, alignment: cellAlignment),
                        proposal: cellProposal
                    )
                }
                rowContent.plan.placements = placements
                row.node.place(in: rowRect, proposal: ProposedSize(rowRect.size), context: context, into: &list)
            }
            y += height + vSpacing
        }
    }

    /// Where a `size`-sized view goes in `cell`: by its anchor if it has
    /// one — its point at `anchor` on the cell's — else by `alignment`.
    private func position(_ size: Size, in cell: Rect, anchor: UnitPoint?, alignment: Alignment) -> Rect {
        guard let anchor else { return alignment.position(size, in: cell) }
        let point = anchor.resolved(in: cell)
        return Rect(
            x: point.x - size.width * anchor.x,
            y: point.y - size.height * anchor.y,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Reading the rows

    struct Cell {
        let node: ViewNode
        let column: Int
        let span: Int
        let traits: GridCellTraits
    }

    struct Row {
        enum Kind {
            /// A view that isn't a `GridRow`: one cell across every column.
            case spanning
            /// A `GridRow`'s cells, with its content (for the plan) and
            /// its vertical alignment.
            case cells([Cell], GridRowContent, VerticalAlignment?)
        }
        /// The node the grid places — the row as it stands in the tree.
        let node: ViewNode
        let kind: Kind
    }

    private func gridRows(of node: ViewNode) -> [Row] {
        node.layoutChildren.map { child in
            guard let (rowNode, content) = Self.gridRow(in: child) else {
                return Row(node: child, kind: .spanning)
            }
            var column = 0
            let cells = rowNode.layoutChildren.map { cell -> Cell in
                let traits = cell.gridCellTraits ?? GridCellTraits()
                let span = max(1, traits.columns ?? 1)
                defer { column += span }
                return Cell(node: cell, column: column, span: span, traits: traits)
            }
            return Row(node: child, kind: .cells(cells, content, content.alignment))
        }
    }

    /// The `GridRow` a row node is — directly, or under the render node a
    /// stateful view wrapping it draws into.
    private static func gridRow(in node: ViewNode) -> (ViewNode, GridRowContent)? {
        if let content = node.content as? GridRowContent { return (node, content) }
        if node.content is RenderBoundaryContent, let child = node.singleChild {
            return gridRow(in: child)
        }
        return nil
    }

    // MARK: - Sizing

    struct Layout {
        var widths: [Double] = []
        var columnOffsets: [Double] = []
        var columnAlignments: [HorizontalAlignment?] = []
        var heights: [Double] = []
        var size: Size = .zero

        func spannedWidth(from column: Int, span: Int, spacing: Double) -> Double {
            let end = min(column + span, widths.count)
            guard column < end else { return 0 }
            return widths[column..<end].reduce(0, +) + spacing * Double(end - column - 1)
        }
    }

    /// Anything past this came back from an infinite offer unchanged.
    private static let greedyThreshold = 1e9

    private func layout(_ rows: [Row], proposal: ProposedSize) -> Layout {
        var layout = Layout()

        // Columns: as many as the widest row has.
        var columnCount = 0
        for row in rows {
            if case .cells(let cells, _, _) = row.kind, let last = cells.last {
                columnCount = max(columnCount, last.column + last.span)
            }
        }
        layout.columnAlignments = Array(repeating: nil, count: columnCount)
        for row in rows {
            guard case .cells(let cells, _, _) = row.kind else { continue }
            for cell in cells where cell.column < columnCount {
                if let guide = cell.traits.columnAlignment {
                    layout.columnAlignments[cell.column] = guide
                }
            }
        }

        // Each column's width from its single-column cells that size it.
        var ideals = Array(repeating: 0.0, count: columnCount)
        var greedyColumns = Array(repeating: false, count: columnCount)
        var fillsWidth = false
        for row in rows {
            switch row.kind {
            case .spanning:
                if !(row.node.gridCellTraits?.unsizedAxes?.contains(.horizontal) ?? false),
                   row.node.sizeThatFits(ProposedSize(width: .infinity, height: nil)).width >= Self.greedyThreshold {
                    fillsWidth = true
                }
            case .cells(let cells, _, _):
                for cell in cells {
                    if cell.traits.unsizedAxes?.contains(.horizontal) ?? false { continue }
                    let greedy = cell.node.sizeThatFits(ProposedSize(width: .infinity, height: nil)).width >= Self.greedyThreshold
                    guard cell.span == 1 else {
                        if greedy { fillsWidth = true }
                        continue
                    }
                    if greedy { greedyColumns[cell.column] = true }
                    ideals[cell.column] = max(ideals[cell.column], cell.node.sizeThatFits(.unspecified).width)
                }
            }
        }

        // A cell across several columns that is wider than they are widens
        // each of them by an equal part of the difference — narrowest spans
        // first, so a wide one sees what the narrow ones already added.
        var spanning: [Cell] = []
        for row in rows {
            guard case .cells(let cells, _, _) = row.kind else { continue }
            spanning += cells.filter { $0.span > 1 && !($0.traits.unsizedAxes?.contains(.horizontal) ?? false) }
        }
        for cell in spanning.sorted(by: { $0.span < $1.span }) {
            let end = min(cell.column + cell.span, columnCount)
            guard cell.column < end else { continue }
            let ideal = cell.node.sizeThatFits(.unspecified).width
            let covered = ideals[cell.column..<end].reduce(0, +) + hSpacing * Double(end - cell.column - 1)
            guard ideal > covered, ideal < Self.greedyThreshold else { continue }
            let share = (ideal - covered) / Double(end - cell.column)
            for index in cell.column..<end { ideals[index] += share }
        }

        var widths = ideals
        let columnSpacing = hSpacing * Double(max(columnCount - 1, 0))
        let natural = widths.reduce(0, +) + columnSpacing
        if let available = proposal.width, available.isFinite, columnCount > 0 {
            let extra = available - natural
            let greedy = greedyColumns.indices.filter { greedyColumns[$0] }
            if extra > 0, !greedy.isEmpty {
                // Greedy columns split what the others leave.
                for index in greedy { widths[index] += extra / Double(greedy.count) }
            } else if extra > 0, fillsWidth {
                // A full-width divider widens the grid; every column shares it.
                for index in widths.indices { widths[index] += extra / Double(columnCount) }
            } else if extra < 0 {
                // Too wide: each column gives up in proportion to its width,
                // and its text wraps.
                let total = widths.reduce(0, +)
                if total > 0 {
                    let scale = max(0, (available - columnSpacing) / total)
                    for index in widths.indices { widths[index] *= scale }
                }
            }
        }
        layout.widths = widths
        var offset = 0.0
        layout.columnOffsets = widths.map { width in
            defer { offset += width + hSpacing }
            return offset
        }
        var gridWidth = widths.reduce(0, +) + columnSpacing
        if columnCount == 0 {
            // Only lone views: as wide as the widest of them.
            gridWidth = rows.reduce(0) { widest, row in
                max(widest, row.node.sizeThatFits(ProposedSize(width: proposal.width, height: nil)).width)
            }
        } else if fillsWidth, let available = proposal.width, available.isFinite {
            gridWidth = max(gridWidth, available)
        }

        // Rows: each as tall as its tallest cell that sizes it, now that
        // the widths are known; greedy rows split the height left over.
        var heights = Array(repeating: 0.0, count: rows.count)
        var greedyRows = Array(repeating: false, count: rows.count)
        for (index, row) in rows.enumerated() {
            switch row.kind {
            case .spanning:
                if row.node.gridCellTraits?.unsizedAxes?.contains(.vertical) ?? false { continue }
                let (height, greedy) = measureHeight(row.node, width: gridWidth)
                heights[index] = height
                greedyRows[index] = greedy
            case .cells(let cells, _, _):
                for cell in cells {
                    if cell.traits.unsizedAxes?.contains(.vertical) ?? false { continue }
                    let width = layout.spannedWidth(from: cell.column, span: cell.span, spacing: hSpacing)
                    let (height, greedy) = measureHeight(cell.node, width: width)
                    heights[index] = max(heights[index], height)
                    if greedy { greedyRows[index] = true }
                }
            }
        }
        let rowSpacing = vSpacing * Double(max(rows.count - 1, 0))
        if let available = proposal.height, available.isFinite {
            let extra = available - heights.reduce(0, +) - rowSpacing
            let greedy = greedyRows.indices.filter { greedyRows[$0] }
            if extra > 0, !greedy.isEmpty {
                for index in greedy { heights[index] += extra / Double(greedy.count) }
            }
        }
        layout.heights = heights
        layout.size = Size(width: gridWidth, height: heights.reduce(0, +) + rowSpacing)
        return layout
    }

    /// A view's height at `width`, and whether it would take any height
    /// it were offered.
    private func measureHeight(_ node: ViewNode, width: Double) -> (Double, Bool) {
        let greedy = node.sizeThatFits(ProposedSize(width: width, height: .infinity)).height >= Self.greedyThreshold
        return (node.sizeThatFits(ProposedSize(width: width, height: nil)).height, greedy)
    }
}

/// Where the grid put a row's cells this pass, relative to the row.
@MainActor
final class GridRowPlan {
    struct Placement {
        let rect: Rect
        let proposal: ProposedSize
    }
    var placements: [ObjectIdentifier: Placement] = [:]
}

/// A `GridRow`'s node. In a grid it puts its cells where the grid planned;
/// anywhere else it is an `HStack`.
struct GridRowContent: NodeContent {
    let alignment: VerticalAlignment?
    let plan = GridRowPlan()

    private var asStack: StackContent {
        StackContent(axis: .horizontal, spacing: nil, horizontalAlignment: .leading, verticalAlignment: alignment ?? .center)
    }

    func flexibility(along axis: Axis, node: ViewNode) -> LayoutPriorityClass {
        asStack.flexibility(along: axis, node: node)
    }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        asStack.sizeThatFits(proposal, node: node)
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard !plan.placements.isEmpty else {
            asStack.place(node: node, in: rect, proposal: proposal, context: context, into: &list)
            return
        }
        for cell in node.layoutChildren {
            guard let placement = plan.placements[ObjectIdentifier(cell)] else { continue }
            cell.place(
                in: placement.rect.offsetBy(dx: rect.minX, dy: rect.minY),
                proposal: placement.proposal,
                context: context,
                into: &list
            )
        }
    }
}
