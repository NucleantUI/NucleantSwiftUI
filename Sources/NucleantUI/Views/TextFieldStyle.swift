//
//  TextFieldStyle.swift
//  NucleantUI
//
//  How text fields and secure fields look: `.textFieldStyle(_:)` and the
//  four styles SwiftUI has.
//

/// The appearance of the text fields and secure fields in a subtree.
///
/// ```swift
/// Form {
///     TextField("Name", text: $name)
///     SecureField("Password", text: $password)
/// }
/// .textFieldStyle(.squareBorder)
/// ```
///
/// As in SwiftUI, the styles are the ones listed here; the protocol's one
/// requirement is underscored, as SwiftUI's `_body` is, and not meant to be
/// implemented outside the framework.
@MainActor
public protocol TextFieldStyle {
    var _decoration: _TextFieldDecoration { get }
}

/// What a field draws around its text — the part of a `TextFieldStyle`
/// the fields read.
public enum _TextFieldDecoration: Hashable, Sendable {
    case roundedBorder
    case squareBorder
    case plain
}

/// The default style: here, `.roundedBorder`.
public struct DefaultTextFieldStyle: TextFieldStyle {
    public init() {}
    public var _decoration: _TextFieldDecoration { .roundedBorder }
}

/// A rounded background with a border, which turns the tint colour while
/// the field has the keys.
public struct RoundedBorderTextFieldStyle: TextFieldStyle {
    public init() {}
    public var _decoration: _TextFieldDecoration { .roundedBorder }
}

/// A square-cornered background with a border.
public struct SquareBorderTextFieldStyle: TextFieldStyle {
    public init() {}
    public var _decoration: _TextFieldDecoration { .squareBorder }
}

/// No decoration: the text alone, with no background, border or inset.
public struct PlainTextFieldStyle: TextFieldStyle {
    public init() {}
    public var _decoration: _TextFieldDecoration { .plain }
}

extension TextFieldStyle where Self == DefaultTextFieldStyle {
    public static var automatic: DefaultTextFieldStyle { DefaultTextFieldStyle() }
}

extension TextFieldStyle where Self == RoundedBorderTextFieldStyle {
    public static var roundedBorder: RoundedBorderTextFieldStyle { RoundedBorderTextFieldStyle() }
}

extension TextFieldStyle where Self == SquareBorderTextFieldStyle {
    public static var squareBorder: SquareBorderTextFieldStyle { SquareBorderTextFieldStyle() }
}

extension TextFieldStyle where Self == PlainTextFieldStyle {
    public static var plain: PlainTextFieldStyle { PlainTextFieldStyle() }
}

private struct TextFieldDecorationKey: EnvironmentKey {
    static let defaultValue = _TextFieldDecoration.roundedBorder
}

extension EnvironmentValues {
    /// How the text fields in this subtree are decorated.
    var textFieldDecoration: _TextFieldDecoration {
        get { self[TextFieldDecorationKey.self] }
        set { self[TextFieldDecorationKey.self] = newValue }
    }
}

extension View {
    /// Sets the style for text fields and secure fields within this view.
    public func textFieldStyle<S: TextFieldStyle>(_ style: S) -> some View {
        environment(\.textFieldDecoration, style._decoration)
    }
}

extension _TextFieldDecoration {
    /// Space between a field's edge and its text, each side.
    var inset: Double {
        self == .plain ? 0 : 6
    }
}

// MARK: - Chrome

/// A field's text area, with the placeholder over it while the text is
/// empty and the style's background and border around it.
@View
struct TextFieldChrome<Content: View, Placeholder: View> {
    let decoration: _TextFieldDecoration
    let isFocused: Bool
    let isEmpty: Bool
    /// Where the placeholder sits: `.leading` for one line, `.topLeading`
    /// for a field that grows downwards.
    let placeholderAlignment: Alignment
    /// How far down the placeholder's line starts, to sit on the text's first line.
    let placeholderTopInset: Double
    let content: Content
    let placeholder: Placeholder

    @Environment(\.tint) private var tint
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let decorated = content
            .overlay(alignment: placeholderAlignment) {
                if isEmpty {
                    placeholder
                        .foregroundColor(.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, decoration.inset)
                        .padding(.top, placeholderTopInset)
                }
            }
        switch decoration {
        case .roundedBorder:
            decorated
                .background(RoundedRectangle(cornerRadius: 6).fill(.color(.secondaryBackground)))
                .border(isFocused ? tint : .separator, width: isFocused ? 2 : 1, cornerRadius: 6)
                .opacity(isEnabled ? 1 : 0.5)
        case .squareBorder:
            decorated
                .background(Rectangle().fill(.color(.secondaryBackground)))
                .border(isFocused ? tint : .separator, width: isFocused ? 2 : 1)
                .opacity(isEnabled ? 1 : 0.5)
        case .plain:
            decorated
                .opacity(isEnabled ? 1 : 0.5)
        }
    }
}
