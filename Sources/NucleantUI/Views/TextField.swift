//
//  TextField.swift
//  NucleantUI
//
//  An editable text field, and `.onSubmit`.
//

import Foundation
#if os(macOS)
import AppKit
#endif

/// A control that displays an editable line of text.
///
/// ```swift
/// TextField("Address", text: $address)
///     .onSubmit { page.load(address) }
///
/// TextField("Notes", text: $notes, axis: .vertical)
///     .lineLimit(3...8)
///
/// TextField("Price", value: $price, format: .number)
/// ```
///
/// Pressing it gives it the keys, and so does Tab from another field:
/// typing inserts at the caret, ⌫/⌦ delete, ←/→ move (⌥ by word, ⌘ to the
/// ends, ⇧ to select), a double press selects a word and a triple the
/// whole text, ⌘A selects all, ⌘C/⌘X/⌘V copy, cut and paste, ⌘Z/⇧⌘Z undo
/// and redo, and Return runs the `.onSubmit` actions around it. Pressing
/// anywhere else takes the keys away. Text wider than the field scrolls to
/// keep the caret in view.
///
/// With `axis: .vertical` the text wraps and the field grows downwards, one
/// line at a time, up to the `lineLimit` in its environment and then
/// scrolls; ⌥Return starts a new line.
///
/// A field bound to a `value` shows it through its format and updates it as
/// the text parses; when the field is submitted or loses the keys, the text
/// is formatted again from the value.
///
/// The prompt, or the label when there is none, is the placeholder shown
/// while the text is empty. How the field is drawn is the
/// `.textFieldStyle(_:)` around it.
@View
public struct TextField<Label: View> {
    let label: Label
    let prompt: Text?
    let source: TextFieldSource
    let axis: Axis
    let selection: TextSelectionSource
    let onEditingChanged: ((Bool) -> Void)?
    let onCommit: (() -> Void)?

