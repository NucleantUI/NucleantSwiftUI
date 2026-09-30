//
//  MultilineTextEditing.swift
//  NucleantUI
//
//  Editable text over several lines: what a `TextEditor` is, and what a
//  `TextField(_:text:axis: .vertical)` grows into. The text wraps at word
//  boundaries to the width it is given, the caret moves between lines, and
//  text taller than the view scrolls to keep the caret in view (and with
//  the wheel).
//

/// How a multi-line text area sizes itself and what Return and Tab do.
enum MultilineTextMode: Equatable {
    /// `TextEditor`: takes the space it is offered; Return breaks the line
    /// and Tab inserts a tab.
    case editor
    /// `TextField(axis: .vertical)`: as tall as its lines, kept between
    /// `minLines` and `maxLines` (none: no limit), scrolling past that;
    /// Return submits, ⌥Return or ⌃Return breaks the line, and Tab moves to
    /// the next field.
    case field(minLines: Int, maxLines: Int?)
}

/// The editing view itself: text, caret, selection, undo. Its owner draws
/// whatever goes around it.
@View
struct MultilineTextArea {
    @Binding var text: String
    let selection: TextSelectionSource
    let mode: MultilineTextMode
    /// Space between the area's edges and its text.
    let horizontalInset: Double
    let verticalInset: Double
    /// Told when the area gains or loses the keys, after it has noted it.
    let onFocusChange: @MainActor (Bool) -> Void
    /// Return in a `.field`.
    let onSubmit: @MainActor () -> Void

    @Environment(\.font) private var font
    @Environment(\.foregroundColor) private var foreground
    @Environment(\.tint) private var tint
    @Environment(\.isEnabled) private var isEnabled

    /// Caret, selection anchor and focus — the area's own transient state.
    @State private var editing = TextEditing()
    /// The lines as last placed, and the scroll offset. Written while the
    /// area is placed, so a reference the placement can reach.
    @State private var layout = TextAreaLayout()
    @State private var history = TextUndoHistory()
    @State private var clicks = TextClickCounter()
    /// Bumped by the wheel, so the area is placed again at its new offset.
    @State private var scrollTick = 0

    init(
        text: Binding<String>,
        selection: TextSelectionSource,
        mode: MultilineTextMode,
        horizontalInset: Double,
        verticalInset: Double,
        onFocusChange: @escaping @MainActor (Bool) -> Void = { _ in },
        onSubmit: @escaping @MainActor () -> Void = {},
        _viewID: ViewID = #viewID
    ) {
        self._text = text
        self.selection = selection
        self.mode = mode
        self.horizontalInset = horizontalInset
        self.verticalInset = verticalInset
        self.onFocusChange = onFocusChange
        self.onSubmit = onSubmit
        self._viewID = _viewID
    }

    var body: some View {
        let current = text
        let resolved = selection.resolve((editing.caret, editing.anchor), in: current)
        TextAreaLines(
            text: current,
            font: font,
            color: foreground,
            selectionColor: tint.opacity(editing.isFocused ? 0.3 : 0.15),
            caret: resolved.caret,
            anchor: resolved.anchor,
            showsCaret: editing.isFocused,
            mode: mode,
            horizontalInset: horizontalInset,
            verticalInset: verticalInset,
            layout: layout,
            scrollTick: scrollTick,
            isEnabled: isEnabled,
            editCommands: editCommands,
            onFocusChange: { focused in
                editing.isFocused = focused
                if !focused {
                    history.endCoalescing()
                    layout.goalX = nil
                }
                onFocusChange(focused)
            },
            onKeyDown: { key in handle(key) },
            onEditCommand: { command in perform(command) },
            onPress: { index, extending in press(at: index, extending: extending) },
            onDrag: { index in drag(to: index) },
            onScroll: { dy in
                if layout.scroll(by: dy) { scrollTick &+= 1 }
            }
        )
    }

