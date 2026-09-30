//
//  SecureField.swift
//  NucleantUI
//

/// A control into which people securely enter private text, such as a
/// password.
///
/// ```swift
/// SecureField("Password", text: $password)
///     .onSubmit { session.signIn() }
/// ```
///
/// It edits like a single-line `TextField`, with every character shown as
/// a bullet. What it holds can be pasted over but not copied or cut out,
/// no undo history of it is kept, and ⌥-arrows and a double press go to the
/// ends rather than to word boundaries, which would give its shape away.
/// Return runs the `.onSubmit` actions around it, and `.textFieldStyle(_:)`
/// decides how it is drawn.
@View
public struct SecureField<Label: View> {
    let label: Label
    let prompt: Text?
    @Binding var text: String
    let onCommit: (() -> Void)?

    @Environment(\.font) private var font
    @Environment(\.foregroundColor) private var foreground
    @Environment(\.tint) private var tint
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.submitActions) private var submitActions
    @Environment(\.textFieldDecoration) private var decoration

    /// Caret, selection anchor and focus — the field's own transient state.
    @State private var editing = TextEditing()
    @State private var scroll = TextFieldScroll()
    @State private var clicks = TextClickCounter()

    init(label: Label, prompt: Text?, text: Binding<String>, onCommit: (() -> Void)? = nil, _viewID: ViewID) {
        self.label = label
        self.prompt = prompt
        self._text = text
        self.onCommit = onCommit
        self._viewID = _viewID
    }

    /// What is drawn for each character.
    private static var bullet: Character { "\u{2022}" }

    public var body: some View {
        let count = text.count
        TextFieldChrome(
            decoration: decoration,
            isFocused: editing.isFocused,
            isEmpty: count == 0,
            placeholderAlignment: .leading,
            placeholderTopInset: 0,
            content: TextFieldLine(
                text: String(repeating: Self.bullet, count: count),
                font: font,
                color: foreground,
                selectionColor: tint.opacity(editing.isFocused ? 0.3 : 0.15),
                caret: min(editing.caret, count),
                anchor: min(editing.anchor, count),
                showsCaret: editing.isFocused,
                scroll: scroll,
                inset: decoration.inset,
                isEnabled: isEnabled,
                editCommands: [.paste, .selectAll],
                onFocusChange: { focused in
                    editing.isFocused = focused
                    // Tabbing in selects everything; a press that gave the
                    // keys places the caret right after.
                    if focused { select(caret: text.count, anchor: 0) }
                },
                onKeyDown: { key in handle(key) },
                onEditCommand: { command in perform(command) },
                onPress: { index, extending in press(at: index, extending: extending) },
                onDrag: { index in drag(to: index) }
            ),
            placeholder: placeholder
        )
    }

    @ViewBuilder
    private var placeholder: some View {
        if let prompt {
            prompt
        } else {
            label
        }
    }

    // MARK: - Editing

    private func select(caret: Int, anchor: Int) {
        if editing.caret != caret { editing.caret = caret }
        if editing.anchor != anchor { editing.anchor = anchor }
    }

    private func handle(_ key: KeyEvent) {
        var characters = Array(text)
        var caret = min(editing.caret, characters.count)
        var anchor = min(editing.anchor, characters.count)
        let lower = min(caret, anchor)
        let upper = max(caret, anchor)
        let jumps = key.modifiers.contains(.command) || key.modifiers.contains(.option)
        let shift = key.modifiers.contains(.shift)

        func replaceSelection(with inserted: [Character]) {
            characters.replaceSubrange(lower..<upper, with: inserted)
            caret = lower + inserted.count
            anchor = caret
        }

        /// Move the caret to `target`, extending the selection with ⇧.
        func move(to target: Int) {
            caret = max(0, min(characters.count, target))
            if !shift { anchor = caret }
        }

        switch key.keyCode {
        case 0x24, 0x4C:  // return, keypad enter
            onCommit?()
            for action in submitActions where action.triggers.contains(.text) {
                action.perform()
            }
            return
        case 0x33:  // delete (backspace)
            if lower != upper {
                replaceSelection(with: [])
            } else if caret > 0 {
                let start = jumps ? 0 : caret - 1
                characters.removeSubrange(start..<caret)
                caret = start
                anchor = caret
            }
        case 0x75:  // forward delete
            if lower != upper {
                replaceSelection(with: [])
            } else if caret < characters.count {
                characters.removeSubrange(caret..<(jumps ? characters.count : caret + 1))
                anchor = caret
            }
        case 0x7B:  // left
            if jumps {
                move(to: 0)
            } else if lower != upper, !shift {
                move(to: lower)
            } else {
                move(to: caret - 1)
            }
        case 0x7C:  // right
            if jumps {
                move(to: characters.count)
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
            if key.modifiers.contains(.command) {
                // Where the Edit menu has these as key equivalents they arrive
                // as its commands instead (`perform`); this is for where not.
                switch key.characters?.lowercased() {
                case "a": perform(.selectAll)
                case "v": perform(.paste)
                default: break
                }
                return
            }
            guard !key.modifiers.contains(.control), let typed = key.characters else { return }
            let printable = printableCharacters(of: typed)
            guard !printable.isEmpty else { return }
            replaceSelection(with: Array(printable))
        }

        let edited = String(characters)
        if edited != text { text = edited }
        select(caret: caret, anchor: anchor)
    }

    /// An editing command, from the Edit menu or its ⌘-key. Only paste and
    /// select all: nothing comes out of a secure field, and it keeps no
    /// history to undo.
    private func perform(_ command: EditCommand) {
        var characters = Array(text)
        let caret = min(editing.caret, characters.count)
        let anchor = min(editing.anchor, characters.count)
        let lower = min(caret, anchor)
        let upper = max(caret, anchor)

        switch command {
        case .selectAll:
            select(caret: characters.count, anchor: 0)
        case .paste:
            guard let pasted = TextFieldPasteboard.read() else { return }
            let inserted = Array(pasted.filter { !$0.isNewline })
            characters.replaceSubrange(lower..<upper, with: inserted)
            text = String(characters)
            select(caret: lower + inserted.count, anchor: lower + inserted.count)
        case .copy, .cut, .undo, .redo:
            break
        }
    }

    /// A press at character offset `index`: places the caret, or with ⇧
    /// extends the selection to it; a double or triple press selects all.
    private func press(at index: Int, extending: Bool) {
        let count = text.count
        if clicks.press(at: index) >= 2 {
            select(caret: count, anchor: 0)
        } else {
            select(caret: index, anchor: extending ? min(editing.anchor, count) : index)
        }
    }

    private func drag(to index: Int) {
        guard clicks.count <= 1 else { return }
        editing.caret = index
    }
}

