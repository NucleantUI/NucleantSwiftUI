//
//  Picker.swift
//  NucleantUI
//
//  `Picker`, `.tag(_:)` and `.pickerStyle(_:)`.
//

/// A control for choosing one of a set of values.
///
/// ```swift
/// Picker("Output", selection: $output) {
///     Text("Speakers").tag(Output.speakers)
///     Text("Headphones").tag(Output.headphones)
///     Divider()
///     Text("None").tag(Output.none)
/// }
///
/// Picker("Scale", selection: $scale) {
///     ForEach(Scale.allCases) { scale in   // tagged with each id
///         Text(scale.name)
///     }
/// }
/// .pickerStyle(.segmented)
/// ```
///
/// The choices are the views in `content` with a `.tag(_:)` of the
/// selection's type — or of its wrapped type, when the selection is
/// optional. A `ForEach` whose id has that type tags each of its views with
/// its id, so its views need no `.tag` of their own. Anything else in
/// `content` is not a choice; a `Divider` between choices is kept where
/// the style can show one.
///
/// The choices are found in `content` as written — through stacks, groups,
/// `ForEach`, `if` and modifiers, but not into the `body` of a view of your
/// own or into an `AnyView`: put the `.tag` on the view you pass, not
/// inside it.
///
/// How it looks is the `.pickerStyle(_:)` around it: a pop-up menu
/// (`.automatic`, `.menu`), a row of segments (`.segmented`), a list with a
/// checkmark on the chosen row (`.inline`) or radio buttons
/// (`.radioGroup`).
@View
public struct Picker<Label: View, SelectionValue: Hashable, Content: View>: View {
    @Binding var selection: SelectionValue
    let content: Content
    let label: Label

    @Environment(\.pickerStyleKind) private var style
    @Environment(\.labelsHidden) private var labelsHidden

    public init(
        selection: Binding<SelectionValue>,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: () -> Content,
        @ViewBuilder label: () -> Label
    ) {
        self._selection = selection
        self.content = content()
        self.label = label()
        self._viewID = _viewID
    }

    public init(
        selection: Binding<SelectionValue>,
        label: Label,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: () -> Content
    ) {
        self._selection = selection
        self.content = content()
        self.label = label
        self._viewID = _viewID
    }

    public var body: some View {
        let entries = pickerEntries(of: content, as: SelectionValue.self)
        switch style {
        case .menu:
            HStack(spacing: 8) {
                if !labelsHidden {
                    label
                    Spacer(minLength: 8)
                }
                _MenuPicker(entries: entries, selection: $selection)
            }
        case .segmented:
            HStack(spacing: 8) {
                if !labelsHidden {
                    label
                    Spacer(minLength: 8)
                }
                _SegmentedPicker(entries: entries, selection: $selection)
            }
        case .inline:
            VStack(alignment: .leading, spacing: 4) {
                if !labelsHidden {
                    label
                }
                _InlinePicker(entries: entries, selection: $selection)
            }
        case .radioGroup:
            HStack(alignment: .top, spacing: 8) {
                if !labelsHidden {
                    label
                }
                _RadioGroupPicker(entries: entries, selection: $selection)
            }
        }
    }
}

extension Picker where Label == Text {
    public init(
        _ title: String,
        selection: Binding<SelectionValue>,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: () -> Content
    ) {
        self.init(selection: selection, _viewID: _viewID, content: content) { Text(title) }
    }

    public init<S: StringProtocol>(
        _ title: S,
        selection: Binding<SelectionValue>,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: () -> Content
    ) {
        self.init(selection: selection, _viewID: _viewID, content: content) { Text(title) }
    }
}

// MARK: - Tags

extension View {
    /// Marks this view as the choice `tag` stands for — in a `Picker`, the
    /// value the selection takes when this view is chosen.
    ///
    /// With `includeOptional` (the default), the tag also stands for
    /// `Optional(tag)`, so a picker over an optional selection can use the
    /// same tags as one over a plain one.
    public func tag<V: Hashable>(_ tag: V, includeOptional: Bool = true) -> some View {
        _TagView(content: self, tag: tag, includeOptional: includeOptional)
    }
}

