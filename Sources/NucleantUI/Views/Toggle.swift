//
//  Toggle.swift
//  NucleantUI
//

/// A control that turns something on and off.
///
/// ```swift
/// Toggle("Loop", isOn: $isLooping)
///
/// Toggle(isOn: $track.isMuted) {
///     Text("Mute").bold()
/// }
/// .toggleStyle(.button)
/// ```
///
/// How it looks is the `ToggleStyle` in the environment: `.switch`,
/// `.checkbox`, `.button`, or one of your own. `.automatic` is a checkbox
/// on the desktop and a switch on a phone, as in SwiftUI.
@View
public struct Toggle<Label: View>: View {
    @Binding var isOn: Bool
    let label: Label

    public init(isOn: Binding<Bool>, _viewID: ViewID = #viewID, @ViewBuilder label: () -> Label) {
        self._isOn = isOn
        self.label = label()
        self._viewID = _viewID
    }

    public var body: some View {
        let label = self.label
        _StyledToggle(configuration: ToggleStyleConfiguration(
            label: .init { context in buildNode(label, &context) },
            isOn: $isOn
        ))
    }
}

extension Toggle where Label == ToggleStyleConfiguration.Label {
    /// A toggle for a style's configuration — how a style that only adjusts
    /// another one draws the toggle it was handed.
    ///
    /// ```swift
    /// struct TintedSwitch: ToggleStyle {
    ///     func makeBody(configuration: Configuration) -> some View {
    ///         Toggle(configuration).toggleStyle(.switch).tint(.green)
    ///     }
    /// }
    /// ```
    public init(_ configuration: ToggleStyleConfiguration, _viewID: ViewID = #viewID) {
        self.init(isOn: configuration.$isOn, _viewID: _viewID) { configuration.label }
    }
}

extension Toggle where Label == Text {
    public init(_ title: String, isOn: Binding<Bool>, _viewID: ViewID = #viewID) {
        self.init(isOn: isOn, _viewID: _viewID) { Text(title) }
    }

    public init<S: StringProtocol>(_ title: S, isOn: Binding<Bool>, _viewID: ViewID = #viewID) {
        self.init(isOn: isOn, _viewID: _viewID) { Text(title) }
    }
}

// MARK: - Styles

/// The appearance and interaction of the toggles in a subtree.
///
/// ```swift
/// struct PowerToggleStyle: ToggleStyle {
///     func makeBody(configuration: Configuration) -> some View {
///         HStack {
///             configuration.label
///             Spacer()
///             Circle()
///                 .fill(configuration.isOn ? .green : .gray)
///                 .frame(width: 14, height: 14)
///         }
///         .onTapGesture { configuration.isOn.toggle() }
///     }
/// }
///
/// Toggle("Power", isOn: $isPowered).toggleStyle(PowerToggleStyle())
/// ```
@MainActor
public protocol ToggleStyle {
    associatedtype Body: View

    @ViewBuilder func makeBody(configuration: Configuration) -> Body

    typealias Configuration = ToggleStyleConfiguration
}

/// The properties of one toggle, handed to its style.
@MainActor
public struct ToggleStyleConfiguration {

    /// The toggle's label. The style is not generic over the label's type,
    /// so this carries how to build it.
    @View
    public struct Label: View {
        let builder: ToggleLabelBuilder

        init(_ build: @escaping @MainActor (inout BuildContext) -> ViewNode, _viewID: ViewID = #viewID) {
            self.builder = ToggleLabelBuilder(build: build)
            self._viewID = _viewID
        }

        public var body: Never { bodyUnavailable() }
    }

    public let label: Label

    /// Whether the toggle is on.
    @Binding public var isOn: Bool

    init(label: Label, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }
}

extension ToggleStyleConfiguration.Label: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        builder.build(&context)
    }
}

/// How to build a toggle's label, in an object made fresh by every build of
/// the toggle. A closure alone would count for nothing when `@View` compares
/// two labels, and a style body would keep the label it drew last; an
/// object compares by identity, so a label is never mistaken for the last
/// one.
@MainActor
final class ToggleLabelBuilder {
    let build: @MainActor (inout BuildContext) -> ViewNode

    init(build: @escaping @MainActor (inout BuildContext) -> ViewNode) {
        self.build = build
    }
}

/// A sliding switch after the label, the label on the leading edge and the
/// switch on the trailing one.
public struct SwitchToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _SwitchToggle(configuration: configuration)
    }
}

/// A box before the label, ticked while on. The label is part of the
/// control: a press on either toggles it.
public struct CheckboxToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _CheckboxToggle(configuration: configuration)
    }
}

/// A button that stays down while on: the label on the tint while on, on
/// the plain control background while off.
public struct ButtonToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _ButtonToggle(configuration: configuration)
    }
}

/// The platform's style: a checkbox on the desktop, a switch on a phone.
public struct DefaultToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        #if os(iOS) || os(Android)
        _SwitchToggle(configuration: configuration)
        #else
        _CheckboxToggle(configuration: configuration)
        #endif
    }
}

extension ToggleStyle where Self == SwitchToggleStyle {
    public static var `switch`: SwitchToggleStyle { SwitchToggleStyle() }
}

extension ToggleStyle where Self == CheckboxToggleStyle {
    public static var checkbox: CheckboxToggleStyle { CheckboxToggleStyle() }
}

extension ToggleStyle where Self == ButtonToggleStyle {
    public static var button: ButtonToggleStyle { ButtonToggleStyle() }
}

extension ToggleStyle where Self == DefaultToggleStyle {
    public static var automatic: DefaultToggleStyle { DefaultToggleStyle() }
}

// MARK: - Style bodies

/// `SwitchToggleStyle`'s body — a view of its own so it can read the
/// environment, and so a flip rebuilds only this.
@View
struct _SwitchToggle {
    let configuration: ToggleStyleConfiguration