    /// The editing commands the area takes: undo and redo only when there is
    /// something to undo or redo, so the Edit menu shows it.
    private var editCommands: Set<EditCommand> {
        var commands: Set<EditCommand> = [.cut, .copy, .paste, .selectAll]
        if history.canUndo { commands.insert(.undo) }
        if history.canRedo { commands.insert(.redo) }
        return commands
    }

    // MARK: - Selection

    private func currentSelection(in current: String) -> (caret: Int, anchor: Int) {
        selection.resolve((editing.caret, editing.anchor), in: current)
    }

    /// Show `caret`…`anchor` in `current`, and tell a bound selection.
    private func select(caret: Int, anchor: Int, in current: String) {
        if editing.caret != caret { editing.caret = caret }
        if editing.anchor != anchor { editing.anchor = anchor }
        selection.write(caret: caret, anchor: anchor, in: current)
    }

    /// Replace the text with `edited`, as one undoable step of `kind`.
    private func commit(_ edited: String, caret: Int, anchor: Int, kind: TextUndoHistory.Kind) {
        let current = text
        let before = currentSelection(in: current)
        history.record(
            TextSnapshot(text: current, caret: before.caret, anchor: before.anchor),
            after: edited,
            kind: kind
        )
        if edited != current { text = edited }
        select(caret: caret, anchor: anchor, in: edited)
    }

    // MARK: - Keys

