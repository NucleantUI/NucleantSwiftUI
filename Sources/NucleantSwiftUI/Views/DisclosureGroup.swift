//
//  DisclosureGroup.swift
//  NucleantSwiftUI
//

/// A view that shows or hides its content behind a label with a chevron.
///
/// ```swift
/// DisclosureGroup("Advanced") {           // expansion kept by the group
///     Fader(level: $gain)
/// }
///
/// DisclosureGroup(isExpanded: $showTracks) {
///     ForEach(tracks) { TrackRow($0) }
/// } label: {
///     Text("Tracks").bold()
/// }
/// ```
///
/// How it looks and toggles is the `DisclosureGroupStyle` in the
/// environment — `.automatic` unless `.disclosureGroupStyle(_:)` says
/// otherwise. The content closure is only called when the style places
/// `configuration.content`, so a collapsed group builds none of it.
@View
public struct DisclosureGroup<Label: View, Content: View>: View {

    let content: () -> Content
    let label: Label
    let isExpandedSource: ExpansionSource

    /// Expansion for a group given no binding.
    @State private var localIsExpanded = false

    public init(
        _viewID: ViewID = #viewID,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder label: () -> Label
    ) {
        self.content = content
        self.label = label()
        self.isExpandedSource = ExpansionSource(binding: nil)
        self._viewID = _viewID
    }

    public init(
        isExpanded: Binding<Bool>,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder label: () -> Label
    ) {
        self.content = content
        self.label = label()
        self.isExpandedSource = ExpansionSource(binding: isExpanded)
        self._viewID = _viewID
    }

    public var body: some View {
        let label = self.label
        let content = self.content
        _StyledDisclosureGroup(configuration: DisclosureGroupStyleConfiguration(
            label: .init { context in buildNode(label, &context) },
            content: .init { context in buildNode(content(), &context) },
            isExpanded: isExpandedSource.binding ?? $localIsExpanded
        ))
    }
}

/// The caller's expansion binding, if they passed one. A type of its own so
/// `@View`'s equivalence compares it by source, as `Binding` itself is —
/// `Optional<Binding<Bool>>` would go through `Equatable` and compare values.
struct ExpansionSource: ViewInput {
    let binding: Binding<Bool>?

    func _isEquivalent(to other: ExpansionSource) -> Bool {
        switch (binding, other.binding) {
        case (nil, nil): true
        case let (mine?, theirs?): mine._isEquivalent(to: theirs)
        default: false
        }
    }
}

extension DisclosureGroup where Label == Text {

    public init(_ label: String, _viewID: ViewID = #viewID, @ViewBuilder content: @escaping () -> Content) {
        self.init(_viewID: _viewID, content: content) { Text(label) }
    }

    public init(
        _ label: String,
        isExpanded: Binding<Bool>,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(isExpanded: isExpanded, _viewID: _viewID, content: content) { Text(label) }
    }

    public init<S: StringProtocol>(_ label: S, _viewID: ViewID = #viewID, @ViewBuilder content: @escaping () -> Content) {
        self.init(_viewID: _viewID, content: content) { Text(label) }
    }

    public init<S: StringProtocol>(
        _ label: S,
        isExpanded: Binding<Bool>,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(isExpanded: isExpanded, _viewID: _viewID, content: content) { Text(label) }
    }
}

// MARK: - Styles

/// The appearance and interaction of the disclosure groups in a subtree.
///
/// ```swift
/// struct ShowHideStyle: DisclosureGroupStyle {
///     func makeBody(configuration: Configuration) -> some View {
///         VStack(alignment: .leading) {
///             HStack {
///                 configuration.label
///                 Spacer()
///                 Text(configuration.isExpanded ? "hide" : "show")
///             }
///             .onTapGesture { configuration.isExpanded.toggle() }
///             if configuration.isExpanded {
///                 configuration.content
///             }
///         }
///     }
/// }
///
/// Settings().disclosureGroupStyle(ShowHideStyle())
/// ```
@MainActor
public protocol DisclosureGroupStyle {
    associatedtype Body: View

    @ViewBuilder func makeBody(configuration: Configuration) -> Body

    typealias Configuration = DisclosureGroupStyleConfiguration
}

/// The properties of one disclosure group, handed to its style.
///
/// The style is not generic over the group's label and content, so these
/// two carry how to build them — run when the style places them, and not
/// before.
@MainActor
public struct DisclosureGroupStyleConfiguration {

    /// The group's label.
    public struct Label: View {
        let build: @MainActor (inout BuildContext) -> ViewNode

        init(_ build: @escaping @MainActor (inout BuildContext) -> ViewNode) {
            self.build = build
        }

        public var body: Never { bodyUnavailable() }
    }

    /// The group's content. Only built if the style places it.
    public struct Content: View {
        let build: @MainActor (inout BuildContext) -> ViewNode

        init(_ build: @escaping @MainActor (inout BuildContext) -> ViewNode) {
            self.build = build
        }

