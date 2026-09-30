//
//  ListContent.swift
//  NucleantUI
//
//  Finding the rows in a `List`'s (or a `Form`'s) content: every view in it
//  is a row, found the way `Picker` finds its choices — through stacks'
//  builders, `Group`, `ForEach`, `if` and modifiers, by reading their stored
//  fields and never a `body`. A `Section` adds a header, its rows and a
//  footer; an `OutlineGroup` or a `DisclosureGroup` adds a row with a
//  chevron and, while open, its children one level in. A view of your own
//  is one row, whatever its body holds.
//
//  Also here: the row modifiers (`.listRowInsets`, `.listRowBackground`,
//  `.listRowSeparator`, `.badge`, `.selectionDisabled`), which a list reads
//  off its rows the same way.
//

// MARK: - Items

/// One entry of a list as it is drawn: a row, or a section's header or
/// footer.
struct ListItem<SelectionValue: Hashable> {
    enum Kind: Equatable {
        case row
        case header
        case footer
    }

    let kind: Kind
    /// Where the item came from, hashed: the same row has the same id from
    /// one build to the next — a `ForEach` row by its element's id — so its
    /// `@State` stays with it.
    let id: Int
    /// The value selecting this row stands for — its `.tag`, or the id of
    /// the `ForEach` or `OutlineGroup` element it was built for.
    let tag: SelectionValue?
    var label: AnyView
    /// How many outline levels in the row sits.
    let depth: Int
    /// The section the item belongs to. Rows outside any section share an
    /// id per run between sections.
    let section: Int
    /// The chevron of a row that opens and closes — an outline row with
    /// children, a disclosure group's label, a collapsible section's header.
    var disclosure: ListDisclosure?
    /// Whether the row is part of an outline, so leaves line up with the
    /// labels of the rows that have chevrons.
    let isInOutline: Bool
    var traits: ListRowTraits
    /// How a `Form` splits this row into a label and a control, when it is
    /// a control with a label.
    var formParts: FormRowParts?
}

/// Whether a row's children are showing, and how to change that.
struct ListDisclosure {
    let isExpanded: Bool
    let binding: Binding<Bool>
}

/// What the row modifiers set, carried down from where they were written
/// to the rows below.
struct ListRowTraits {
    var insets: EdgeInsets?
    var background: AnyView?
    var topSeparator = Visibility.automatic
    var bottomSeparator = Visibility.automatic
    var separatorTint: Color?
    var badge: Text?
    var selectionDisabled = false
}

// MARK: - The walk

/// The state of one walk over a list's content.
@MainActor
struct ListWalk<SelectionValue: Hashable> {
    private(set) var items: [ListItem<SelectionValue>] = []

    /// Where in the content the walk is — hashed into each item's id.
    private var path: [Int] = []
    /// The id of the element the views being walked were built for, when
    /// it is a selection value: the tag of a row that has none of its own.
    var implicitTag: SelectionValue?
    private(set) var depth = 0
    private(set) var isInOutline = false
    var traits = ListRowTraits()

    private(set) var section = 0
    private var nextSection = 1

    /// The open rows and the collapsed sections, as the list keeps them for
    /// the groups and sections that bring no binding of their own.
    let expanded: Binding<Set<Int>>
    let collapsed: Binding<Set<Int>>
    /// Whether a section without a binding can be collapsed — in a sidebar.
    let sectionsCollapse: Bool

    init(expanded: Binding<Set<Int>>, collapsed: Binding<Set<Int>>, sectionsCollapse: Bool) {
        self.expanded = expanded
        self.collapsed = collapsed
        self.sectionsCollapse = sectionsCollapse
    }

    /// The id an item appended here gets.
    var identity: Int {
        var hasher = Hasher()
        hasher.combine(path)
        return hasher.finalize()
    }

    /// Walk `body` one level down, at slot `index`.
    mutating func child(_ index: Int, _ body: (inout ListWalk) -> Void) {
        path.append(index)
        body(&self)
        path.removeLast()
    }

    /// Walk `body` with the traits and tag in effect restored after it.
    mutating func scoped(_ body: (inout ListWalk) -> Void) {
        let traits = self.traits
        let tag = implicitTag
        body(&self)
        self.traits = traits
        self.implicitTag = tag
    }

    mutating func appendRow(_ label: AnyView, formParts: FormRowParts? = nil) {
        items.append(ListItem(
            kind: .row,
            id: identity,
            tag: implicitTag,
            label: label,
            depth: depth,
            section: section,
            disclosure: nil,
            isInOutline: isInOutline,
            traits: traits,
            formParts: formParts
        ))
    }

    mutating func appendSectionItem(_ kind: ListItem<SelectionValue>.Kind, _ label: AnyView, disclosure: ListDisclosure?) {
        items.append(ListItem(
            kind: kind,
            id: identity,
            tag: nil,
            label: label,
            depth: depth,
            section: section,
            disclosure: disclosure,
            isInOutline: false,
            traits: ListRowTraits(),
            formParts: nil
        ))
    }