    private func handle(_ key: KeyEvent) {
        let current = text
        var characters = Array(current)
        let resolved = currentSelection(in: current)
        var caret = resolved.caret
        var anchor = resolved.anchor
        let lower = min(caret, anchor)
        let upper = max(caret, anchor)
        let command = key.modifiers.contains(.command)
        let option = key.modifiers.contains(.option)
        let control = key.modifiers.contains(.control)
        let shift = key.modifiers.contains(.shift)
        let lines = layout.lines(for: current, font: font)
        var kind: TextUndoHistory.Kind?
        var keepsGoal = false

        func replaceSelection(with inserted: [Character], as editKind: TextUndoHistory.Kind) {
            characters.replaceSubrange(lower..<upper, with: inserted)
            caret = lower + inserted.count
            anchor = caret
            kind = editKind
        }

        func remove(_ range: Range<Int>) {
            characters.removeSubrange(range)
            caret = range.lowerBound
            anchor = caret
            kind = .deleting
        }

        /// Move the caret to `target`, extending the selection with ⇧.
        func move(to target: Int) {
            caret = max(0, min(characters.count, target))
            if !shift { anchor = caret }
        }

        /// Move `delta` lines up (negative) or down, keeping to the column
        /// the vertical moves started from.
        func moveLines(_ delta: Int) {
            let line = TextAreaLayout.lineIndex(of: caret, in: lines)
            let goal = layout.goalX ?? TextAreaLayout.x(of: caret, in: lines)
            let target = line + delta
            if target < 0 {
                move(to: 0)
            } else if target >= lines.count {
                move(to: characters.count)
            } else {
                move(to: TextAreaLayout.offset(nearestX: goal, on: lines[target], in: characters))
            }
            layout.goalX = goal
            keepsGoal = true
        }

        switch key.keyCode {
        case 0x24, 0x4C:  // return, keypad enter
            if case .field = mode, !option, !control {
                onSubmit()
                return
            }
            replaceSelection(with: ["\n"], as: .typing)
        case 0x30:  // tab
            guard mode == .editor else { return }
            replaceSelection(with: ["\t"], as: .typing)
        case 0x33:  // delete (backspace)
            if lower != upper {
                replaceSelection(with: [], as: .deleting)
            } else if caret > 0 {
                let start: Int
                if command {
                    let lineStart = lines[TextAreaLayout.lineIndex(of: caret, in: lines)].start
                    start = lineStart < caret ? lineStart : caret - 1
                } else if option {
                    start = TextWords.start(in: characters, before: caret)
                } else {
                    start = caret - 1
                }
                remove(start..<caret)
            }
        case 0x75:  // forward delete
            if lower != upper {
                replaceSelection(with: [], as: .deleting)
            } else if caret < characters.count {
                let end: Int
                if command {
                    let lineEnd = TextAreaLayout.visualEnd(of: lines[TextAreaLayout.lineIndex(of: caret, in: lines)], in: characters)
                    end = lineEnd > caret ? lineEnd : caret + 1
                } else if option {
                    end = TextWords.end(in: characters, after: caret)
                } else {
                    end = caret + 1
                }
                remove(caret..<end)
            }
        case 0x7B:  // left
            if command {
                move(to: lines[TextAreaLayout.lineIndex(of: caret, in: lines)].start)
            } else if option {
                move(to: TextWords.start(in: characters, before: caret))
            } else if lower != upper, !shift {
                move(to: lower)
            } else {
                move(to: caret - 1)
            }
        case 0x7C:  // right
            if command {
                move(to: TextAreaLayout.visualEnd(of: lines[TextAreaLayout.lineIndex(of: caret, in: lines)], in: characters))
            } else if option {
                move(to: TextWords.end(in: characters, after: caret))
            } else if lower != upper, !shift {
                move(to: upper)
            } else {
                move(to: caret + 1)
            }
        case 0x7E:  // up
            if command {
                move(to: 0)
            } else if option {
                move(to: TextAreaLayout.paragraphStart(in: characters, before: caret))
            } else {
                if lower != upper, !shift { caret = lower }
                moveLines(-1)
            }
        case 0x7D:  // down
            if command {
                move(to: characters.count)
            } else if option {
                move(to: TextAreaLayout.paragraphEnd(in: characters, after: caret))
            } else {
                if lower != upper, !shift { caret = upper }
                moveLines(1)
            }
        case 0x73:  // home
            move(to: 0)
        case 0x77:  // end
            move(to: characters.count)
        case 0x74:  // page up
            moveLines(-max(1, layout.visibleLineCount - 1))
        case 0x79:  // page down
            moveLines(max(1, layout.visibleLineCount - 1))
        case 0x35:  // escape
            return
        default:
            if command {
                // Where the Edit menu has these as key equivalents they arrive
                // as its commands instead (`perform`); this is for where not.
                switch key.characters?.lowercased() {
                case "a": perform(.selectAll)
                case "c": perform(.copy)
                case "x": perform(.cut)
                case "v": perform(.paste)
                case "z": perform(shift ? .redo : .undo)
                default: break
                }
                return
            }
            guard !control, let typed = key.characters else { return }
            let printable = printableCharacters(of: typed)
            guard !printable.isEmpty else { return }
            replaceSelection(with: Array(printable), as: .typing)
        }

        if !keepsGoal { layout.goalX = nil }
        if let kind {
            commit(String(characters), caret: caret, anchor: anchor, kind: kind)
        } else {
            history.endCoalescing()
            select(caret: caret, anchor: anchor, in: current)
        }
    }

    // MARK: - Editing commands

    private func perform(_ command: EditCommand) {
        let current = text
        var characters = Array(current)
        let resolved = currentSelection(in: current)
        let lower = min(resolved.caret, resolved.anchor)
        let upper = max(resolved.caret, resolved.anchor)
        layout.goalX = nil

        switch command {
        case .selectAll:
            history.endCoalescing()
            select(caret: characters.count, anchor: 0, in: current)
        case .copy:
            if lower != upper { TextFieldPasteboard.write(String(characters[lower..<upper])) }
        case .cut:
            guard lower != upper else { return }
            TextFieldPasteboard.write(String(characters[lower..<upper]))
            characters.removeSubrange(lower..<upper)
            commit(String(characters), caret: lower, anchor: lower, kind: .other)
        case .paste:
            guard let pasted = TextFieldPasteboard.read(), !pasted.isEmpty else { return }
            characters.replaceSubrange(lower..<upper, with: Array(pasted))
            let caret = lower + pasted.count
            commit(String(characters), caret: caret, anchor: caret, kind: .other)
        case .undo:
            let snapshot = TextSnapshot(text: current, caret: resolved.caret, anchor: resolved.anchor)
            guard let previous = history.undo(from: snapshot) else { return }
            text = previous.text
            select(caret: previous.caret, anchor: previous.anchor, in: previous.text)
        case .redo:
            let snapshot = TextSnapshot(text: current, caret: resolved.caret, anchor: resolved.anchor)
            guard let next = history.redo(from: snapshot) else { return }
            text = next.text
            select(caret: next.caret, anchor: next.anchor, in: next.text)
        }
    }