@MainActor
extension SecureField {
    /// A secure field editing `text`, with `label` as its placeholder unless
    /// a `prompt` is given.
    public init(
        text: Binding<String>,
        prompt: Text? = nil,
        _viewID: ViewID = #viewID,
        @ViewBuilder label: () -> Label
    ) {
        self.init(label: label(), prompt: prompt, text: text, _viewID: _viewID)
    }
}

@MainActor
extension SecureField where Label == Text {
    public init(_ title: String, text: Binding<String>, _viewID: ViewID = #viewID) {
        self.init(label: Text(title), prompt: nil, text: text, _viewID: _viewID)
    }

    public init<S: StringProtocol>(_ title: S, text: Binding<String>, _viewID: ViewID = #viewID) {
        self.init(label: Text(title), prompt: nil, text: text, _viewID: _viewID)
    }

    public init(_ title: String, text: Binding<String>, prompt: Text?, _viewID: ViewID = #viewID) {
        self.init(label: Text(title), prompt: prompt, text: text, _viewID: _viewID)
    }

    public init<S: StringProtocol>(_ title: S, text: Binding<String>, prompt: Text?, _viewID: ViewID = #viewID) {
        self.init(label: Text(title), prompt: prompt, text: text, _viewID: _viewID)
    }

    /// SwiftUI's older shape, with the commit as a callback; `.onSubmit` is
    /// the current one.
    public init(_ title: String, text: Binding<String>, onCommit: @escaping () -> Void, _viewID: ViewID = #viewID) {
        self.init(label: Text(title), prompt: nil, text: text, onCommit: onCommit, _viewID: _viewID)
    }

    public init<S: StringProtocol>(
        _ title: S,
        text: Binding<String>,
        onCommit: @escaping () -> Void,
        _viewID: ViewID = #viewID
    ) {
        self.init(label: Text(title), prompt: nil, text: text, onCommit: onCommit, _viewID: _viewID)
    }
}