        public var body: Never { bodyUnavailable() }
    }

    public let label: Label
    public let content: Content

    /// Whether the group is expanded — the caller's binding, or the group's
    /// own state when it was given none.
    @Binding public var isExpanded: Bool

    init(label: Label, content: Content, isExpanded: Binding<Bool>) {
        self.label = label
        self.content = content
        self._isExpanded = isExpanded
    }
}

extension DisclosureGroupStyleConfiguration.Label: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        build(&context)
    }
}

extension DisclosureGroupStyleConfiguration.Content: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        build(&context)
    }
}

/// The default style: a "›" before the label that turns down while open, a
/// tap anywhere on the label row to toggle, and the content indented under
/// the label.
public struct AutomaticDisclosureGroupStyle: DisclosureGroupStyle {

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _AutomaticDisclosureGroup(configuration: configuration)
    }
}

extension DisclosureGroupStyle where Self == AutomaticDisclosureGroupStyle {
    public static var automatic: AutomaticDisclosureGroupStyle { AutomaticDisclosureGroupStyle() }
}

/// `AutomaticDisclosureGroupStyle`'s body — a view of its own so it can
/// read the environment, and so a toggle rebuilds only this.
@View
struct _AutomaticDisclosureGroup: View {
    let configuration: DisclosureGroupStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let isExpanded = configuration.isExpanded
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // The same "›" `Menu` uses. A fixed width so the label does
                // not shift as it turns.
                Text("›")
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12)
                configuration.label
                Spacer()
            }
            .opacity(isEnabled ? 1 : 0.4)
            .onTapGesture { configuration.isExpanded = !isExpanded }
            if isExpanded {
                configuration.content
                    .padding(.leading, 18)
            }
        }
    }
}

/// A group's body. The style is only known from the environment at build
/// time, so it is chosen there — the one `.disclosureGroupStyle(_:)` set,
/// or `.automatic`.
@View
struct _StyledDisclosureGroup: View {
    let configuration: DisclosureGroupStyleConfiguration

    init(configuration: DisclosureGroupStyleConfiguration, _viewID: ViewID = #viewID) {
        self.configuration = configuration
        self._viewID = _viewID
    }

    var body: Never { bodyUnavailable() }
}

extension _StyledDisclosureGroup: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        if let style = context.environment.disclosureGroupStyle {
            return style.storage.makeNode(configuration, &context)
        }
        return buildNode(AutomaticDisclosureGroupStyle().makeBody(configuration: configuration), &context)
    }
}

/// The style `.disclosureGroupStyle(_:)` set, as the environment holds it:
/// one concrete type whatever the style, the style itself in a subclass
/// that knows its type.
struct DisclosureGroupStyleBox: ViewInput {
    let storage: DisclosureGroupStyleStorage

    init<S: DisclosureGroupStyle>(_ style: S) {
        self.storage = TypedDisclosureGroupStyleStorage(style)
    }

    /// Same style type, equivalent values — re-applying the same style is
    /// not an environment change.
    func _isEquivalent(to other: DisclosureGroupStyleBox) -> Bool {
        storage.isEquivalent(to: other.storage)
    }
}

@MainActor
class DisclosureGroupStyleStorage {
    func makeNode(_ configuration: DisclosureGroupStyleConfiguration, _ context: inout BuildContext) -> ViewNode {
        fatalError("DisclosureGroupStyleStorage is abstract")
    }

    func isEquivalent(to other: DisclosureGroupStyleStorage) -> Bool {
        fatalError("DisclosureGroupStyleStorage is abstract")
    }
}

final class TypedDisclosureGroupStyleStorage<S: DisclosureGroupStyle>: DisclosureGroupStyleStorage {
    let style: S

    init(_ style: S) {
        self.style = style
    }

    override func makeNode(_ configuration: DisclosureGroupStyleConfiguration, _ context: inout BuildContext) -> ViewNode {
        buildNode(style.makeBody(configuration: configuration), &context)
    }

    override func isEquivalent(to other: DisclosureGroupStyleStorage) -> Bool {
        guard let other = other as? TypedDisclosureGroupStyleStorage<S> else { return false }
        return _areEquivalent(style, other.style)
    }
}

/// `nil` is `.automatic`.
private struct DisclosureGroupStyleKey: EnvironmentKey {
    static var defaultValue: DisclosureGroupStyleBox? { nil }
}

extension EnvironmentValues {
    /// The style `DisclosureGroup`s in this subtree draw with.
    var disclosureGroupStyle: DisclosureGroupStyleBox? {
        get { self[DisclosureGroupStyleKey.self] }
        set { self[DisclosureGroupStyleKey.self] = newValue }
    }
}

extension View {
    /// Sets the style for disclosure groups within this view.
    public func disclosureGroupStyle<S: DisclosureGroupStyle>(_ style: S) -> some View {
        environment(\.disclosureGroupStyle, DisclosureGroupStyleBox(style))
    }
}