    // MARK: - Pointer

    /// A press at character offset `index`: places the caret, or with ⇧
    /// extends the selection to it; a double press selects the word, a
    /// triple the paragraph.
    private func press(at index: Int, extending: Bool) {
        let current = text
        let characters = Array(current)
        let resolved = currentSelection(in: current)
        history.endCoalescing()
        layout.goalX = nil
        switch clicks.press(at: index) {
        case 1:
            clicks.origin = index..<index
            select(caret: index, anchor: extending ? resolved.anchor : index, in: current)
        case 2:
            let word = TextWords.range(in: characters, at: index)
            clicks.origin = word
            select(caret: word.upperBound, anchor: word.lowerBound, in: current)
        default:
            let paragraph = TextAreaLayout.paragraphRange(in: characters, at: index)
            clicks.origin = paragraph
            select(caret: paragraph.upperBound, anchor: paragraph.lowerBound, in: current)
        }
    }

    /// The pointer dragged to `index`: the selection follows it — by
    /// character, or by word or paragraph after a double or triple press.
    private func drag(to index: Int) {
        let current = text
        let characters = Array(current)
        let resolved = currentSelection(in: current)
        let origin = clicks.origin
        let unit: Range<Int>
        switch clicks.count {
        case ...1:
            select(caret: index, anchor: resolved.anchor, in: current)
            return
        case 2:
            unit = TextWords.range(in: characters, at: index)
        default:
            unit = TextAreaLayout.paragraphRange(in: characters, at: index)
        }
        if unit.lowerBound < origin.lowerBound {
            select(caret: unit.lowerBound, anchor: origin.upperBound, in: current)
        } else {
            select(caret: max(unit.upperBound, origin.upperBound), anchor: origin.lowerBound, in: current)
        }
    }
}

// MARK: - Layout

/// One line as laid out: the characters `start..<end` of the text, and the
/// x of each boundary between them from the line's left edge
/// (`xs.count == end - start + 1`). A line ended by a line break does not
/// include it; `isSoftWrapped` says the line was broken to fit instead, so
/// the next one starts at `end`.
struct TextAreaLine: Equatable {
    let start: Int
    let end: Int
    let xs: [Double]
    let isSoftWrapped: Bool

    var width: Double { xs.last ?? 0 }
}

/// What a text area remembers between placements: its lines at the width
/// it was last given, how far it is scrolled, and the column vertical caret
/// moves keep to.
@MainActor
final class TextAreaLayout {
    /// Lines of `text` at `width` in `font`, the last ones worked out.
    private var cache: (text: String, font: Font, width: Double?, lines: [TextAreaLine])?

    /// The width the text was last wrapped to — for a key press that needs
    /// lines before the area has been placed again.
    private(set) var wrapWidth: Double?

    var offset: Double = 0
    private(set) var contentHeight: Double = 0
    private(set) var viewportHeight: Double = 0
    private(set) var lineHeight: Double = 0
    /// What the caret and text were when the area was last placed — it
    /// scrolls to the caret only when one of them has changed, so the wheel
    /// can take it elsewhere.
    var placedCaret = -1
    var placedText: String?

    /// The x vertical moves keep to, from the first of a run of them.
    var goalX: Double?

