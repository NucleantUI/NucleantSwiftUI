//
//  Form.swift
//  NucleantUI
//
//  `Form`, `FormStyle` (`.columns`, `.grouped`), and `LabeledContent`.
//

import Foundation

/// Controls for entering data or changing settings, laid out the way the
/// platform lays out a settings pane.
///
/// ```swift
/// Form {
///     Section("Issue") {
///         TextField("Title", text: $issue.title)
///         Picker("Status", selection: $issue.status) { … }
///         Stepper("Estimate: \(issue.points)", value: $issue.points, in: 0...13)
///     }
///     Section {
///         Toggle("Blocked", isOn: $issue.isBlocked)
///         LabeledContent("Created", value: issue.created, format: .dateTime)
///     }
/// }
/// ```
///
/// Its rows are found as a `List`'s are (see `ListContent.swift`). A
/// control with a label — `Picker`, `Slider`, `Stepper`, `TextField`,
/// `SecureField`, `Toggle`, `LabeledContent` — is split into its label and
/// the control, and the style places the two:
///
/// * `.columns` (the desktop default): labels in a column of their own,
///   against its trailing edge, and controls lined up beside them; a
///   toggle sits in the control column with its label, and a section's
///   header goes in the label column beside the section's first row.
/// * `.grouped` (the phone default): sections as rounded groups down a
///   scrolling page, each row a label on the leading edge and its control
///   on the trailing one; toggles are switches.
@View
public struct Form<Content: View>: View {
    let content: Content

    public init(_viewID: ViewID = #viewID, @ViewBuilder content: () -> Content) {
        self.content = content()
        self._viewID = _viewID
    }

    public var body: some View {
        _StyledForm(configuration: FormStyleConfiguration(
            content: FormStyleConfiguration.Content(TypedFormContentBuilder(content))
        ))
    }
}

extension Form where Content == FormStyleConfiguration.Content {
    /// A form for a style's configuration — how a style that only adjusts
    /// another one draws the form it was handed.
    public init(_ configuration: FormStyleConfiguration, _viewID: ViewID = #viewID) {
        self.init(_viewID: _viewID) { configuration.content }
    }
}

// MARK: - Styles

/// The appearance of the forms in a subtree.
///
/// ```swift
/// struct CardFormStyle: FormStyle {
///     func makeBody(configuration: Configuration) -> some View {
///         ScrollView {
///             VStack(alignment: .leading, spacing: 12) {
///                 configuration.content
///             }
///             .padding(24)
///         }
///     }
/// }
/// ```
@MainActor
public protocol FormStyle {
    associatedtype Body: View

    @ViewBuilder func makeBody(configuration: Configuration) -> Body

    typealias Configuration = FormStyleConfiguration
}

/// The properties of a form, handed to its style.
@MainActor
public struct FormStyleConfiguration {

    /// The form's content — as written, when a style places it; row by
    /// row, when a style of the framework's lays it out.
    public struct Content: View {
        let builder: FormContentBuilder

        init(_ builder: FormContentBuilder) {
            self.builder = builder
        }

        public var body: Never { bodyUnavailable() }
    }

    public let content: Content
}

extension FormStyleConfiguration.Content: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        builder.build(&context)
    }
}

extension FormStyleConfiguration.Content: ListContentSource {
    func _listItems<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>) {
        builder.walk(into: &walk)
    }
}

/// How to build or walk a form's content, in an object made fresh by
/// every build of the form — compared by identity, so a style's body is
/// never kept over content it hasn't seen.
@MainActor
class FormContentBuilder {
    func build(_ context: inout BuildContext) -> ViewNode {
        fatalError("FormContentBuilder is abstract")
    }

    func walk<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>) {
        fatalError("FormContentBuilder is abstract")
    }
}

final class TypedFormContentBuilder<Content: View>: FormContentBuilder {
    let content: Content

    init(_ content: Content) {
        self.content = content
    }

    override func build(_ context: inout BuildContext) -> ViewNode {
        buildNode(content, &context)
    }

    override func walk<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>) {
        listItems(of: content, into: &walk)
    }
}