/// A view with a `.tag(_:)`. Draws as its content; the tag is only read by
/// the picker around it.
@View
public struct _TagView<Content: View, V: Hashable>: View {
    let content: Content
    let tag: V
    let includeOptional: Bool

    public var body: some View {
        content
    }

    /// The tag as a `SelectionValue`, if it is one — exactly, or wrapped in
    /// an optional when `includeOptional` allows it.
    func tag<SelectionValue: Hashable>(as type: SelectionValue.Type) -> SelectionValue? {
        if let exact = tag as? SelectionValue, V.self == SelectionValue.self {
            return exact
        }
        guard includeOptional else { return nil }
        return tag as? SelectionValue
    }
}

// MARK: - Finding the choices

/// One row of a picker: a choice with its tag and how it is drawn, or a
/// rule between choices.
enum PickerEntry<SelectionValue: Hashable> {
    case option(tag: SelectionValue, label: AnyView)
    case divider

    var option: (tag: SelectionValue, label: AnyView)? {
        if case let .option(tag, label) = self { return (tag, label) }
        return nil
    }
}

/// The choices in a picker's content, in order.
///
/// Nothing is built or laid out: like the lowering of a menu's items to
/// native rows, this reads stored fields of the structural views and the
/// modifiers, and never asks a view for its `body`. Each choice's label is
/// then built where the style places it, as an `AnyView` — the choices are
/// views of any types, as many as a `ForEach` has elements.
@MainActor
func pickerEntries<Content: View, SelectionValue: Hashable>(
    of content: Content,
    as type: SelectionValue.Type
) -> [PickerEntry<SelectionValue>] {
    var entries: [PickerEntry<SelectionValue>] = []
    pickerEntries(of: content, into: &entries, implicitTag: nil)
    return entries
}

/// Adds the choices in `view` to `entries`. `implicitTag` is the id of the
/// `ForEach` element `view` was built for, when that id is a selection
/// value — the tag of a view in it that has none of its own.
@MainActor
func pickerEntries<V: View, SelectionValue: Hashable>(
    of view: V,
    into entries: inout [PickerEntry<SelectionValue>],
    implicitTag: SelectionValue?
) {
    if let source = view as? PickerContentSource {
        source._pickerEntries(into: &entries, implicitTag: implicitTag)
    } else if let implicitTag {
        entries.append(.option(tag: implicitTag, label: AnyView(view)))
    }
}

/// A view the choice-finding walk looks into, or that is a choice itself.
@MainActor
protocol PickerContentSource {
    func _pickerEntries<SelectionValue: Hashable>(
        into entries: inout [PickerEntry<SelectionValue>],
        implicitTag: SelectionValue?
    )
}

extension _TagView: PickerContentSource {
    /// A tag of another type is not a choice of this picker.
    func _pickerEntries<SelectionValue: Hashable>(
        into entries: inout [PickerEntry<SelectionValue>],
        implicitTag: SelectionValue?
    ) {
        guard let tag = tag(as: SelectionValue.self) else { return }
        entries.append(.option(tag: tag, label: AnyView(content)))
    }
}

extension Divider: PickerContentSource {
    func _pickerEntries<SelectionValue: Hashable>(
        into entries: inout [PickerEntry<SelectionValue>],
        implicitTag: SelectionValue?
    ) {
        entries.append(.divider)
    }
}

extension EmptyView: PickerContentSource {
    func _pickerEntries<SelectionValue: Hashable>(
        into entries: inout [PickerEntry<SelectionValue>],
        implicitTag: SelectionValue?
    ) {}
}