    var overflows: Bool { contentHeight > viewportHeight + 0.5 }

    /// How many whole lines fit in the viewport.
    var visibleLineCount: Int {
        guard lineHeight > 0 else { return 1 }
        return max(1, Int(viewportHeight / lineHeight))
    }

    /// Scroll by a wheel delta; whether the offset moved.
    func scroll(by dy: Double) -> Bool {
        let next = max(0, min(offset - dy, max(0, contentHeight - viewportHeight)))
        guard next != offset else { return false }
        offset = next
        return true
    }

    func noteViewport(contentHeight: Double, viewportHeight: Double, lineHeight: Double) {
        self.contentHeight = contentHeight
        self.viewportHeight = viewportHeight
        self.lineHeight = lineHeight
    }

    /// `text`'s lines at the width it was last placed at.
    func lines(for text: String, font: Font) -> [TextAreaLine] {
        lines(for: text, font: font, width: wrapWidth)
    }

    /// `text`'s lines wrapped to `width` (`nil`: never wrapped).
    func lines(for text: String, font: Font, width: Double?) -> [TextAreaLine] {
        if let cache, cache.width == width, cache.font == font, cache.text == text {
            return cache.lines
        }
        let lines = Self.layOut(Array(text), font: font, width: width)
        cache = (text, font, width, lines)
        return lines
    }

    func noteWrapWidth(_ width: Double?) {
        wrapWidth = width
    }

    /// Break `characters` into lines no wider than `width`: at line breaks,
    /// and after the last space that fits, or mid-word for a word wider
    /// than the whole line. Spaces may hang past the edge. Tabs advance to
    /// the next stop four spaces apart.
    static func layOut(_ characters: [Character], font: Font, width: Double?) -> [TextAreaLine] {
        var advances: [Character: Double] = [:]
        func advance(_ character: Character) -> Double {
            if let known = advances[character] { return known }
            let measured = TextMeasurer.width(of: String(character), font: font)
            advances[character] = measured
            return measured
        }
        let tabStop = max(1, 4 * advance(" "))

        var lines: [TextAreaLine] = []
        var paragraphStart = 0
        while true {
            var paragraphEnd = paragraphStart
            while paragraphEnd < characters.count, !characters[paragraphEnd].isNewline { paragraphEnd += 1 }

            var lineStart = paragraphStart
            var xs: [Double] = [0]
            var lastBreak: Int?
            var index = paragraphStart
            while index < paragraphEnd {
                let character = characters[index]
                let x = xs[xs.count - 1]
                let step = character == "\t" ? (Double(Int(x / tabStop)) + 1) * tabStop - x : advance(character)
                if let width, x + step > width, index > lineStart, !character.isWhitespace {
                    let breakAt = lastBreak ?? index
                    lines.append(TextAreaLine(
                        start: lineStart,
                        end: breakAt,
                        xs: Array(xs[0...(breakAt - lineStart)]),
                        isSoftWrapped: true
                    ))
                    // Lay the carried-over characters out again from the new
                    // line's left edge — tabs land on different stops.
                    lineStart = breakAt
                    lastBreak = nil
                    xs = [0]
                    for carried in breakAt..<index {
                        let c = characters[carried]
                        let cx = xs[xs.count - 1]
                        let cStep = c == "\t" ? (Double(Int(cx / tabStop)) + 1) * tabStop - cx : advance(c)
                        xs.append(cx + cStep)
                        if c.isWhitespace { lastBreak = carried + 1 }
                    }
                    continue
                }
                xs.append(x + step)
                if character.isWhitespace { lastBreak = index + 1 }
                index += 1
            }
            lines.append(TextAreaLine(start: lineStart, end: paragraphEnd, xs: xs, isSoftWrapped: false))

            guard paragraphEnd < characters.count else { break }
            paragraphStart = paragraphEnd + 1
        }
        return lines
    }