/// The platform's style: `.columns` on the desktop, `.grouped` on a phone.
public struct AutomaticFormStyle: FormStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        #if os(iOS) || os(Android)
        _GroupedForm(content: configuration.content)
        #else
        _ColumnsForm(content: configuration.content)
        #endif
    }
}

/// Labels in a column against its trailing edge, controls lined up beside
/// them.
public struct ColumnsFormStyle: FormStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _ColumnsForm(content: configuration.content)
    }
}

/// Sections as rounded groups down a scrolling page, each row a label on
/// the leading edge and its control on the trailing one.
public struct GroupedFormStyle: FormStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        _GroupedForm(content: configuration.content)
    }
}

extension FormStyle where Self == AutomaticFormStyle {
    public static var automatic: AutomaticFormStyle { AutomaticFormStyle() }
}

extension FormStyle where Self == ColumnsFormStyle {
    public static var columns: ColumnsFormStyle { ColumnsFormStyle() }
}

extension FormStyle where Self == GroupedFormStyle {
    public static var grouped: GroupedFormStyle { GroupedFormStyle() }
}

/// A form's body. The style is only known from the environment at build
/// time, so it is chosen there.
@View
struct _StyledForm {
    let configuration: FormStyleConfiguration

    init(configuration: FormStyleConfiguration, _viewID: ViewID = #viewID) {
        self.configuration = configuration
        self._viewID = _viewID
    }

    var body: Never { bodyUnavailable() }
}

extension _StyledForm: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        if let style = context.environment.formStyle {
            return style.storage.makeNode(configuration, &context)
        }
        return buildNode(AutomaticFormStyle().makeBody(configuration: configuration), &context)
    }
}

/// The style `.formStyle(_:)` set, as the environment holds it.
struct FormStyleBox: ViewInput {
    let storage: FormStyleStorage

    init<S: FormStyle>(_ style: S) {
        self.storage = TypedFormStyleStorage(style)
    }

    func _isEquivalent(to other: FormStyleBox) -> Bool {
        storage.isEquivalent(to: other.storage)
    }
}

@MainActor
class FormStyleStorage {
    func makeNode(_ configuration: FormStyleConfiguration, _ context: inout BuildContext) -> ViewNode {
        fatalError("FormStyleStorage is abstract")
    }

    func isEquivalent(to other: FormStyleStorage) -> Bool {
        fatalError("FormStyleStorage is abstract")
    }
}

final class TypedFormStyleStorage<S: FormStyle>: FormStyleStorage {
    let style: S

    init(_ style: S) {
        self.style = style
    }

    override func makeNode(_ configuration: FormStyleConfiguration, _ context: inout BuildContext) -> ViewNode {
        buildNode(style.makeBody(configuration: configuration), &context)
    }

    override func isEquivalent(to other: FormStyleStorage) -> Bool {
        guard let other = other as? TypedFormStyleStorage<S> else { return false }
        return _areEquivalent(style, other.style)
    }
}

/// `nil` is `.automatic`.
private struct FormStyleKey: EnvironmentKey {
    static var defaultValue: FormStyleBox? { nil }
}

extension EnvironmentValues {
    /// The style `Form`s in this subtree draw with.
    var formStyle: FormStyleBox? {
        get { self[FormStyleKey.self] }
        set { self[FormStyleKey.self] = newValue }
    }
}

extension View {
    /// Sets the style for forms within this view.
    public func formStyle<S: FormStyle>(_ style: S) -> some View {
        environment(\.formStyle, FormStyleBox(style))
    }
}

// MARK: - Labels and controls

/// A form row split into the control's label and the control.
struct FormRowParts {
    enum Kind {
        /// The control keeps its natural width — a pop-up menu, a stepper.
        case labeled
        /// The control takes the width it is offered — a text field, a
        /// slider.
        case field
        /// A toggle: in columns, the whole toggle in the control column; in
        /// groups, the label and a switch.
        case toggle
    }

    let kind: Kind
    let label: AnyView
    /// The whole control, label and all; the form hides the label with
    /// `.labelsHidden()` where it draws it apart.
    var control: AnyView
}

/// A control whose label a form draws apart from it.
@MainActor
protocol FormRowSource {
    func _formRowParts() -> FormRowParts
}