    /// Walk `view` as one row that opens and closes — the label of an
    /// outline element or a disclosure group — and, while it is open, walk
    /// `children` one level in.
    mutating func appendDisclosure<Label: View>(
        _ label: Label,
        tag: SelectionValue?,
        isExpanded: Binding<Bool>?,
        children: (inout ListWalk) -> Void
    ) {
        let binding = isExpanded ?? expansion(for: identity)
        let open = binding.wrappedValue
        let start = items.count
        let outer = isInOutline
        isInOutline = true
        scoped { walk in
            walk.implicitTag = tag
            walk.child(0) { listItems(of: label, into: &$0) }
        }
        // The chevron goes on the label's row — when the label is one row.
        if items.count == start + 1, items[start].kind == .row {
            items[start].disclosure = ListDisclosure(isExpanded: open, binding: binding)
        }
        if open {
            depth += 1
            child(1) { children(&$0) }
            depth -= 1
        }
        isInOutline = outer
    }

    /// Walk `view` as a row of an outline that has no children — lined up
    /// with the labels of the rows that do.
    mutating func appendOutlineLeaf<Label: View>(_ view: Label, tag: SelectionValue?) {
        let outer = isInOutline
        isInOutline = true
        scoped { walk in
            walk.implicitTag = tag
            walk.child(0) { listItems(of: view, into: &$0) }
        }
        isInOutline = outer
    }

    mutating func beginSection() {
        section = nextSection
        nextSection += 1
    }

    /// Rows after a section are a run of their own.
    mutating func endSection() {
        section = nextSection
        nextSection += 1
    }

    /// Whether the row with id `key` is open, as the list keeps it.
    func expansion(for key: Int) -> Binding<Bool> {
        let expanded = self.expanded
        return Binding(
            get: { expanded.wrappedValue.contains(key) },
            set: { isOpen in
                if isOpen { expanded.wrappedValue.insert(key) } else { expanded.wrappedValue.remove(key) }
            }
        )
    }

    /// Whether the section with header id `key` is open, as the list keeps
    /// it — open unless collapsed.
    func sectionExpansion(for key: Int) -> Binding<Bool> {
        let collapsed = self.collapsed
        return Binding(
            get: { !collapsed.wrappedValue.contains(key) },
            set: { isOpen in
                if isOpen { collapsed.wrappedValue.remove(key) } else { collapsed.wrappedValue.insert(key) }
            }
        )
    }
}

/// Adds the rows in `view` to `walk`.
@MainActor
func listItems<V: View, SelectionValue: Hashable>(of view: V, into walk: inout ListWalk<SelectionValue>) {
    if let source = view as? ListContentSource {
        source._listItems(into: &walk)
    } else {
        walk.appendRow(AnyView(view), formParts: (view as? FormRowSource)?._formRowParts())
    }
}

/// A view the row-finding walk looks into rather than taking as one row.
@MainActor
protocol ListContentSource {
    func _listItems<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>)
}

extension EmptyView: ListContentSource {
    func _listItems<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>) {}
}

extension TupleView: ListContentSource {
    func _listItems<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>) {
        var index = 0
        for view in repeat (each value) {
            walk.child(index) { listItems(of: view, into: &$0) }
            index += 1
        }
    }
}

extension _ViewArray: ListContentSource {
    func _listItems<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>) {
        for (index, element) in elements.enumerated() {
            walk.child(index) { listItems(of: element, into: &$0) }
        }
    }
}

extension _ConditionalContent: ListContentSource {
    func _listItems<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>) {
        switch storage {
        case .trueContent(let content): walk.child(0) { listItems(of: content, into: &$0) }
        case .falseContent(let content): walk.child(1) { listItems(of: content, into: &$0) }
        }
    }
}

extension Optional: ListContentSource where Wrapped: View {
    func _listItems<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>) {
        if case .some(let wrapped) = self {
            walk.child(0) { listItems(of: wrapped, into: &$0) }
        }
    }
}

extension Group: ListContentSource {
    func _listItems<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>) {
        walk.child(0) { listItems(of: content, into: &$0) }
    }
}

extension ForEach: ListContentSource {
    /// A row per element, identified by the element's id and tagged with it
    /// when it is a selection value.
    func _listItems<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>) {
        for element in data {
            let id = identify(element)
            walk.child(id.hashValue) { walk in
                walk.scoped { walk in
                    if let tag = id as? SelectionValue { walk.implicitTag = tag }
                    listItems(of: build(element), into: &walk)
                }
            }
        }
    }
}

extension _TagView: ListContentSource {
    /// A tag of the list's selection type selects the rows inside; another
    /// type's tag is no concern of the list's.
    func _listItems<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>) {
        walk.scoped { walk in
            if let tag = tag(as: SelectionValue.self) { walk.implicitTag = tag }
            listItems(of: content, into: &walk)
        }
    }
}

/// A modified row — `Text("Inbox").bold()`, a row in a `ForEach` with
/// modifiers of its own — is drawn with its modifiers. A modifier over
/// several rows at once (`Group { … }.padding()`) is left out.
@MainActor
private func modifiedListItems<V: View, Content: View, SelectionValue: Hashable>(
    _ view: V,
    content: Content,
    into walk: inout ListWalk<SelectionValue>
) {
    let start = walk.items.count
    listItems(of: content, into: &walk)
    walk.replaceSingleRow(from: start, with: view)
}