extension TupleView: PickerContentSource {
    func _pickerEntries<SelectionValue: Hashable>(
        into entries: inout [PickerEntry<SelectionValue>],
        implicitTag: SelectionValue?
    ) {
        for view in repeat (each value) {
            pickerEntries(of: view, into: &entries, implicitTag: implicitTag)
        }
    }
}

extension _ViewArray: PickerContentSource {
    func _pickerEntries<SelectionValue: Hashable>(
        into entries: inout [PickerEntry<SelectionValue>],
        implicitTag: SelectionValue?
    ) {
        for element in elements {
            pickerEntries(of: element, into: &entries, implicitTag: implicitTag)
        }
    }
}

extension _ConditionalContent: PickerContentSource {
    func _pickerEntries<SelectionValue: Hashable>(
        into entries: inout [PickerEntry<SelectionValue>],
        implicitTag: SelectionValue?
    ) {
        switch storage {
        case .trueContent(let content): pickerEntries(of: content, into: &entries, implicitTag: implicitTag)
        case .falseContent(let content): pickerEntries(of: content, into: &entries, implicitTag: implicitTag)
        }
    }
}

extension Optional: PickerContentSource where Wrapped: View {
    func _pickerEntries<SelectionValue: Hashable>(
        into entries: inout [PickerEntry<SelectionValue>],
        implicitTag: SelectionValue?
    ) {
        if case .some(let wrapped) = self {
            pickerEntries(of: wrapped, into: &entries, implicitTag: implicitTag)
        }
    }
}

extension Group: PickerContentSource {
    func _pickerEntries<SelectionValue: Hashable>(
        into entries: inout [PickerEntry<SelectionValue>],
        implicitTag: SelectionValue?
    ) {
        pickerEntries(of: content, into: &entries, implicitTag: implicitTag)
    }
}

extension ForEach: PickerContentSource {
    /// Each element's views, tagged with its id when that id is a
    /// selection value and they carry no tag of their own.
    func _pickerEntries<SelectionValue: Hashable>(
        into entries: inout [PickerEntry<SelectionValue>],
        implicitTag: SelectionValue?
    ) {
        for element in data {
            let id = identify(element) as? SelectionValue
            pickerEntries(of: build(element), into: &entries, implicitTag: id ?? implicitTag)
        }
    }
}

/// A modified choice — `Text("Red").tag(1).foregroundColor(.red)`, or a
/// view in a `ForEach` with modifiers of its own — is drawn with its
/// modifiers: the choice's label is the whole modified view. A modifier
/// over several choices at once (`Group { … }.padding()`) is left out.
@MainActor
private func modifiedPickerEntries<V: View, Content: View, SelectionValue: Hashable>(
    _ view: V,
    content: Content,
    into entries: inout [PickerEntry<SelectionValue>],
    implicitTag: SelectionValue?
) {
    var inner: [PickerEntry<SelectionValue>] = []
    pickerEntries(of: content, into: &inner, implicitTag: implicitTag)
    if inner.count == 1, let option = inner[0].option {
        entries.append(.option(tag: option.tag, label: AnyView(view)))
    } else {
        entries += inner
    }
}

extension _ModifierView: PickerContentSource {
    func _pickerEntries<SelectionValue: Hashable>(
        into entries: inout [PickerEntry<SelectionValue>],
        implicitTag: SelectionValue?
    ) {
        modifiedPickerEntries(self, content: content, into: &entries, implicitTag: implicitTag)
    }
}

extension _DecoratedView: PickerContentSource {
    func _pickerEntries<SelectionValue: Hashable>(
        into entries: inout [PickerEntry<SelectionValue>],
        implicitTag: SelectionValue?
    ) {
        modifiedPickerEntries(self, content: content, into: &entries, implicitTag: implicitTag)
    }
}

extension ModifiedContent: PickerContentSource {
    func _pickerEntries<SelectionValue: Hashable>(
        into entries: inout [PickerEntry<SelectionValue>],
        implicitTag: SelectionValue?
    ) {
        modifiedPickerEntries(self, content: content, into: &entries, implicitTag: implicitTag)
    }
}