    @Environment(\.tint) private var tint
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.labelsHidden) private var labelsHidden

    private static var trackWidth: Double { 40 }
    private static var trackHeight: Double { 24 }
    private static var knobInset: Double { 2 }

    var body: some View {
        let isOn = configuration.isOn
        HStack(spacing: 8) {
            if !labelsHidden {
                configuration.label
                Spacer(minLength: 8)
            }
            // Only the switch flips it, as on every platform that has one.
            ZStack {
                Capsule()
                    .fill(isOn ? tint : controlTrackColor)
                Circle()
                    .fill(Color.white)
                    .frame(width: Self.trackHeight - 2 * Self.knobInset, height: Self.trackHeight - 2 * Self.knobInset)
                    .offset(x: (isOn ? 1 : -1) * (Self.trackWidth - Self.trackHeight) / 2)
            }
            .frame(width: Self.trackWidth, height: Self.trackHeight)
            .animation(.snappy(duration: 0.25), value: isOn)
            .onTapGesture { configuration.isOn = !isOn }
        }
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// `CheckboxToggleStyle`'s body.
@View
struct _CheckboxToggle {
    let configuration: ToggleStyleConfiguration

    @Environment(\.tint) private var tint
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.labelsHidden) private var labelsHidden
    @State private var isPressed = false

    var body: some View {
        let isOn = configuration.isOn
        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isOn ? tint.opacity(isPressed ? 0.7 : 1) : (isPressed ? Color.tertiaryBackground : Color.secondaryBackground))
                    .border(isOn ? Color.clear : Color.separator, width: 1, cornerRadius: 4)
                if isOn {
                    _ControlCheckmark()
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: 12, height: 12)
                }
            }
            .frame(width: 16, height: 16)
            if !labelsHidden {
                configuration.label
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
        ._hitTarget(HitTarget(
            isEnabled: isEnabled,
            onPress: { _ in isPressed = true },
            onRelease: { _, inside in
                isPressed = false
                if inside { configuration.isOn = !isOn }
            }
        ))
    }
}

/// `ButtonToggleStyle`'s body.
@View
struct _ButtonToggle {
    let configuration: ToggleStyleConfiguration

    @Environment(\.tint) private var tint
    @Environment(\.isEnabled) private var isEnabled
    @State private var isPressed = false

    var body: some View {
        let isOn = configuration.isOn
        configuration.label
            .foregroundColor(isOn ? .white : .primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isOn ? tint.opacity(isPressed ? 0.65 : 1) : (isPressed ? controlTrackColor : Color.tertiaryBackground))
            )
            .opacity(isEnabled ? 1 : 0.4)
            ._hitTarget(HitTarget(
                isEnabled: isEnabled,
                onPress: { _ in isPressed = true },
                onRelease: { _, inside in
                    isPressed = false
                    if inside { configuration.isOn = !isOn }
                }
            ))
    }
}

/// A toggle's body. The style is only known from the environment at build
/// time, so it is chosen there — the one `.toggleStyle(_:)` set, or
/// `.automatic`.
@View
struct _StyledToggle {
    let configuration: ToggleStyleConfiguration

    init(configuration: ToggleStyleConfiguration, _viewID: ViewID = #viewID) {
        self.configuration = configuration
        self._viewID = _viewID
    }

    var body: Never { bodyUnavailable() }
}

extension _StyledToggle: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        if let style = context.environment.toggleStyle {
            return style.storage.makeNode(configuration, &context)
        }
        return buildNode(DefaultToggleStyle().makeBody(configuration: configuration), &context)
    }
}

/// The style `.toggleStyle(_:)` set, as the environment holds it: one
/// concrete type whatever the style, the style itself in a subclass that
/// knows its type.
struct ToggleStyleBox: ViewInput {
    let storage: ToggleStyleStorage

    init<S: ToggleStyle>(_ style: S) {
        self.storage = TypedToggleStyleStorage(style)
    }

    /// Same style type, equivalent values — re-applying the same style is
    /// not an environment change.
    func _isEquivalent(to other: ToggleStyleBox) -> Bool {
        storage.isEquivalent(to: other.storage)
    }
}

@MainActor
class ToggleStyleStorage {
    func makeNode(_ configuration: ToggleStyleConfiguration, _ context: inout BuildContext) -> ViewNode {
        fatalError("ToggleStyleStorage is abstract")
    }

    func isEquivalent(to other: ToggleStyleStorage) -> Bool {
        fatalError("ToggleStyleStorage is abstract")
    }
}

final class TypedToggleStyleStorage<S: ToggleStyle>: ToggleStyleStorage {
    let style: S

    init(_ style: S) {
        self.style = style
    }

    override func makeNode(_ configuration: ToggleStyleConfiguration, _ context: inout BuildContext) -> ViewNode {
        buildNode(style.makeBody(configuration: configuration), &context)
    }

    override func isEquivalent(to other: ToggleStyleStorage) -> Bool {
        guard let other = other as? TypedToggleStyleStorage<S> else { return false }
        return _areEquivalent(style, other.style)
    }
}

/// `nil` is `.automatic`.
private struct ToggleStyleKey: EnvironmentKey {
    static var defaultValue: ToggleStyleBox? { nil }
}

extension EnvironmentValues {
    /// The style `Toggle`s in this subtree draw with.
    var toggleStyle: ToggleStyleBox? {
        get { self[ToggleStyleKey.self] }
        set { self[ToggleStyleKey.self] = newValue }
    }
}

extension View {
    /// Sets the style for toggles within this view.
    public func toggleStyle<S: ToggleStyle>(_ style: S) -> some View {
        environment(\.toggleStyle, ToggleStyleBox(style))
    }
}