    /// The line the caret at `offset` is drawn on: the last that starts at
    /// or before it — so an offset where a line was soft-wrapped is on the
    /// line after the break.
    static func lineIndex(of offset: Int, in lines: [TextAreaLine]) -> Int {
        var low = 0
        var high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].start <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The x of the caret at `offset`, from its line's left edge.
    static func x(of offset: Int, in lines: [TextAreaLine]) -> Double {
        let line = lines[lineIndex(of: offset, in: lines)]
        let column = max(0, min(offset - line.start, line.xs.count - 1))
        return line.xs[column]
    }

    /// The last offset a caret can sit at on `line` and still be drawn on
    /// it: before the space a soft-wrapped line was broken after.
    static func visualEnd(of line: TextAreaLine, in characters: [Character]) -> Int {
        if line.isSoftWrapped, line.end > line.start, characters[line.end - 1].isWhitespace {
            return line.end - 1
        }
        return line.end
    }

    /// The offset on `line` whose boundary is nearest `x`.
    static func offset(nearestX x: Double, on line: TextAreaLine, in characters: [Character]) -> Int {
        let last = visualEnd(of: line, in: characters)
        var best = line.start
        for offset in line.start...last {
            let boundary = line.xs[offset - line.start]
            if boundary <= x {
                best = offset
            } else {
                let previous = line.xs[best - line.start]
                return x - previous < boundary - x ? best : offset
            }
        }
        return best
    }

    /// Start of the paragraph `offset` is in — or of the one before, when
    /// already at a start.
    static func paragraphStart(in characters: [Character], before offset: Int) -> Int {
        var i = offset
        if i > 0, characters[i - 1].isNewline { i -= 1 }
        while i > 0, !characters[i - 1].isNewline { i -= 1 }
        return i
    }

    /// End of the paragraph `offset` is in — or of the one after, when
    /// already at an end.
    static func paragraphEnd(in characters: [Character], after offset: Int) -> Int {
        var i = offset
        if i < characters.count, characters[i].isNewline { i += 1 }
        while i < characters.count, !characters[i].isNewline { i += 1 }
        return i
    }

    /// The paragraph a triple press at `offset` selects, with its line break.
    static func paragraphRange(in characters: [Character], at offset: Int) -> Range<Int> {
        var lower = min(offset, characters.count)
        while lower > 0, !characters[lower - 1].isNewline { lower -= 1 }
        var upper = min(offset, characters.count)
        while upper < characters.count, !characters[upper].isNewline { upper += 1 }
        if upper < characters.count { upper += 1 }
        return lower..<upper
    }
}

// MARK: - The lines

/// The text, selection and caret of a multi-line area. A leaf, because the
/// lines — and so where the caret is, and how far to scroll — are only
/// known once the area has its width.
@View
struct TextAreaLines {
    let text: String
    let font: Font
    let color: Color
    let selectionColor: Color
    let caret: Int
    let anchor: Int
    let showsCaret: Bool
    let mode: MultilineTextMode
    let horizontalInset: Double
    let verticalInset: Double
    let layout: TextAreaLayout
    let scrollTick: Int
    let isEnabled: Bool
    let editCommands: Set<EditCommand>
    let onFocusChange: @MainActor (Bool) -> Void
    let onKeyDown: @MainActor (KeyEvent) -> Void
    let onEditCommand: @MainActor (EditCommand) -> Void
    /// A press at a character offset; `true` extends the selection (⇧).
    let onPress: @MainActor (Int, Bool) -> Void
    let onDrag: @MainActor (Int) -> Void
    /// A wheel's vertical delta.
    let onScroll: @MainActor (Double) -> Void

    var body: Never { bodyUnavailable() }
}

