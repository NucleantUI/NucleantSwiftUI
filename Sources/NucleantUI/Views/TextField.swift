//
//  TextField.swift
//  NucleantUI
//
//  A single-line editable text field, and `.onSubmit`.
//

#if os(macOS)
import AppKit
#endif

/// A control that displays an editable line of text.
///
/// ```swift
/// TextField("Address", text: $address)
///     .onSubmit { page.load(address) }
/// ```
///
/// Pressing it gives it the keys: typing inserts at the caret, ⌫/⌦ delete,
/// ←/→ move (⌥ by word, ⌘ to the ends, ⇧ to select), ⌘A selects all, ⌘C/⌘X/⌘V
/// copy, cut and paste, and Return runs the `.onSubmit` actions around it.
/// Pressing anywhere else takes the keys away. Text wider than the field
/// scrolls to keep the caret in view.
///
/// The label is the placeholder, shown while the text is empty.
@View
public struct TextField<Label: View> {
    let label: Label
    @Binding var text: String

    @Environment(\.font) private var font
    @Environment(\.foregroundColor) private var foreground
    @Environment(\.tint) private var tint
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.submitActions) private var submitActions

    /// Caret, selection anchor and focus — the field's own transient state.
    @State private var editing = TextEditing()
    /// How far the text is scrolled, kept across placements; written while
    /// the field is placed, so a reference the placement can reach.
    @State private var scroll = TextFieldScroll()

    public init(text: Binding<String>, @ViewBuilder label: () -> Label, _viewID: ViewID = #viewID) {
        self._text = text
        self.label = label()
        self._viewID = _viewID
    }

    public var body: some View {
        let count = text.count
        let caret = min(editing.caret, count)
        let anchor = min(editing.anchor, count)
        TextFieldLine(
            text: text,
            font: font,
            color: foreground,
            selectionColor: tint.opacity(editing.isFocused ? 0.3 : 0.15),
            caret: caret,
            anchor: anchor,
            showsCaret: editing.isFocused,
            scroll: scroll,
            isEnabled: isEnabled,
            onFocusChange: { focused in editing.isFocused = focused },
            onKeyDown: { key in handle(key) },
            onEditCommand: { command in perform(command) },
            onPress: { index, extending in
                editing.caret = index
                if !extending { editing.anchor = index }
            },
            onDrag: { index in editing.caret = index }
        )
        .overlay(alignment: .leading) {
            if text.isEmpty {
                label
                    .foregroundColor(.tertiary)
                    .lineLimit(1)
                    .padding(.horizontal, TextFieldLine.inset)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(.color(.secondaryBackground)))
        .border(
            editing.isFocused ? tint : .separator,
            width: editing.isFocused ? 2 : 1,
            cornerRadius: 6
        )
        .opacity(isEnabled ? 1 : 0.5)
    }

    // MARK: - Editing

    private func handle(_ key: KeyEvent) {
        var characters = Array(text)
        var caret = min(editing.caret, characters.count)
        var anchor = min(editing.anchor, characters.count)
        let lower = min(caret, anchor)
        let upper = max(caret, anchor)
        let command = key.modifiers.contains(.command)
        let option = key.modifiers.contains(.option)
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
            for action in submitActions where action.triggers.contains(.text) {
                action.perform()
            }
            return
        case 0x33:  // delete (backspace)
            if lower != upper {
                replaceSelection(with: [])
            } else if caret > 0 {
                let start = command ? 0 : option ? Self.wordStart(in: characters, before: caret) : caret - 1
                characters.removeSubrange(start..<caret)
                caret = start
                anchor = caret
            }
        case 0x75:  // forward delete
            if lower != upper {
                replaceSelection(with: [])
            } else if caret < characters.count {
                let end = command ? characters.count
                    : option ? Self.wordEnd(in: characters, after: caret) : caret + 1
                characters.removeSubrange(caret..<end)
                anchor = caret
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
                default: break
                }
                return
            } else {
                guard !key.modifiers.contains(.control), let typed = key.characters else { return }
                // Not the function keys (arrows, F-keys report characters in
                // the private-use range U+F700–U+F8FF on macOS) or controls.
                let printable = typed.filter { character in
                    character.unicodeScalars.allSatisfy { scalar in
                        scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
                    }
                }
                guard !printable.isEmpty else { return }
                replaceSelection(with: Array(printable))
            }
        }

        let edited = String(characters)
        if edited != text { text = edited }
        if editing.caret != caret { editing.caret = caret }
        if editing.anchor != anchor { editing.anchor = anchor }
    }

    /// The editing commands a text field takes — undo has no history to
    /// work from here, so it is left to the rest of the app.
    static var editCommands: Set<EditCommand> { [.cut, .copy, .paste, .selectAll] }

    /// An editing command, from the Edit menu or its ⌘-key.
    private func perform(_ command: EditCommand) {
        var characters = Array(text)
        let caret = min(editing.caret, characters.count)
        let anchor = min(editing.anchor, characters.count)
        let lower = min(caret, anchor)
        let upper = max(caret, anchor)

        func replaceSelection(with inserted: [Character]) {
            characters.replaceSubrange(lower..<upper, with: inserted)
            text = String(characters)
            editing.caret = lower + inserted.count
            editing.anchor = editing.caret
        }

        switch command {
        case .selectAll:
            editing.anchor = 0
            editing.caret = characters.count
        case .copy:
            if lower != upper { TextFieldPasteboard.write(String(characters[lower..<upper])) }
        case .cut:
            if lower != upper {
                TextFieldPasteboard.write(String(characters[lower..<upper]))
                replaceSelection(with: [])
            }
        case .paste:
            if let pasted = TextFieldPasteboard.read() {
                // One line: a pasted newline would end the field's only line.
                replaceSelection(with: Array(pasted.filter { !$0.isNewline }))
            }
        case .undo, .redo:
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

extension TextField where Label == Text {
    @MainActor
    public init(_ title: String, text: Binding<String>, _viewID: ViewID = #viewID) {
        self.init(text: text, label: { Text(title) }, _viewID: _viewID)
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
    /// Space between the field's edge and its text, each side.
    static var inset: Double { 6 }

    let text: String
    let font: Font
    let color: Color
    let selectionColor: Color
    let caret: Int
    let anchor: Int
    let showsCaret: Bool
    let scroll: TextFieldScroll
    let isEnabled: Bool
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
        let onPress = self.onPress
        let onDrag = self.onDrag
        /// The character offset under `x` (the field's own space): the
        /// boundary nearest to it.
        let index: @MainActor (Double) -> Int = { x in
            let target = x - TextFieldLine.inset + scroll.offset
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
            focus: FocusTarget(
                path: context.path,
                isEnabled: isEnabled,
                onFocusChange: onFocusChange,
                onKeyDown: onKeyDown,
                editCommands: TextField<Text>.editCommands,
                onEditCommand: onEditCommand
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
    let focus: FocusTarget
    let hitTarget: HitTarget?

    var focusTarget: FocusTarget? { focus }

    /// One line tall; as wide as offered, or as the text when nothing is.
    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        let lineHeight = TextMeasurer.lineMetrics(for: font).lineHeight
        let natural = TextMeasurer.width(of: text, font: font) + 2 * TextFieldLine.inset
        return Size(width: proposal.width ?? max(80, natural), height: lineHeight + 8)
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        let lineHeight = TextMeasurer.lineMetrics(for: font).lineHeight
        let inset = TextFieldLine.inset
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