extension Picker: FormRowSource {
    func _formRowParts() -> FormRowParts {
        FormRowParts(kind: .labeled, label: AnyView(label), control: AnyView(self))
    }
}

extension Slider: FormRowSource {
    func _formRowParts() -> FormRowParts {
        FormRowParts(kind: .field, label: AnyView(label), control: AnyView(self))
    }
}

extension Stepper: FormRowSource {
    func _formRowParts() -> FormRowParts {
        FormRowParts(kind: .labeled, label: AnyView(label), control: AnyView(self))
    }
}

extension TextField: FormRowSource {
    func _formRowParts() -> FormRowParts {
        FormRowParts(kind: .field, label: AnyView(label), control: AnyView(self))
    }
}

extension SecureField: FormRowSource {
    func _formRowParts() -> FormRowParts {
        FormRowParts(kind: .field, label: AnyView(label), control: AnyView(self))
    }
}

extension Toggle: FormRowSource {
    func _formRowParts() -> FormRowParts {
        FormRowParts(kind: .toggle, label: AnyView(label), control: AnyView(self))
    }
}

extension LabeledContent: FormRowSource {
    func _formRowParts() -> FormRowParts {
        FormRowParts(kind: .labeled, label: AnyView(label), control: AnyView(self))
    }
}

// MARK: - Columns

/// One line of a columns form: what goes in the label column and what in
/// the control column.
struct FormLine: Identifiable {
    let id: Int
    let label: AnyView?
    let control: AnyView?
    /// Extra space above the line — where a new section starts.
    let gap: Double
}

/// The lines of a columns form, from its rows.
@MainActor
func formLines(_ items: [ListItem<Never>]) -> [FormLine] {
    var lines: [FormLine] = []
    var pendingHeader: (id: Int, label: AnyView)?
    var lastSection: Int?
    var gap = 0.0

    func plainControl(for item: ListItem<Never>) -> AnyView {
        guard item.formParts == nil else { return AnyView(EmptyView()) }
        return AnyView(_ListRowContent(item: item, inverted: false, look: ListLook(kind: .inset, alternates: .disabled)))
    }

    for item in items {
        if let lastSection, lastSection != item.section, !lines.isEmpty || pendingHeader != nil {
            gap = 18
        }
        lastSection = item.section
        switch item.kind {
        case .header:
            if let header = pendingHeader {
                lines.append(FormLine(id: header.id, label: header.label, control: nil, gap: gap))
                gap = 0
            }
            pendingHeader = (item.id, item.label)
        case .footer:
            if let header = pendingHeader {
                lines.append(FormLine(id: header.id, label: header.label, control: nil, gap: gap))
                gap = 0
                pendingHeader = nil
            }
            lines.append(FormLine(
                id: item.id,
                label: nil,
                control: AnyView(item.label.font(.system(size: 12)).foregroundColor(.secondary)),
                gap: gap
            ))
            gap = 0
        case .row:
            var label: AnyView?
            var control: AnyView
            if let parts = item.formParts {
                switch parts.kind {
                case .labeled, .field:
                    label = parts.label
                    control = AnyView(parts.control.labelsHidden())
                case .toggle:
                    control = parts.control
                }
            } else {
                control = plainControl(for: item)
            }
            // A section's header takes the label column beside its first
            // row, when that row has no label of its own.
            if let header = pendingHeader {
                if label == nil {
                    label = header.label
                } else {
                    lines.append(FormLine(id: header.id, label: header.label, control: nil, gap: gap))
                    gap = 0
                }
                pendingHeader = nil
            }
            lines.append(FormLine(id: item.id, label: label, control: control, gap: gap))
            gap = 0
        }
    }
    if let header = pendingHeader {
        lines.append(FormLine(id: header.id, label: header.label, control: nil, gap: gap))
    }
    return lines
}

/// `ColumnsFormStyle`'s body.
@View
struct _ColumnsForm {
    let content: FormStyleConfiguration.Content

    @State private var expanded: Set<Int> = []
    @State private var collapsed: Set<Int> = []

    var body: some View {
        _FormColumns(lines: formLines(items()))
    }

    private func items() -> [ListItem<Never>] {
        var walk = ListWalk<Never>(expanded: $expanded, collapsed: $collapsed, sectionsCollapse: false)
        listItems(of: content, into: &walk)
        return walk.items
    }
}