// MARK: - Styles

/// The appearance of the pickers in a subtree.
///
/// ```swift
/// Picker("Scale", selection: $scale) { … }
///     .pickerStyle(.segmented)
/// ```
///
/// As in SwiftUI, the styles are the ones listed here; the protocol's one
/// requirement is underscored, as SwiftUI's are, and not meant to be
/// implemented outside the framework.
@MainActor
public protocol PickerStyle {
    var _kind: _PickerStyleKind { get }
}

/// How a picker draws its choices — the part of a `PickerStyle` the
/// picker reads.
public enum _PickerStyleKind: Hashable, Sendable {
    case menu
    case segmented
    case inline
    case radioGroup
}

/// The default style: here, `.menu`.
public struct DefaultPickerStyle: PickerStyle {
    public init() {}
    public var _kind: _PickerStyleKind { .menu }
}

/// A button showing the chosen value, that opens the choices as a menu
/// with a checkmark on the chosen one.
public struct MenuPickerStyle: PickerStyle {
    public init() {}
    public var _kind: _PickerStyleKind { .menu }
}

/// The choices side by side as segments, the chosen one on the tint.
public struct SegmentedPickerStyle: PickerStyle {
    public init() {}
    public var _kind: _PickerStyleKind { .segmented }
}

/// The choices as rows under the label, a checkmark on the chosen one.
public struct InlinePickerStyle: PickerStyle {
    public init() {}
    public var _kind: _PickerStyleKind { .inline }
}

/// The choices as a column of radio buttons beside the label.
public struct RadioGroupPickerStyle: PickerStyle {
    public init() {}
    public var _kind: _PickerStyleKind { .radioGroup }
}

extension PickerStyle where Self == DefaultPickerStyle {
    public static var automatic: DefaultPickerStyle { DefaultPickerStyle() }
}

extension PickerStyle where Self == MenuPickerStyle {
    public static var menu: MenuPickerStyle { MenuPickerStyle() }
}

extension PickerStyle where Self == SegmentedPickerStyle {
    public static var segmented: SegmentedPickerStyle { SegmentedPickerStyle() }
}

extension PickerStyle where Self == InlinePickerStyle {
    public static var inline: InlinePickerStyle { InlinePickerStyle() }
}

extension PickerStyle where Self == RadioGroupPickerStyle {
    public static var radioGroup: RadioGroupPickerStyle { RadioGroupPickerStyle() }
}

private struct PickerStyleKindKey: EnvironmentKey {
    static let defaultValue = _PickerStyleKind.menu
}

extension EnvironmentValues {
    /// How the pickers in this subtree draw their choices.
    var pickerStyleKind: _PickerStyleKind {
        get { self[PickerStyleKindKey.self] }
        set { self[PickerStyleKindKey.self] = newValue }
    }
}

extension View {
    /// Sets the style for pickers within this view.
    public func pickerStyle<S: PickerStyle>(_ style: S) -> some View {
        environment(\.pickerStyleKind, style._kind)
    }
}

// MARK: - Menu

/// A button showing the chosen value and a chevron. It is as wide as the
/// widest choice, so it keeps its size as the choice changes; releasing it
/// opens the choices as a menu under it.
@View
struct _MenuPicker<SelectionValue: Hashable> {
    let entries: [PickerEntry<SelectionValue>]
    @Binding var selection: SelectionValue

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.menuPresenter) private var presenter
    @State private var isPressed = false

    var body: some View {
        let options = entries.compactMap(\.option)
        let entries = self.entries
        let selection = $selection
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                ForEach(options.indices, id: \.self) { index in
                    if options[index].tag == self.selection {
                        options[index].label
                            .lineLimit(1)
                    } else {
                        options[index].label
                            .lineLimit(1)
                            .hidden()
                    }
                }
            }
            // The chevron turned to point down — the bundled face has no
            // "▾" of its own.
            Text("›")
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(90))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isPressed ? controlTrackColor : Color.tertiaryBackground)
        )
        .border(.separator, width: 1, cornerRadius: 6)
        .opacity(isEnabled ? 1 : 0.4)
        ._hitTarget(HitTarget(
            isEnabled: isEnabled,
            onPress: { _ in isPressed = true },
            onRelease: { _, inside in
                isPressed = false
                if inside {
                    presenter?.present(AnyView(_PickerMenuItems(entries: entries, selection: selection)))
                }
            }
        ))
    }
}