    @Environment(\.font) private var font
    @Environment(\.foregroundColor) private var foreground
    @Environment(\.tint) private var tint
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.submitActions) private var submitActions
    @Environment(\.textFieldDecoration) private var decoration
    @Environment(\.lineLimit) private var lineLimit
    @Environment(\.reservedLineCount) private var reservedLineCount

    /// Caret, selection anchor and focus — the field's own transient state.
    @State private var editing = TextEditing()
    /// A value field's text while it has the keys — what the user typed,
    /// not yet formatted again from the value.
    @State private var draft: String? = nil
    /// How far the text is scrolled, kept across placements; written while
    /// the field is placed, so a reference the placement can reach.
    @State private var scroll = TextFieldScroll()
    @State private var history = TextUndoHistory()
    @State private var clicks = TextClickCounter()

    init(
        label: Label,
        prompt: Text?,
        source: TextFieldSource,
        axis: Axis = .horizontal,
        selection: Binding<TextSelection?>? = nil,
        onEditingChanged: ((Bool) -> Void)? = nil,
        onCommit: (() -> Void)? = nil,
        _viewID: ViewID
    ) {
        self.label = label
        self.prompt = prompt
        self.source = source
        self.axis = axis
        self.selection = TextSelectionSource(binding: selection)
        self.onEditingChanged = onEditingChanged
        self.onCommit = onCommit
        self._viewID = _viewID
    }

    public var body: some View {
        TextFieldChrome(
            decoration: decoration,
            isFocused: editing.isFocused,
            isEmpty: displayText.isEmpty,
            placeholderAlignment: verticalText == nil ? .leading : .topLeading,
            placeholderTopInset: verticalText == nil ? 0 : Self.verticalInset,
            content: field,
            placeholder: placeholder
        )
    }

    /// Above and below the text, each side.
    private static var verticalInset: Double { 4 }

    /// The text a vertical field edits — only a field bound to a string
    /// grows downwards.
    private var verticalText: Binding<String>? {
        guard axis == .vertical, case .text(let binding) = source else { return nil }
        return binding
    }

    @ViewBuilder
    private var field: some View {
        if let text = verticalText {
            MultilineTextArea(
                text: text,
                selection: selection,
                mode: .field(minLines: reservedLineCount, maxLines: lineLimit),
                horizontalInset: decoration.inset,
                verticalInset: Self.verticalInset,
                onFocusChange: { focused in
                    editing.isFocused = focused
                    onEditingChanged?(focused)
                },
                onSubmit: { submit() }
            )
        } else {
            let current = displayText
            let resolved = selection.resolve((editing.caret, editing.anchor), in: current)
            TextFieldLine(
                text: current,
                font: font,
                color: foreground,
                selectionColor: tint.opacity(editing.isFocused ? 0.3 : 0.15),
                caret: resolved.caret,
                anchor: resolved.anchor,
                showsCaret: editing.isFocused,
                scroll: scroll,
                inset: decoration.inset,
                isEnabled: isEnabled,
                editCommands: editCommands,
                onFocusChange: { focused in focusChanged(focused) },
                onKeyDown: { key in handle(key) },
                onEditCommand: { command in perform(command) },
                onPress: { index, extending in press(at: index, extending: extending) },
                onDrag: { index in drag(to: index) }
            )
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let prompt {
            prompt
        } else {
            label
        }
    }

    // MARK: - Text

    /// What the field shows: the bound text, or a value field's draft while
    /// it has the keys and the formatted value otherwise.
    private var displayText: String {
        switch source {
        case .text(let binding): binding.wrappedValue
        case .value(let value): draft ?? value.formatted()
        }
    }

    /// Put `edited` in the field: into the bound text, or into a value
    /// field's draft and — when it parses — the value.
    private func write(_ edited: String) {
        switch source {
        case .text(let binding):
            if binding.wrappedValue != edited { binding.wrappedValue = edited }
        case .value(let value):
            if draft != edited { draft = edited }
            value.update(from: edited)
        }
    }

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
        let current = displayText
        let before = currentSelection(in: current)
        history.record(
            TextSnapshot(text: current, caret: before.caret, anchor: before.anchor),
            after: edited,
            kind: kind
        )
        write(edited)
        select(caret: caret, anchor: anchor, in: edited)
    }

    private func focusChanged(_ focused: Bool) {
        editing.isFocused = focused
        if focused {
            let current: String
            if case .value(let value) = source {
                current = value.formatted()
                draft = current
            } else {
                current = displayText
            }
            // Tabbing in selects everything; a press that gave the keys
            // places the caret right after.
            select(caret: current.count, anchor: 0, in: current)
        } else {
            history.endCoalescing()
            if case .value = source { draft = nil }
        }
        onEditingChanged?(focused)
    }

    /// Return: a value field's text is formatted again from its value, then
    /// `onCommit` and the `.onSubmit` actions run.
    private func submit() {
        if case .value(let value) = source, editing.isFocused {
            let formatted = value.formatted()
            draft = formatted
            history.endCoalescing()
            select(caret: formatted.count, anchor: formatted.count, in: formatted)
        }
        onCommit?()
        for action in submitActions where action.triggers.contains(.text) {
            action.perform()
        }
    }

    // MARK: - Editing

    private func handle(_ key: KeyEvent) {
        let current = displayText
        var characters = Array(current)
        let resolved = currentSelection(in: current)
        var caret = resolved.caret
        var anchor = resolved.anchor
        let lower = min(caret, anchor)
        let upper = max(caret, anchor)
        let command = key.modifiers.contains(.command)
        let option = key.modifiers.contains(.option)
        let shift = key.modifiers.contains(.shift)
        var kind: TextUndoHistory.Kind?

        func replaceSelection(with inserted: [Character], as editKind: TextUndoHistory.Kind) {
            characters.replaceSubrange(lower..<upper, with: inserted)
            caret = lower + inserted.count
            anchor = caret
            kind = editKind
        }

        /// Move the caret to `target`, extending the selection with ⇧.
        func move(to target: Int) {
            caret = max(0, min(characters.count, target))
            if !shift { anchor = caret }
        }

        switch key.keyCode {
        case 0x24, 0x4C:  // return, keypad enter
            submit()
            return
        case 0x33:  // delete (backspace)
            if lower != upper {
                replaceSelection(with: [], as: .deleting)
            } else if caret > 0 {
                let start = command ? 0 : option ? Self.wordStart(in: characters, before: caret) : caret - 1
                characters.removeSubrange(start..<caret)
                caret = start
                anchor = caret
                kind = .deleting
            }
        case 0x75:  // forward delete
            if lower != upper {
                replaceSelection(with: [], as: .deleting)
            } else if caret < characters.count {
                let end = command ? characters.count
                    : option ? Self.wordEnd(in: characters, after: caret) : caret + 1
                characters.removeSubrange(caret..<end)
                anchor = caret
                kind = .deleting
            }
        case 0x7B:  // left
            if command {
                move(to: 0)
            } else if option {
                move(to: Self.wordStart(in: characters, before: caret))
            } else if lower != upper, !shift {
                move(to: lower)
            } else {
                move(to: caret - 1)
            }
        case 0x7C:  // right
            if command {
                move(to: characters.count)
            } else if option {
                move(to: Self.wordEnd(in: characters, after: caret))
            } else if lower != upper, !shift {
                move(to: upper)
            } else {
                move(to: caret + 1)
            }
        case 0x7E, 0x73, 0x74:  // up, home, page up
            move(to: 0)
        case 0x7D, 0x77, 0x79:  // down, end, page down
            move(to: characters.count)
        case 0x30, 0x35:  // tab, escape
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
            } else {
                guard !key.modifiers.contains(.control), let typed = key.characters else { return }
                let printable = printableCharacters(of: typed)
                guard !printable.isEmpty else { return }
                replaceSelection(with: Array(printable), as: .typing)
            }
        }

        if let kind {
            commit(String(characters), caret: caret, anchor: anchor, kind: kind)
        } else {
            history.endCoalescing()
            select(caret: caret, anchor: anchor, in: current)
        }
    }

    /// The editing commands the field takes: undo and redo only when there
    /// is something to undo or redo, so the Edit menu shows it.
    private var editCommands: Set<EditCommand> {
        var commands: Set<EditCommand> = [.cut, .copy, .paste, .selectAll]
        if history.canUndo { commands.insert(.undo) }
        if history.canRedo { commands.insert(.redo) }
        return commands
    }

    /// An editing command, from the Edit menu or its ⌘-key.
    private func perform(_ command: EditCommand) {
        let current = displayText
        var characters = Array(current)
        let resolved = currentSelection(in: current)
        let lower = min(resolved.caret, resolved.anchor)
        let upper = max(resolved.caret, resolved.anchor)

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
            guard let pasted = TextFieldPasteboard.read() else { return }
            // One line: a pasted newline would end the field's only line.
            let inserted = Array(pasted.filter { !$0.isNewline })
            guard !inserted.isEmpty || lower != upper else { return }
            characters.replaceSubrange(lower..<upper, with: inserted)
            let caret = lower + inserted.count
            commit(String(characters), caret: caret, anchor: caret, kind: .other)
        case .undo:
            let snapshot = TextSnapshot(text: current, caret: resolved.caret, anchor: resolved.anchor)
            guard let previous = history.undo(from: snapshot) else { return }
            write(previous.text)
            select(caret: previous.caret, anchor: previous.anchor, in: previous.text)
        case .redo:
            let snapshot = TextSnapshot(text: current, caret: resolved.caret, anchor: resolved.anchor)
            guard let next = history.redo(from: snapshot) else { return }
            write(next.text)
            select(caret: next.caret, anchor: next.anchor, in: next.text)
        }
    }

    // MARK: - Pointer

    /// A press at character offset `index`: places the caret, or with ⇧
    /// extends the selection to it; a double press selects the word, a
    /// triple all of the text.
    private func press(at index: Int, extending: Bool) {
        let current = displayText
        let characters = Array(current)
        let resolved = currentSelection(in: current)
        history.endCoalescing()
        switch clicks.press(at: index) {
        case 1:
            clicks.origin = index..<index
            select(caret: index, anchor: extending ? resolved.anchor : index, in: current)
        case 2:
            let word = TextWords.range(in: characters, at: index)
            clicks.origin = word
            select(caret: word.upperBound, anchor: word.lowerBound, in: current)
        default:
            clicks.origin = 0..<characters.count
            select(caret: characters.count, anchor: 0, in: current)
        }
    }

    /// The pointer dragged to `index`: the selection follows it — by
    /// character, or by word after a double press.
    private func drag(to index: Int) {
        let current = displayText
        let resolved = currentSelection(in: current)
        let origin = clicks.origin
        switch clicks.count {
        case ...1:
            select(caret: index, anchor: resolved.anchor, in: current)
        case 2:
            let word = TextWords.range(in: Array(current), at: index)
            if word.lowerBound < origin.lowerBound {
                select(caret: word.lowerBound, anchor: origin.upperBound, in: current)
            } else {
                select(caret: max(word.upperBound, origin.upperBound), anchor: origin.lowerBound, in: current)
            }
        default:
            break
        }
    }

    /// Start of the word before `index` — back over spaces, then over the word.
    private static func wordStart(in characters: [Character], before index: Int) -> Int {
        var i = index
        while i > 0, !isWordCharacter(characters[i - 1]) { i -= 1 }
        while i > 0, isWordCharacter(characters[i - 1]) { i -= 1 }
        return i
    }

    /// End of the word after `index`.
    private static func wordEnd(in characters: [Character], after index: Int) -> Int {
        var i = index
        while i < characters.count, !isWordCharacter(characters[i]) { i += 1 }
        while i < characters.count, isWordCharacter(characters[i]) { i += 1 }
        return i
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}