extension ListWalk {
    /// When the rows from `start` on are exactly one, draw it as `view` —
    /// the whole modified view — instead of what was inside it.
    mutating func replaceSingleRow<V: View>(from start: Int, with view: V) {
        guard items.count == start + 1, items[start].kind == .row else { return }
        items[start].label = AnyView(view)
        if items[start].formParts != nil {
            items[start].formParts?.control = AnyView(view)
        }
    }
}

extension _ModifierView: ListContentSource {
    func _listItems<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>) {
        modifiedListItems(self, content: content, into: &walk)
    }
}

extension _DecoratedView: ListContentSource {
    func _listItems<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>) {
        modifiedListItems(self, content: content, into: &walk)
    }
}

extension ModifiedContent: ListContentSource {
    func _listItems<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>) {
        modifiedListItems(self, content: content, into: &walk)
    }
}

extension DisclosureGroup: ListContentSource {
    /// In a list, the label is a row with a chevron and the content is rows
    /// one level in — as in a sidebar.
    func _listItems<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>) {
        let content = self.content
        walk.appendDisclosure(label, tag: walk.implicitTag, isExpanded: isExpandedSource.binding) { walk in
            listItems(of: content(), into: &walk)
        }
    }
}

// MARK: - Row modifiers

/// A row modifier: draws as its content, and sets a trait of the rows in it
/// for the list around them.
@View
public struct _ListRowTraitView<Content: View>: View {
    let content: Content
    let trait: ListRowTrait

    init(content: Content, trait: ListRowTrait, _viewID: ViewID = #viewID) {
        self.content = content
        self.trait = trait
        self._viewID = _viewID
    }

    public var body: some View {
        content
    }
}

enum ListRowTrait {
    case insets(EdgeInsets?)
    case background(AnyView?)
    case separator(Visibility, VerticalEdge.Set)
    case separatorTint(Color?, VerticalEdge.Set)
    case badge(Text?)
    case selectionDisabled(Bool)

    func apply(to traits: inout ListRowTraits) {
        switch self {
        case .insets(let insets):
            traits.insets = insets
        case .background(let background):
            traits.background = background
        case .separator(let visibility, let edges):
            if edges.contains(.top) { traits.topSeparator = visibility }
            if edges.contains(.bottom) { traits.bottomSeparator = visibility }
        case .separatorTint(let color, _):
            traits.separatorTint = color
        case .badge(let badge):
            traits.badge = badge
        case .selectionDisabled(let isDisabled):
            traits.selectionDisabled = isDisabled
        }
    }
}

extension _ListRowTraitView: ListContentSource {
    func _listItems<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>) {
        walk.scoped { walk in
            trait.apply(to: &walk.traits)
            listItems(of: content, into: &walk)
        }
    }
}

extension View {
    /// The space around this row's content in a list, in place of the
    /// style's own.
    public func listRowInsets(_ insets: EdgeInsets?) -> some View {
        _ListRowTraitView(content: self, trait: .insets(insets))
    }

    /// A view behind this row in a list, in place of the style's own
    /// background. A selected row is still drawn selected over it.
    public func listRowBackground<V: View>(_ view: V?) -> some View {
        _ListRowTraitView(content: self, trait: .background(view.map { AnyView($0) }))
    }

    /// Shows or hides the rules above and below this row in a list.
    public func listRowSeparator(_ visibility: Visibility, edges: VerticalEdge.Set = .all) -> some View {
        _ListRowTraitView(content: self, trait: .separator(visibility, edges))
    }

    /// The colour of the rules above and below this row in a list.
    public func listRowSeparatorTint(_ color: Color?, edges: VerticalEdge.Set = .all) -> some View {
        _ListRowTraitView(content: self, trait: .separatorTint(color, edges))
    }

    /// A count on the trailing edge of this row in a list — the unread
    /// count beside a mailbox. Zero shows no badge.
    public func badge(_ count: Int) -> some View {
        _ListRowTraitView(content: self, trait: .badge(count == 0 ? nil : Text("\(count)")))
    }

    /// A label on the trailing edge of this row in a list.
    public func badge(_ label: Text?) -> some View {
        _ListRowTraitView(content: self, trait: .badge(label))
    }

    public func badge<S: StringProtocol>(_ label: S?) -> some View {
        _ListRowTraitView(content: self, trait: .badge(label.map { Text($0) }))
    }

    /// Keeps this row of a list or table from being selected.
    public func selectionDisabled(_ isDisabled: Bool = true) -> some View {
        _ListRowTraitView(content: self, trait: .selectionDisabled(isDisabled))
    }
}

// MARK: - In a picker

extension _ListRowTraitView: PickerContentSource {
    func _pickerEntries<SelectionValue: Hashable>(
        into entries: inout [PickerEntry<SelectionValue>],
        implicitTag: SelectionValue?
    ) {
        pickerEntries(of: content, into: &entries, implicitTag: implicitTag)
    }
}
