//
//  TextEditor.swift
//  NucleantUI
//

/// A view that displays and edits long-form text.
///
/// ```swift
/// TextEditor(text: $note.body)
///     .font(.system(size: 14))
///     .foregroundColor(.secondary)
///
/// TextEditor(text: $draft, selection: $selection)
/// ```
///
/// It takes the space it is offered. The text wraps to its width at word
/// boundaries and scrolls, with the wheel and to keep the caret in view.
/// Pressing it — or Tab from a field before it — gives it the keys: typing
/// inserts at the caret, Return starts a new line and Tab inserts a tab
/// (⌃Tab moves on to the next field); ←/→ move by character, ⌥ by word, ⌘
/// to the ends of the line; ↑/↓ move by line, ⌥ by paragraph, ⌘ to the ends
/// of the text; ⇧ selects; a double press selects a word and a triple a
/// paragraph; ⌘A/⌘C/⌘X/⌘V and ⌘Z/⇧⌘Z work as in any editor.
///
/// Its font and colour are the environment's; `.textEditorStyle(_:)` decides
/// what is drawn around it.
@View
public struct TextEditor {
    @Binding var text: String
    let selection: TextSelectionSource

    public init(text: Binding<String>, _viewID: ViewID = #viewID) {
        self._text = text
        self.selection = TextSelectionSource(binding: nil)
        self._viewID = _viewID
    }

    /// An editor that also reads and sets which part of the text is selected.
    public init(text: Binding<String>, selection: Binding<TextSelection?>, _viewID: ViewID = #viewID) {
        self._text = text
        self.selection = TextSelectionSource(binding: selection)
        self._viewID = _viewID
    }

    public var body: some View {
        let text = $text
        let selection = self.selection
        _StyledTextEditor(configuration: TextEditorStyleConfiguration { inset, context in
            buildNode(
                MultilineTextArea(
                    text: text,
                    selection: selection,
                    mode: .editor,
                    horizontalInset: inset,
                    verticalInset: inset
                ),
                &context
            )
        })
    }
}

// MARK: - Styles

/// The appearance of the text editors in a subtree.
///
/// ```swift
/// TextEditor(text: $notes)
///     .textEditorStyle(.plain)
/// ```
///
/// As in SwiftUI, the configuration a style is handed carries nothing it can
/// place: the framework's styles, `.automatic` and `.plain`, are the ones
/// that draw an editor.
@MainActor
public protocol TextEditorStyle {
    associatedtype Body: View

    @ViewBuilder func makeBody(configuration: Configuration) -> Body

    typealias Configuration = TextEditorStyleConfiguration
}

/// The properties of a text editor, handed to its style.
@MainActor
public struct TextEditorStyleConfiguration {
    /// Builds the editing area with `inset` points around its text.
    let build: @MainActor (Double, inout BuildContext) -> ViewNode

    init(build: @escaping @MainActor (Double, inout BuildContext) -> ViewNode) {
        self.build = build
    }

    /// The editing area itself, as a framework style places it.
    func editor(inset: Double) -> _TextEditorArea {
        _TextEditorArea(configuration: self, inset: inset)
    }
}

/// A text editor's editing area, with no decoration of its own.
@View
public struct _TextEditorArea {
    let configuration: TextEditorStyleConfiguration
    let inset: Double

    public var body: Never { bodyUnavailable() }
}

extension _TextEditorArea: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        configuration.build(inset, &context)
    }
}

/// The default style: the text on the secondary background, inside a
/// hairline border.
public struct AutomaticTextEditorStyle: TextEditorStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.editor(inset: 5)
            .background(Rectangle().fill(.color(.secondaryBackground)))
            .border(.separator)
    }
}

/// No decoration: the text alone, right up to the editor's edges.
public struct PlainTextEditorStyle: TextEditorStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.editor(inset: 0)
    }
}

extension TextEditorStyle where Self == AutomaticTextEditorStyle {
    public static var automatic: AutomaticTextEditorStyle { AutomaticTextEditorStyle() }
}

extension TextEditorStyle where Self == PlainTextEditorStyle {
    public static var plain: PlainTextEditorStyle { PlainTextEditorStyle() }
}

/// An editor's body. The style is only known from the environment at build
/// time, so it is chosen there — the one `.textEditorStyle(_:)` set, or
/// `.automatic`.
@View
struct _StyledTextEditor {
    let configuration: TextEditorStyleConfiguration

    init(configuration: TextEditorStyleConfiguration, _viewID: ViewID = #viewID) {
        self.configuration = configuration
        self._viewID = _viewID
    }

    var body: Never { bodyUnavailable() }
}

extension _StyledTextEditor: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        if let style = context.environment.textEditorStyle {
            return style.storage.makeNode(configuration, &context)
        }
        return buildNode(AutomaticTextEditorStyle().makeBody(configuration: configuration), &context)
    }
}

/// The style `.textEditorStyle(_:)` set, as the environment holds it: one
/// concrete type whatever the style, the style itself in a subclass that
/// knows its type.
struct TextEditorStyleBox: ViewInput {
    let storage: TextEditorStyleStorage

    init<S: TextEditorStyle>(_ style: S) {
        self.storage = TypedTextEditorStyleStorage(style)
    }

    /// Same style type, equivalent values — re-applying the same style is
    /// not an environment change.
    func _isEquivalent(to other: TextEditorStyleBox) -> Bool {
        storage.isEquivalent(to: other.storage)
    }
}

@MainActor
class TextEditorStyleStorage {
    func makeNode(_ configuration: TextEditorStyleConfiguration, _ context: inout BuildContext) -> ViewNode {
        fatalError("TextEditorStyleStorage is abstract")
    }

    func isEquivalent(to other: TextEditorStyleStorage) -> Bool {
        fatalError("TextEditorStyleStorage is abstract")
    }
}

final class TypedTextEditorStyleStorage<S: TextEditorStyle>: TextEditorStyleStorage {
    let style: S

    init(_ style: S) {
        self.style = style
    }

    override func makeNode(_ configuration: TextEditorStyleConfiguration, _ context: inout BuildContext) -> ViewNode {
        buildNode(style.makeBody(configuration: configuration), &context)
    }

    override func isEquivalent(to other: TextEditorStyleStorage) -> Bool {
        guard let other = other as? TypedTextEditorStyleStorage<S> else { return false }
        return _areEquivalent(style, other.style)
    }
}

/// `nil` is `.automatic`.
private struct TextEditorStyleKey: EnvironmentKey {
    static var defaultValue: TextEditorStyleBox? { nil }
}

extension EnvironmentValues {
    /// The style `TextEditor`s in this subtree draw with.
    var textEditorStyle: TextEditorStyleBox? {
        get { self[TextEditorStyleKey.self] }
        set { self[TextEditorStyleKey.self] = newValue }
    }
}

extension View {
    /// Sets the style for text editors within this view.
    public func textEditorStyle<S: TextEditorStyle>(_ style: S) -> some View {
        environment(\.textEditorStyle, TextEditorStyleBox(style))
    }
}