// MARK: - Initializers

@MainActor
extension TextField {
    /// A field editing `text`, with `label` as its placeholder unless a
    /// `prompt` is given.
    public init(
        text: Binding<String>,
        prompt: Text? = nil,
        _viewID: ViewID = #viewID,
        @ViewBuilder label: () -> Label
    ) {
        self.init(label: label(), prompt: prompt, source: .text(text), _viewID: _viewID)
    }

    /// A field editing `text` that wraps and grows along `axis` when it is
    /// `.vertical`.
    public init(
        text: Binding<String>,
        prompt: Text? = nil,
        axis: Axis,
        _viewID: ViewID = #viewID,
        @ViewBuilder label: () -> Label
    ) {
        self.init(label: label(), prompt: prompt, source: .text(text), axis: axis, _viewID: _viewID)
    }

    /// A field editing `value` through `format`.
    public init<F: ParseableFormatStyle>(
        value: Binding<F.FormatInput>,
        format: F,
        prompt: Text? = nil,
        _viewID: ViewID = #viewID,
        @ViewBuilder label: () -> Label
    ) where F.FormatOutput == String {
        self.init(
            label: label(),
            prompt: prompt,
            source: .value(FormatStyleValue(value: value, format: format)),
            _viewID: _viewID
        )
    }