/// The two columns, built as nodes of their own so the label column can be
/// as wide as its widest label.
@View
struct _FormColumns {
    let lines: [FormLine]

    init(lines: [FormLine], _viewID: ViewID = #viewID) {
        self.lines = lines
        self._viewID = _viewID
    }

    var body: Never { bodyUnavailable() }
}

extension _FormColumns: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let metrics = FormColumnsMetrics()
        var inner = context
        inner.stackAxis = nil
        let children = lines.map { line in
            inner.child(line.id) { ctx -> ViewNode in
                let label = ctx.child(0) { buildNode(line.label?.multilineTextAlignment(.trailing), &$0) }
                let control = ctx.child(1) { buildNode(line.control, &$0) }
                return ViewNode(content: FormLineContent(metrics: metrics), children: [label, control])
            }
        }
        return ViewNode(
            content: FormColumnsContent(metrics: metrics, gaps: lines.map(\.gap)),
            children: children
        )
    }
}

/// The label column's width, worked out by the form and read by its lines.
@MainActor
final class FormColumnsMetrics {
    var labelWidth = 0.0
}

/// The lines of a columns form, one under the other.
struct FormColumnsContent: NodeContent {
    let metrics: FormColumnsMetrics
    let gaps: [Double]

    static let columnGap = 8.0
    static let lineSpacing = 10.0

    /// As wide as the widest label — but never more than two fifths of the
    /// form, past which labels wrap.
    private func labelWidth(_ proposal: ProposedSize, lines: [ViewNode]) -> Double {
        var widest = 0.0
        for line in lines where line.children.count == 2 {
            widest = max(widest, line.children[0].sizeThatFits(.unspecified).width)
        }
        if let width = proposal.width { widest = min(widest, width * 0.4) }
        return widest.rounded(.up)
    }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        let lines = node.children
        metrics.labelWidth = labelWidth(proposal, lines: lines)
        var size = Size.zero
        for (index, line) in lines.enumerated() {
            let lineSize = line.sizeThatFits(ProposedSize(width: proposal.width, height: nil))
            size.width = max(size.width, lineSize.width)
            size.height += lineSize.height + spacing(before: index)
        }
        return Size(width: proposal.width ?? size.width, height: size.height)
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        let lines = node.children
        metrics.labelWidth = labelWidth(ProposedSize(rect.size), lines: lines)
        var y = rect.minY
        let lineProposal = ProposedSize(width: rect.width, height: nil)
        for (index, line) in lines.enumerated() {
            y += spacing(before: index)
            let size = line.sizeThatFits(lineProposal)
            line.place(
                in: Rect(x: rect.minX, y: y, width: rect.width, height: size.height),
                proposal: lineProposal,
                context: context,
                into: &list
            )
            y += size.height
        }
    }

    private func spacing(before index: Int) -> Double {
        guard index > 0 else { return 0 }
        return Self.lineSpacing + (index < gaps.count ? gaps[index] : 0)
    }
}

/// One line: the label against the label column's trailing edge, the
/// control at the start of the control column.
struct FormLineContent: NodeContent {
    let metrics: FormColumnsMetrics

    private func sizes(_ proposal: ProposedSize, node: ViewNode) -> (label: Size, control: Size, controlProposal: ProposedSize) {
        let labelWidth = metrics.labelWidth
        let label = node.children[0].sizeThatFits(ProposedSize(width: labelWidth, height: nil))
        let controlProposal = ProposedSize(
            width: proposal.width.map { max(0, $0 - labelWidth - FormColumnsContent.columnGap) },
            height: nil
        )
        let control = node.children[1].sizeThatFits(controlProposal)
        return (label, control, controlProposal)
    }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        guard node.children.count == 2 else { return .zero }
        let (label, control, _) = sizes(proposal, node: node)
        let width = proposal.width ?? metrics.labelWidth + FormColumnsContent.columnGap + control.width
        return Size(width: width, height: max(label.height, control.height))
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard node.children.count == 2 else { return }
        let (label, control, controlProposal) = sizes(ProposedSize(rect.size), node: node)
        let labelWidth = metrics.labelWidth
        // A short control and its label are centred on each other; beside
        // a tall one (an inline picker, a text editor) the label stays
        // level with its first line.
        let height = max(label.height, control.height)
        let labelY: Double
        let controlY: Double
        if control.height <= 34 {
            labelY = rect.minY + (height - label.height) / 2
            controlY = rect.minY + (height - control.height) / 2
        } else {
            labelY = rect.minY + max(0, (28 - label.height) / 2)
            controlY = rect.minY
        }
        node.children[0].place(
            in: Rect(x: rect.minX + labelWidth - label.width, y: labelY, width: label.width, height: label.height),
            proposal: ProposedSize(width: labelWidth, height: nil),
            context: context,
            into: &list
        )
        node.children[1].place(
            in: Rect(
                x: rect.minX + labelWidth + FormColumnsContent.columnGap,
                y: controlY,
                width: control.width,
                height: control.height
            ),
            proposal: controlProposal,
            context: context,
            into: &list
        )
    }
}

