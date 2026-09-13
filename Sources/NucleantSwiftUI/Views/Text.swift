//
//  Text.swift
//  NucleantSwiftUI
//

/// A view that displays one or more lines of text.
///
/// ```swift
/// Text("Hello, World!")
///     .font(.title)
///     .foregroundColor(.white)
/// ```
@View
public struct Text: View {
    public let content: String

    /// Set by `.font(_:)` on the `Text` itself; `nil` inherits from the
    /// environment, which is what `.font(_:)` applied further up sets.
    var explicitFont: Font?
    var explicitColor: Color?
    var explicitWeight: FontWeight?
    var isItalic = false
    var alignment: TextAlignment?
    var explicitLineLimit: Int??

    public init(_ content: String) {
        self.content = content
    }

    public init<S: StringProtocol>(_ content: S) {
        self.content = String(content)
    }

    public var body: Never { bodyUnavailable() }
}

extension Text {
    public func font(_ font: Font) -> Text {
        var copy = self
        copy.explicitFont = font
        return copy
    }

    public func foregroundColor(_ color: Color) -> Text {
        var copy = self
        copy.explicitColor = color
        return copy
    }

    public func fontWeight(_ weight: FontWeight) -> Text {
        var copy = self
        copy.explicitWeight = weight
        return copy
    }

    public func bold() -> Text { fontWeight(.bold) }

    public func italic() -> Text {
        var copy = self
        copy.isItalic = true
        return copy
    }

    public func multilineTextAlignment(_ alignment: TextAlignment) -> Text {
        var copy = self
        copy.alignment = alignment
        return copy
    }

    public func lineLimit(_ limit: Int?) -> Text {
        var copy = self
        copy.explicitLineLimit = .some(limit)
        return copy
    }
}

extension Text: @preconcurrency ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}

extension Text: ExpressibleByStringInterpolation {}

extension Text: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        var font = explicitFont ?? context.environment.font
        if let explicitWeight { font.weight = explicitWeight }
        if isItalic { font.isItalic = true }

        return ViewNode(content: TextContent(
            string: content,
            font: font,
            color: explicitColor ?? context.environment.foregroundColor,
            alignment: alignment ?? context.environment.multilineTextAlignment,
            lineLimit: explicitLineLimit ?? context.environment.lineLimit
        ))
    }
}