    /// A field editing an optional `value` through `format`: text that
    /// doesn't parse, or none, makes it `nil`.
    public init<F: ParseableFormatStyle>(
        value: Binding<F.FormatInput?>,
        format: F,
        prompt: Text? = nil,
        _viewID: ViewID = #viewID,
        @ViewBuilder label: () -> Label
    ) where F.FormatOutput == String {
        self.init(
            label: label(),
            prompt: prompt,
            source: .value(OptionalFormatStyleValue(value: value, format: format)),
            _viewID: _viewID
        )
    }

    /// A field editing `value` through `formatter`: text it can't parse
    /// leaves the value as it was.
    public init<V>(
        value: Binding<V>,
        formatter: Formatter,
        prompt: Text? = nil,
        _viewID: ViewID = #viewID,
        @ViewBuilder label: () -> Label
    ) {
        self.init(
            label: label(),
            prompt: prompt,
            source: .value(FormatterValue(value: value, formatter: formatter)),
            _viewID: _viewID
        )
    }
}

@MainActor
extension TextField where Label == Text {
    public init(_ title: String, text: Binding<String>, _viewID: ViewID = #viewID) {
        self.init(label: Text(title), prompt: nil, source: .text(text), _viewID: _viewID)
    }

    public init<S: StringProtocol>(_ title: S, text: Binding<String>, _viewID: ViewID = #viewID) {
        self.init(label: Text(title), prompt: nil, source: .text(text), _viewID: _viewID)
    }

    public init(_ title: String, text: Binding<String>, prompt: Text?, _viewID: ViewID = #viewID) {
        self.init(label: Text(title), prompt: prompt, source: .text(text), _viewID: _viewID)
    }

    public init<S: StringProtocol>(_ title: S, text: Binding<String>, prompt: Text?, _viewID: ViewID = #viewID) {
        self.init(label: Text(title), prompt: prompt, source: .text(text), _viewID: _viewID)
    }

    // Along an axis.

    public init(_ title: String, text: Binding<String>, axis: Axis, _viewID: ViewID = #viewID) {
        self.init(label: Text(title), prompt: nil, source: .text(text), axis: axis, _viewID: _viewID)
    }

    public init<S: StringProtocol>(_ title: S, text: Binding<String>, axis: Axis, _viewID: ViewID = #viewID) {
        self.init(label: Text(title), prompt: nil, source: .text(text), axis: axis, _viewID: _viewID)
    }

    public init(_ title: String, text: Binding<String>, prompt: Text?, axis: Axis, _viewID: ViewID = #viewID) {
        self.init(label: Text(title), prompt: prompt, source: .text(text), axis: axis, _viewID: _viewID)
    }

    public init<S: StringProtocol>(
        _ title: S,
        text: Binding<String>,
        prompt: Text?,
        axis: Axis,
        _viewID: ViewID = #viewID
    ) {
        self.init(label: Text(title), prompt: prompt, source: .text(text), axis: axis, _viewID: _viewID)
    }

    // With a selection.

    public init(
        _ title: String,
        text: Binding<String>,
        selection: Binding<TextSelection?>,
        prompt: Text? = nil,
        axis: Axis? = nil,
        _viewID: ViewID = #viewID
    ) {
        self.init(
            label: Text(title),
            prompt: prompt,
            source: .text(text),
            axis: axis ?? .horizontal,
            selection: selection,
            _viewID: _viewID
        )
    }

    public init<S: StringProtocol>(
        _ title: S,
        text: Binding<String>,
        selection: Binding<TextSelection?>,
        prompt: Text? = nil,
        axis: Axis? = nil,
        _viewID: ViewID = #viewID
    ) {
        self.init(
            label: Text(title),
            prompt: prompt,
            source: .text(text),
            axis: axis ?? .horizontal,
            selection: selection,
            _viewID: _viewID
        )
    }