// MARK: - Grouped

/// `GroupedFormStyle`'s body: the sections as rounded groups down a
/// scrolling page.
@View
struct _GroupedForm {
    let content: FormStyleConfiguration.Content

    @State private var expanded: Set<Int> = []
    @State private var collapsed: Set<Int> = []

    var body: some View {
        let look = ListLook(kind: .insetGrouped, alternates: .disabled)
        let groups = listGroups(items(), look: look)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        if let header = group.header {
                            _GroupedSectionHeader(item: header)
                        }
                        if !group.rows.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(group.rows) { entry in
                                    _GroupedFormRow(item: entry.item, showsSeparator: entry.showsSeparator)
                                }
                            }
                            .background(Color.secondaryBackground)
                            .cornerRadius(10)
                        }
                        if let footer = group.footer {
                            footer.label
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .padding(look.contentInsets)
        }
        .background(Color.background)
    }

    private func items() -> [ListItem<Never>] {
        var walk = ListWalk<Never>(expanded: $expanded, collapsed: $collapsed, sectionsCollapse: false)
        listItems(of: content, into: &walk)
        return walk.items
    }
}

/// One row of a grouped form: a control's label leading and the control
/// trailing, or a plain row as it is.
@View
struct _GroupedFormRow {
    let item: ListItem<Never>
    let showsSeparator: Bool

    var body: some View {
        let item = self.item
        let insets = item.traits.insets ?? ListLook(kind: .insetGrouped, alternates: .disabled).rowInsets
        Group {
            if let parts = item.formParts {
                switch parts.kind {
                case .labeled:
                    _LabeledRow(fillsControl: false) {
                        parts.label
                    } control: {
                        parts.control.labelsHidden()
                    }
                case .field:
                    _LabeledRow(fillsControl: true) {
                        parts.label
                    } control: {
                        parts.control.labelsHidden()
                    }
                case .toggle:
                    _LabeledRow(fillsControl: false) {
                        parts.label
                    } control: {
                        parts.control.labelsHidden().toggleStyle(.switch)
                    }
                }
            } else {
                _ListRowContent(item: item, inverted: false, look: ListLook(kind: .insetGrouped, alternates: .disabled))
            }
        }
        .padding(insets)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(item.traits.background ?? AnyView(Color.clear))
        .overlay(alignment: .bottom) {
            if showsSeparator {
                Rectangle()
                    .fill(item.traits.separatorTint ?? Color.separator)
                    .frame(height: 1)
                    .padding(.leading, insets.leading)
            }
        }
    }
}

/// A label on the leading edge and a control on the trailing one — or, for
/// a control that fills (`fillsControl`), across the rest of the row. The
/// label takes its natural width, up to half the row.
@View
struct _LabeledRow<Label: View, Control: View> {
    let fillsControl: Bool
    let label: Label
    let control: Control

    init(
        fillsControl: Bool,
        _viewID: ViewID = #viewID,
        @ViewBuilder label: () -> Label,
        @ViewBuilder control: () -> Control
    ) {
        self.fillsControl = fillsControl
        self.label = label()
        self.control = control()
        self._viewID = _viewID
    }

    var body: Never { bodyUnavailable() }
}