extension TextAreaLines: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let text = self.text
        let font = self.font
        let layout = self.layout
        let verticalInset = self.verticalInset
        let horizontalInset = self.horizontalInset
        let onPress = self.onPress
        let onDrag = self.onDrag
        /// The character offset under `point` (the area's own space): the
        /// boundary nearest to it on the line it is over.
        let index: @MainActor (Point) -> Int = { point in
            let lines = layout.lines(for: text, font: font)
            let lineHeight = TextMeasurer.lineMetrics(for: font).lineHeight
            let row = Int(((point.y - verticalInset + layout.offset) / lineHeight).rounded(.down))
            let characters = Array(text)
            if row < 0 { return 0 }
            if row >= lines.count { return characters.count }
            return TextAreaLayout.offset(nearestX: point.x - horizontalInset, on: lines[row], in: characters)
        }
        return ViewNode(content: TextAreaContent(
            text: text,
            font: font,
            color: color,
            selectionColor: selectionColor,
            caret: caret,
            anchor: anchor,
            showsCaret: showsCaret,
            mode: mode,
            horizontalInset: horizontalInset,
            verticalInset: verticalInset,
            layout: layout,
            isEnabled: isEnabled,
            onPress: { point in onPress(index(point), textShiftHeld) },
            onDrag: { point in onDrag(index(point)) },
            onScroll: onScroll,
            focus: FocusTarget(
                path: context.path,
                isEnabled: isEnabled,
                onFocusChange: onFocusChange,
                onKeyDown: onKeyDown,
                editCommands: editCommands,
                onEditCommand: onEditCommand,
                isTabStop: true,
                insertsTab: mode == .editor
            )
        ))
    }
}

struct TextAreaContent: NodeContent {
    let text: String
    let font: Font
    let color: Color
    let selectionColor: Color
    let caret: Int
    let anchor: Int
    let showsCaret: Bool
    let mode: MultilineTextMode
    let horizontalInset: Double
    let verticalInset: Double
    let layout: TextAreaLayout
    let isEnabled: Bool
    let onPress: @MainActor (Point) -> Void
    let onDrag: @MainActor (Point) -> Void
    let onScroll: @MainActor (Double) -> Void
    let focus: FocusTarget

    var focusTarget: FocusTarget? { focus }

    /// Built when asked for, so whether the wheel is taken follows the last
    /// placement: an area whose text all fits leaves the wheel to the
    /// scroll view around it.
    var hitTarget: HitTarget? {
        let onScroll = self.onScroll
        let onDrag = self.onDrag
        var scroll: (@MainActor (Point) -> Void)?
        if layout.overflows {
            scroll = { delta in onScroll(delta.y) }
        }
        return HitTarget(
            isEnabled: isEnabled,
            minimumDragDistance: 0,
            onPress: onPress,
            onScroll: scroll,
            onDragChanged: { value in onDrag(value.location) }
        )
    }

    /// A text editor is as flexible as a scroll view; a field only across.
    func flexibility(along axis: Axis, node: ViewNode) -> LayoutPriorityClass {
        mode == .editor ? .flexible : .content
    }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        let lineHeight = TextMeasurer.lineMetrics(for: font).lineHeight
        let wrapWidth = proposal.width.map { max(0, $0 - 2 * horizontalInset) }
        let lines = layout.lines(for: text, font: font, width: wrapWidth)
        let natural = lines.reduce(0) { max($0, $1.width) } + 2 * horizontalInset
        switch mode {
        case .editor:
            return proposal.replacingUnspecifiedDimensions(by: Size(
                width: max(natural, 100),
                height: Double(max(lines.count, 3)) * lineHeight + 2 * verticalInset
            ))
        case .field(let minLines, let maxLines):
            var count = max(lines.count, minLines, 1)
            if let maxLines { count = min(count, max(1, maxLines)) }
            return Size(
                width: proposal.width ?? max(80, natural),
                height: Double(count) * lineHeight + 2 * verticalInset
            )
        }
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        let lineHeight = TextMeasurer.lineMetrics(for: font).lineHeight
        let viewport = Rect(
            x: rect.minX + horizontalInset,
            y: rect.minY + verticalInset,
            width: max(0, rect.width - 2 * horizontalInset),
            height: max(0, rect.height - 2 * verticalInset)
        )
        layout.noteWrapWidth(viewport.width)
        let lines = layout.lines(for: text, font: font, width: viewport.width)
        let characters = Array(text)
        let contentHeight = Double(lines.count) * lineHeight
        layout.noteViewport(contentHeight: contentHeight, viewportHeight: viewport.height, lineHeight: lineHeight)