    // With editing-changed and commit callbacks — SwiftUI's older shape;
    // `.onSubmit` and focus are the current one.

    public init(
        _ title: String,
        text: Binding<String>,
        onEditingChanged: @escaping (Bool) -> Void,
        onCommit: @escaping () -> Void,
        _viewID: ViewID = #viewID
    ) {
        self.init(
            label: Text(title), prompt: nil, source: .text(text),
            onEditingChanged: onEditingChanged, onCommit: onCommit, _viewID: _viewID
        )
    }

    public init(
        _ title: String,
        text: Binding<String>,
        onEditingChanged: @escaping (Bool) -> Void,
        _viewID: ViewID = #viewID
    ) {
        self.init(
            label: Text(title), prompt: nil, source: .text(text),
            onEditingChanged: onEditingChanged, _viewID: _viewID
        )
    }

    public init(
        _ title: String,
        text: Binding<String>,
        onCommit: @escaping () -> Void,
        _viewID: ViewID = #viewID
    ) {
        self.init(label: Text(title), prompt: nil, source: .text(text), onCommit: onCommit, _viewID: _viewID)
    }

    public init<S: StringProtocol>(
        _ title: S,
        text: Binding<String>,
        onEditingChanged: @escaping (Bool) -> Void,
        onCommit: @escaping () -> Void,
        _viewID: ViewID = #viewID
    ) {
        self.init(
            label: Text(title), prompt: nil, source: .text(text),
            onEditingChanged: onEditingChanged, onCommit: onCommit, _viewID: _viewID
        )
    }

    public init<S: StringProtocol>(
        _ title: S,
        text: Binding<String>,
        onEditingChanged: @escaping (Bool) -> Void,
        _viewID: ViewID = #viewID
    ) {
        self.init(
            label: Text(title), prompt: nil, source: .text(text),
            onEditingChanged: onEditingChanged, _viewID: _viewID
        )
    }

    public init<S: StringProtocol>(
        _ title: S,
        text: Binding<String>,
        onCommit: @escaping () -> Void,
        _viewID: ViewID = #viewID
    ) {
        self.init(label: Text(title), prompt: nil, source: .text(text), onCommit: onCommit, _viewID: _viewID)
    }

    // A value through a format style.

    public init<F: ParseableFormatStyle>(
        _ title: String,
        value: Binding<F.FormatInput>,
        format: F,
        prompt: Text? = nil,
        _viewID: ViewID = #viewID
    ) where F.FormatOutput == String {
        self.init(
            label: Text(title), prompt: prompt,
            source: .value(FormatStyleValue(value: value, format: format)), _viewID: _viewID
        )
    }

    public init<S: StringProtocol, F: ParseableFormatStyle>(
        _ title: S,
        value: Binding<F.FormatInput>,
        format: F,
        prompt: Text? = nil,
        _viewID: ViewID = #viewID
    ) where F.FormatOutput == String {
        self.init(
            label: Text(title), prompt: prompt,
            source: .value(FormatStyleValue(value: value, format: format)), _viewID: _viewID
        )
    }

    public init<F: ParseableFormatStyle>(
        _ title: String,
        value: Binding<F.FormatInput?>,
        format: F,
        prompt: Text? = nil,
        _viewID: ViewID = #viewID
    ) where F.FormatOutput == String {
        self.init(
            label: Text(title), prompt: prompt,
            source: .value(OptionalFormatStyleValue(value: value, format: format)), _viewID: _viewID
        )
    }

    public init<S: StringProtocol, F: ParseableFormatStyle>(
        _ title: S,
        value: Binding<F.FormatInput?>,
        format: F,
        prompt: Text? = nil,
        _viewID: ViewID = #viewID
    ) where F.FormatOutput == String {
        self.init(
            label: Text(title), prompt: prompt,
            source: .value(OptionalFormatStyleValue(value: value, format: format)), _viewID: _viewID
        )
    }

    // A value through a `Formatter`.

    public init<V>(_ title: String, value: Binding<V>, formatter: Formatter, _viewID: ViewID = #viewID) {
        self.init(
            label: Text(title), prompt: nil,
            source: .value(FormatterValue(value: value, formatter: formatter)), _viewID: _viewID
        )
    }

    public init<S: StringProtocol, V>(_ title: S, value: Binding<V>, formatter: Formatter, _viewID: ViewID = #viewID) {
        self.init(
            label: Text(title), prompt: nil,
            source: .value(FormatterValue(value: value, formatter: formatter)), _viewID: _viewID
        )
    }