extension _LabeledRow: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        var inner = context
        inner.stackAxis = nil
        let label = inner.child(0) { buildNode(self.label, &$0) }
        let control = inner.child(1) { buildNode(self.control, &$0) }
        return ViewNode(content: LabeledRowContent(fillsControl: fillsControl), children: [label, control])
    }
}

struct LabeledRowContent: NodeContent {
    let fillsControl: Bool

    static let gap = 16.0

    private func sizes(_ proposal: ProposedSize, node: ViewNode) -> (label: Size, control: Size, labelProposal: ProposedSize, controlProposal: ProposedSize) {
        let ideal = node.children[0].sizeThatFits(.unspecified)
        var labelProposal = ProposedSize.unspecified
        var controlProposal = ProposedSize.unspecified
        if let width = proposal.width {
            let labelWidth = min(ideal.width, width * (fillsControl ? 0.4 : 0.6))
            labelProposal = ProposedSize(width: labelWidth, height: nil)
            controlProposal = ProposedSize(width: max(0, width - labelWidth - Self.gap), height: nil)
        }
        let label = node.children[0].sizeThatFits(labelProposal)
        let control = node.children[1].sizeThatFits(controlProposal)
        return (label, control, labelProposal, controlProposal)
    }

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        guard node.children.count == 2 else { return .zero }
        let (label, control, _, _) = sizes(proposal, node: node)
        return Size(
            width: proposal.width ?? label.width + Self.gap + control.width,
            height: max(label.height, control.height)
        )
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard node.children.count == 2 else { return }
        let (label, control, labelProposal, controlProposal) = sizes(ProposedSize(rect.size), node: node)
        let height = rect.height
        node.children[0].place(
            in: Rect(x: rect.minX, y: rect.minY + (height - label.height) / 2, width: label.width, height: label.height),
            proposal: labelProposal,
            context: context,
            into: &list
        )
        let controlX = fillsControl
            ? rect.minX + label.width + Self.gap
            : rect.maxX - control.width
        let controlWidth = fillsControl ? max(0, rect.maxX - controlX) : control.width
        node.children[1].place(
            in: Rect(x: controlX, y: rect.minY + (height - control.height) / 2, width: controlWidth, height: control.height),
            proposal: controlProposal,
            context: context,
            into: &list
        )
    }
}

// MARK: - LabeledContent

/// A value with a label — a read-only row of a form, or a label beside a
/// control of your own.
///
/// ```swift
/// LabeledContent("Created", value: issue.created, format: .dateTime)
/// LabeledContent("Reporter") {
///     AvatarView(issue.reporter)
/// }
/// ```
///
/// In a form, the label goes where the form puts labels. Anywhere else the
/// label is on the leading edge and the content, in the secondary colour,
/// on the trailing one.
@View
public struct LabeledContent<Label: View, Content: View>: View {
    let label: Label
    let content: Content

    @Environment(\.labelsHidden) private var labelsHidden

    public init(_viewID: ViewID = #viewID, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.label = label()
        self.content = content()
        self._viewID = _viewID
    }

    public var body: some View {
        if labelsHidden {
            content
        } else {
            _LabeledRow(fillsControl: false) {
                label
            } control: {
                content
                    .foregroundColor(.secondary)
            }
        }
    }
}

extension LabeledContent where Label == Text {
    public init<S: StringProtocol>(_ title: S, _viewID: ViewID = #viewID, @ViewBuilder content: () -> Content) {
        self.init(_viewID: _viewID, content: content) { Text(title) }
    }
}

extension LabeledContent where Label == Text, Content == Text {
    public init<S: StringProtocol, V: StringProtocol>(_ title: S, value: V, _viewID: ViewID = #viewID) {
        self.init(_viewID: _viewID) { Text(value) } label: { Text(title) }
    }

    /// The value, formatted — `LabeledContent("Due", value: date, format:
    /// .dateTime.day().month())`.
    public init<S: StringProtocol, F: FormatStyle>(
        _ title: S,
        value: F.FormatInput,
        format: F,
        _viewID: ViewID = #viewID
    ) where F.FormatInput: Equatable, F.FormatOutput == String {
        self.init(_viewID: _viewID) { Text(format.format(value)) } label: { Text(title) }
    }
}