        // Scroll just enough to show the caret — only when it or the text
        // has moved since the last placement, so the wheel's offset stays.
        var offset = layout.offset
        if caret != layout.placedCaret || text != layout.placedText {
            let caretTop = Double(TextAreaLayout.lineIndex(of: caret, in: lines)) * lineHeight
            if caretTop - offset < 0 { offset = caretTop }
            if caretTop + lineHeight - offset > viewport.height { offset = caretTop + lineHeight - viewport.height }
            layout.placedCaret = caret
            layout.placedText = text
        }
        offset = max(0, min(offset, max(0, contentHeight - viewport.height)))
        layout.offset = offset

        let clip = context.clip.map { viewport.intersection($0) } ?? viewport
        let firstRow = max(0, Int((offset / lineHeight).rounded(.down)))
        let lastRow = min(lines.count - 1, Int(((offset + viewport.height) / lineHeight).rounded(.up)) - 1)
        guard firstRow <= lastRow else { return }
        let lower = min(caret, anchor)
        let upper = max(caret, anchor)
        let resolvedColor = context.resolve(color)

        for row in firstRow...lastRow {
            let line = lines[row]
            let top = viewport.minY + Double(row) * lineHeight - offset
            let left = viewport.minX

            // The selection's part of this line — past its end, to show the
            // line break is selected too.
            if lower != upper {
                let from = max(lower, line.start)
                let to = min(upper, line.end)
                let includesBreak = !line.isSoftWrapped && lower <= line.end && upper > line.end
                if from < to || (includesBreak && from <= to) {
                    let leftX = line.xs[from - line.start]
                    let right = line.xs[to - line.start] + (includesBreak ? 6 : 0)
                    var path = Path()
                    path.addRect(Rect(x: left + leftX, y: top, width: right - leftX, height: lineHeight))
                    list.append(.shape(ShapeDraw(
                        path: path,
                        bounds: viewport,
                        fill: context.resolve(.color(selectionColor)),
                        transform: context.transform,
                        clip: clip
                    )))
                }
            }

            // The text, one run between tabs at a time — a tab is space the
            // layout decided, not a glyph.
            var runStart = line.start
            while runStart < line.end {
                var runEnd = runStart
                while runEnd < line.end, characters[runEnd] != "\t" { runEnd += 1 }
                if runEnd > runStart {
                    let x0 = line.xs[runStart - line.start]
                    let x1 = line.xs[runEnd - line.start]
                    list.append(.text(TextDraw(
                        string: String(characters[runStart..<runEnd]),
                        frame: Rect(x: left + x0, y: top, width: x1 - x0 + 1, height: lineHeight),
                        font: font,
                        color: resolvedColor,
                        lineLimit: 1,
                        wraps: false,
                        transform: context.transform,
                        clip: clip
                    )))
                }
                runStart = runEnd + 1
            }
        }

        if showsCaret {
            let row = TextAreaLayout.lineIndex(of: caret, in: lines)
            let top = viewport.minY + Double(row) * lineHeight - offset
            let x = TextAreaLayout.x(of: caret, in: lines)
            var path = Path()
            path.addRect(Rect(x: viewport.minX + x, y: top, width: 1.5, height: lineHeight))
            list.append(.shape(ShapeDraw(
                path: path,
                bounds: viewport,
                fill: context.resolve(.color(color)),
                transform: context.transform,
                clip: clip.insetBy(-1)
            )))
        }
    }
}