    public init<V>(
        _ title: String,
        value: Binding<V>,
        formatter: Formatter,
        prompt: Text?,
        _viewID: ViewID = #viewID
    ) {
        self.init(
            label: Text(title), prompt: prompt,
            source: .value(FormatterValue(value: value, formatter: formatter)), _viewID: _viewID
        )
    }

    public init<S: StringProtocol, V>(
        _ title: S,
        value: Binding<V>,
        formatter: Formatter,
        prompt: Text?,
        _viewID: ViewID = #viewID
    ) {
        self.init(
            label: Text(title), prompt: prompt,
            source: .value(FormatterValue(value: value, formatter: formatter)), _viewID: _viewID
        )
    }

    public init<V>(
        _ title: String,
        value: Binding<V>,
        formatter: Formatter,
        onEditingChanged: @escaping (Bool) -> Void,
        onCommit: @escaping () -> Void,
        _viewID: ViewID = #viewID
    ) {
        self.init(
            label: Text(title), prompt: nil,
            source: .value(FormatterValue(value: value, formatter: formatter)),
            onEditingChanged: onEditingChanged, onCommit: onCommit, _viewID: _viewID
        )
    }

    public init<V>(
        _ title: String,
        value: Binding<V>,
        formatter: Formatter,
        onEditingChanged: @escaping (Bool) -> Void,
        _viewID: ViewID = #viewID
    ) {
        self.init(
            label: Text(title), prompt: nil,
            source: .value(FormatterValue(value: value, formatter: formatter)),
            onEditingChanged: onEditingChanged, _viewID: _viewID
        )
    }

    public init<V>(
        _ title: String,
        value: Binding<V>,
        formatter: Formatter,
        onCommit: @escaping () -> Void,
        _viewID: ViewID = #viewID
    ) {
        self.init(
            label: Text(title), prompt: nil,
            source: .value(FormatterValue(value: value, formatter: formatter)),
            onCommit: onCommit, _viewID: _viewID
        )
    }

    public init<S: StringProtocol, V>(
        _ title: S,
        value: Binding<V>,
        formatter: Formatter,
        onEditingChanged: @escaping (Bool) -> Void,
        onCommit: @escaping () -> Void,
        _viewID: ViewID = #viewID
    ) {
        self.init(
            label: Text(title), prompt: nil,
            source: .value(FormatterValue(value: value, formatter: formatter)),
            onEditingChanged: onEditingChanged, onCommit: onCommit, _viewID: _viewID
        )
    }

    public init<S: StringProtocol, V>(
        _ title: S,
        value: Binding<V>,
        formatter: Formatter,
        onEditingChanged: @escaping (Bool) -> Void,
        _viewID: ViewID = #viewID
    ) {
        self.init(
            label: Text(title), prompt: nil,
            source: .value(FormatterValue(value: value, formatter: formatter)),
            onEditingChanged: onEditingChanged, _viewID: _viewID
        )
    }

    public init<S: StringProtocol, V>(
        _ title: S,
        value: Binding<V>,
        formatter: Formatter,
        onCommit: @escaping () -> Void,
        _viewID: ViewID = #viewID
    ) {
        self.init(
            label: Text(title), prompt: nil,
            source: .value(FormatterValue(value: value, formatter: formatter)),
            onCommit: onCommit, _viewID: _viewID
        )
    }
}

/// Where the caret and the other end of the selection are, as character
/// offsets into the text, and whether the field has the keys.
struct TextEditing: Equatable {
    var caret = 0
    var anchor = 0
    var isFocused = false
}

/// The field's scroll offset, in points — how far the text has been moved
/// left to keep the caret in view.
@MainActor
final class TextFieldScroll {
    var offset: Double = 0
}

// MARK: - Sources

/// What a text field edits: a string, or a value through a format.
enum TextFieldSource: ViewInput {
    case text(Binding<String>)
    case value(TextFieldValue)

    func _isEquivalent(to other: TextFieldSource) -> Bool {
        switch (self, other) {
        case let (.text(mine), .text(theirs)): mine._isEquivalent(to: theirs)
        case let (.value(mine), .value(theirs)): mine.isEquivalent(to: theirs)
        default: false
        }
    }
}

/// A value a text field edits through its text: shown formatted, and
/// updated from the text whenever it parses. One concrete type whatever
/// the value's, the value and its format in a subclass that knows theirs.
@MainActor
class TextFieldValue {
    func formatted() -> String {
        fatalError("TextFieldValue is abstract")
    }

    func update(from text: String) {
        fatalError("TextFieldValue is abstract")
    }

    /// The same binding through an equal format.
    func isEquivalent(to other: TextFieldValue) -> Bool {
        fatalError("TextFieldValue is abstract")
    }
}

final class FormatStyleValue<F: ParseableFormatStyle>: TextFieldValue where F.FormatOutput == String {
    let value: Binding<F.FormatInput>
    let format: F