/// The menu a menu picker opens: a row per choice, the chosen one ticked,
/// and a rule for each `Divider`. A row sets the selection and closes the
/// menu, as any `Button` in a menu does.
@View
struct _PickerMenuItems<SelectionValue: Hashable> {
    let entries: [PickerEntry<SelectionValue>]
    @Binding var selection: SelectionValue

    var body: some View {
        ForEach(entries.indices, id: \.self) { index in
            if let option = entries[index].option {
                Button {
                    selection = option.tag
                } label: {
                    HStack(spacing: 6) {
                        _PickerMenuCheck()
                            .opacity(option.tag == selection ? 1 : 0)
                        option.label
                    }
                }
            } else {
                Divider()
            }
        }
    }
}

/// The tick before the chosen row, in the row's own colour — white while
/// the row is lit.
@View
struct _PickerMenuCheck {
    @Environment(\.foregroundColor) private var foreground

    var body: some View {
        _ControlCheckmark()
            .stroke(foreground, style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
            .frame(width: 11, height: 11)
    }
}

// MARK: - Segmented

/// The choices side by side on one track, the chosen one on the tint. A
/// press on a segment chooses it; dividers are left out.
@View
struct _SegmentedPicker<SelectionValue: Hashable> {
    let entries: [PickerEntry<SelectionValue>]
    @Binding var selection: SelectionValue

    @Environment(\.tint) private var tint
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let options = entries.compactMap(\.option)
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.tag == selection
                option.label
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? tint : Color.clear)
                    )
                    .onTapGesture { selection = option.tag }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.tertiaryBackground))
        .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Inline

/// A row per choice — label leading, a tick in the tint trailing on the
/// chosen one — and a rule for each `Divider`. A press on a row chooses it.
@View
struct _InlinePicker<SelectionValue: Hashable> {
    let entries: [PickerEntry<SelectionValue>]
    @Binding var selection: SelectionValue

    @Environment(\.tint) private var tint
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries.indices, id: \.self) { index in
                if let option = entries[index].option {
                    HStack(spacing: 8) {
                        option.label
                        Spacer(minLength: 8)
                        _ControlCheckmark()
                            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .frame(width: 13, height: 13)
                            .opacity(option.tag == selection ? 1 : 0)
                    }
                    .padding(.vertical, 7)
                    .onTapGesture { selection = option.tag }
                } else {
                    Divider()
                }
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Radio group

/// A column of radio buttons, one per choice, the chosen one filled with
/// the tint. A press on a button or its label chooses it; dividers are
/// kept as rules.
@View
struct _RadioGroupPicker<SelectionValue: Hashable> {
    let entries: [PickerEntry<SelectionValue>]
    @Binding var selection: SelectionValue

    @Environment(\.tint) private var tint
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entries.indices, id: \.self) { index in
                if let option = entries[index].option {
                    let isSelected = option.tag == selection
                    HStack(spacing: 6) {
                        ZStack {
                            Circle()
                                .fill(isSelected ? tint : Color.secondaryBackground)
                            if isSelected {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 6, height: 6)
                            } else {
                                Circle()
                                    .stroke(Color.separator, lineWidth: 1)
                            }
                        }
                        .frame(width: 16, height: 16)
                        option.label
                    }
                    .onTapGesture { selection = option.tag }
                } else {
                    Divider()
                }
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
    }
}