    init(value: Binding<F.FormatInput>, format: F) {
        self.value = value
        self.format = format
    }

    override func formatted() -> String {
        format.format(value.wrappedValue)
    }

    /// Text that doesn't parse leaves the value as it was.
    override func update(from text: String) {
        guard let parsed = try? format.parseStrategy.parse(text) else { return }
        value.wrappedValue = parsed
    }

    override func isEquivalent(to other: TextFieldValue) -> Bool {
        guard let other = other as? FormatStyleValue<F> else { return false }
        return value._isEquivalent(to: other.value) && format == other.format
    }
}

final class OptionalFormatStyleValue<F: ParseableFormatStyle>: TextFieldValue where F.FormatOutput == String {
    let value: Binding<F.FormatInput?>
    let format: F

    init(value: Binding<F.FormatInput?>, format: F) {
        self.value = value
        self.format = format
    }

    override func formatted() -> String {
        value.wrappedValue.map { format.format($0) } ?? ""
    }

    /// Text that doesn't parse — or no text — makes the value `nil`.
    override func update(from text: String) {
        value.wrappedValue = try? format.parseStrategy.parse(text)
    }

    override func isEquivalent(to other: TextFieldValue) -> Bool {
        guard let other = other as? OptionalFormatStyleValue<F> else { return false }
        return value._isEquivalent(to: other.value) && format == other.format
    }
}

final class FormatterValue<V>: TextFieldValue {
    let value: Binding<V>
    let formatter: Formatter

    init(value: Binding<V>, formatter: Formatter) {
        self.value = value
        self.formatter = formatter
    }

    override func formatted() -> String {
        formatter.string(for: value.wrappedValue) ?? ""
    }

    /// Text the formatter can't parse into a `V` leaves the value as it was.
    override func update(from text: String) {
        var object: AnyObject?
        guard formatter.getObjectValue(&object, for: text, errorDescription: nil),
              let parsed = object as? V else { return }
        value.wrappedValue = parsed
    }

    /// A formatter is an object: the same one, not an equal one.
    override func isEquivalent(to other: TextFieldValue) -> Bool {
        guard let other = other as? FormatterValue<V> else { return false }
        return value._isEquivalent(to: other.value) && formatter === other.formatter
    }
}

// MARK: - Submit

/// Which submissions an `.onSubmit` action runs for — SwiftUI's
/// `SubmitTriggers`. `.text` is a text field's Return; `.search` is kept
/// for source compatibility and never fires here.
public struct SubmitTriggers: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let text = SubmitTriggers(rawValue: 1 << 0)
    public static let search = SubmitTriggers(rawValue: 1 << 1)
}

/// One `.onSubmit` action.
struct SubmitAction {
    let triggers: SubmitTriggers
    let perform: @MainActor () -> Void
}

private struct SubmitActionsKey: EnvironmentKey {
    static let defaultValue: [SubmitAction] = []
}

extension EnvironmentValues {
    /// Every `.onSubmit` action above this point, outermost first.
    var submitActions: [SubmitAction] {
        get { self[SubmitActionsKey.self] }
        set { self[SubmitActionsKey.self] = newValue }
    }
}

extension View {
    /// Runs `action` when a text field inside this view is submitted — its
    /// Return pressed. Actions set further out run too, outermost first.
    public func onSubmit(of triggers: SubmitTriggers = .text, _ action: @escaping @MainActor () -> Void) -> some View {
        _ModifierView(
            content: self,
            key: nil,
            environment: { $0.submitActions.append(SubmitAction(triggers: triggers, perform: action)) },
            node: { context in EnvironmentContent(colorScheme: context.environment.colorScheme) }
        )
    }
}

// MARK: - Pasteboard

enum TextFieldPasteboard {
    @MainActor
    static func read() -> String? {
        #if os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #else
        return nil
        #endif
    }

    @MainActor
    static func write(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

// MARK: - The line

/// The text, selection and caret of a `TextField`: one line, scrolled so the
/// caret stays in view, cut to the field. A leaf, because where the caret
/// ends up on screen — and so how far to scroll — is only known once the
/// field has its frame.
@View
struct TextFieldLine {
    let text: String
    let font: Font
    let color: Color
    let selectionColor: Color
    let caret: Int
    let anchor: Int
    let showsCaret: Bool
    let scroll: TextFieldScroll
    /// Space between the field's edge and its text, each side.
    let inset: Double
    let isEnabled: Bool
    /// The editing commands the field takes, for the Edit menu.
    let editCommands: Set<EditCommand>
    let onFocusChange: @MainActor (Bool) -> Void
    let onKeyDown: @MainActor (KeyEvent) -> Void
    let onEditCommand: @MainActor (EditCommand) -> Void
    /// A press at a character offset; `true` extends the selection (⇧).
    let onPress: @MainActor (Int, Bool) -> Void
    let onDrag: @MainActor (Int) -> Void

    var body: Never { bodyUnavailable() }
}

extension TextFieldLine: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let text = self.text
        let font = self.font
        let scroll = self.scroll
        let inset = self.inset
        let onPress = self.onPress
        let onDrag = self.onDrag
        /// The character offset under `x` (the field's own space): the
        /// boundary nearest to it.
        let index: @MainActor (Double) -> Int = { x in
            let target = x - inset + scroll.offset
            var previous = 0.0
            var offset = 0
            for character in text {
                let next = previous + TextMeasurer.width(of: String(character), font: font)
                if target < (previous + next) / 2 { return offset }
                previous = next
                offset += 1
            }
            return offset
        }
        return ViewNode(content: TextFieldLineContent(
            text: text,
            font: font,
            color: color,
            selectionColor: selectionColor,
            caret: caret,
            anchor: anchor,
            showsCaret: showsCaret,
            scroll: scroll,
            inset: inset,
            focus: FocusTarget(
                path: context.path,
                isEnabled: isEnabled,
                onFocusChange: onFocusChange,
                onKeyDown: onKeyDown,
                editCommands: editCommands,
                onEditCommand: onEditCommand,
                isTabStop: true
            ),
            hitTarget: HitTarget(
                isEnabled: isEnabled,
                minimumDragDistance: 0,
                onPress: { point in
                    onPress(index(point.x), TextFieldLine.shiftHeld)
                },
                onDragChanged: { value in onDrag(index(value.location.x)) }
            )
        ))
    }

    /// Whether ⇧ is down now — a press has no modifiers of its own.
    @MainActor
    static var shiftHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }
}

struct TextFieldLineContent: NodeContent {
    let text: String
    let font: Font
    let color: Color
    let selectionColor: Color
    let caret: Int
    let anchor: Int
    let showsCaret: Bool
    let scroll: TextFieldScroll
    let inset: Double
    let focus: FocusTarget
    let hitTarget: HitTarget?

    var focusTarget: FocusTarget? { focus }

    /// One line tall; as wide as offered, or as the text when nothing is.
    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        let lineHeight = TextMeasurer.lineMetrics(for: font).lineHeight
        let natural = TextMeasurer.width(of: text, font: font) + 2 * inset
        return Size(width: proposal.width ?? max(80, natural), height: lineHeight + 8)
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        let lineHeight = TextMeasurer.lineMetrics(for: font).lineHeight
        let visibleWidth = max(0, rect.width - 2 * inset)
        let characters = Array(text)
        func x(_ index: Int) -> Double {
            TextMeasurer.width(of: String(characters.prefix(index)), font: font)
        }
        let textWidth = x(characters.count)
        let caretX = x(caret)

        // Scroll just enough to keep the caret in view, and never past the
        // end of the text.
        var offset = scroll.offset
        if caretX - offset > visibleWidth - 1 { offset = caretX - visibleWidth + 1 }
        if caretX - offset < 0 { offset = caretX }
        offset = max(0, min(offset, max(0, textWidth - visibleWidth + 1)))
        scroll.offset = offset

        let lineRect = Rect(
            x: rect.minX + inset,
            y: rect.minY + (rect.height - lineHeight) / 2,
            width: visibleWidth,
            height: lineHeight
        )
        let clip = context.clip.map { lineRect.intersection($0) } ?? lineRect
        let originX = lineRect.minX - offset

        if caret != anchor {
            let from = x(min(caret, anchor)), to = x(max(caret, anchor))
            var path = Path()
            path.addRect(Rect(x: originX + from, y: lineRect.minY, width: to - from, height: lineHeight))
            list.append(.shape(ShapeDraw(
                path: path,
                bounds: lineRect,
                fill: context.resolve(.color(selectionColor)),
                transform: context.transform,
                clip: clip
            )))
        }
        if !text.isEmpty {
            list.append(.text(TextDraw(
                string: text,
                frame: Rect(x: originX, y: lineRect.minY, width: textWidth + 1, height: lineHeight),
                font: font,
                color: context.resolve(color),
                lineLimit: 1,
                wraps: false,
                transform: context.transform,
                clip: clip
            )))
        }
        if showsCaret {
            var path = Path()
            path.addRect(Rect(x: originX + caretX, y: lineRect.minY, width: 1.5, height: lineHeight))
            list.append(.shape(ShapeDraw(
                path: path,
                bounds: lineRect,
                fill: context.resolve(.color(color)),
                transform: context.transform,
                clip: clip.insetBy(-1)
            )))
        }
    }
}
