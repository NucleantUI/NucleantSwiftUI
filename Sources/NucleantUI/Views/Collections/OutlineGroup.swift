//
//  OutlineGroup.swift
//  NucleantUI
//

/// A tree of rows: each element of `data` shown by `content`, and each
/// element with children openable to show them, as deep as the tree goes.
///
/// ```swift
/// struct FileItem: Identifiable {
///     let id = UUID()
///     var name: String
///     var children: [FileItem]?     // nil: a file; non-nil: a folder
/// }
///
/// OutlineGroup(folders, children: \.children) { item in
///     Text(item.name)
/// }
/// ```
///
/// An element whose `children` is `nil` is a leaf; one whose `children` is
/// an array — empty or not — can be opened. In a `List` the tree becomes
/// the list's rows, each level indented under a chevron and selectable by
/// its element's id (`List(data, children:)` is the shorthand). Anywhere
/// else each element with children is a `DisclosureGroup` of its own.
@View
public struct OutlineGroup<Data: RandomAccessCollection, ID: Hashable, Parent: View, Leaf: View, Subgroup: View>: View {
    let data: Data
    let identify: (Data.Element) -> ID
    let children: (Data.Element) -> Data?
    let content: (Data.Element) -> Leaf

    init(
        data: Data,
        identify: @escaping (Data.Element) -> ID,
        children: @escaping (Data.Element) -> Data?,
        content: @escaping (Data.Element) -> Leaf,
        _viewID: ViewID
    ) {
        self.data = data
        self.identify = identify
        self.children = children
        self.content = content
        self._viewID = _viewID
    }
}

extension OutlineGroup where Parent == Leaf, Subgroup == DisclosureGroup<Leaf, OutlineSubgroupChildren> {

    public init<DataElement>(
        _ data: Data,
        id: KeyPath<DataElement, ID>,
        children: KeyPath<DataElement, Data?>,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: @escaping (DataElement) -> Leaf
    ) where DataElement == Data.Element {
        self.init(
            data: data,
            identify: { $0[keyPath: id] },
            children: { $0[keyPath: children] },
            content: content,
            _viewID: _viewID
        )
    }

    /// A tree from its root: the root itself, then its children.
    public init<DataElement>(
        _ root: DataElement,
        id: KeyPath<DataElement, ID>,
        children: KeyPath<DataElement, Data?>,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: @escaping (DataElement) -> Leaf
    ) where DataElement == Data.Element, Data == [DataElement] {
        self.init(
            data: [root],
            identify: { $0[keyPath: id] },
            children: { $0[keyPath: children] },
            content: content,
            _viewID: _viewID
        )
    }
}

extension OutlineGroup where Parent == Leaf, Subgroup == DisclosureGroup<Leaf, OutlineSubgroupChildren>, Data.Element: Identifiable, ID == Data.Element.ID {

    public init<DataElement>(
        _ data: Data,
        children: KeyPath<DataElement, Data?>,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: @escaping (DataElement) -> Leaf
    ) where DataElement == Data.Element {
        self.init(data, id: \.id, children: children, _viewID: _viewID, content: content)
    }

    public init<DataElement>(
        _ root: DataElement,
        children: KeyPath<DataElement, Data?>,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: @escaping (DataElement) -> Leaf
    ) where DataElement == Data.Element, Data == [DataElement] {
        self.init(root, id: \.id, children: children, _viewID: _viewID, content: content)
    }
}

extension OutlineGroup {
    /// Outside a list: a leaf as its content, an element with children as
    /// a disclosure group over its subtree.
    @ViewBuilder
    public var body: some View {
        let identify = self.identify
        let children = self.children
        let content = self.content
        ForEach(data.map { OutlineElement(id: identify($0), element: $0) }, id: \.id) { node in
            let element = node.element
            if let subtree = children(element) {
                DisclosureGroup {
                    OutlineSubgroupChildren(AnyView(OutlineGroup(
                        data: subtree,
                        identify: identify,
                        children: children,
                        content: content,
                        _viewID: ViewID(hash: identify(element).hashValue)
                    )))
                } label: {
                    content(element)
                }
            } else {
                content(element)
            }
        }
    }
}

/// An element with its id, for the `ForEach` over one level.
struct OutlineElement<ID: Hashable, Element> {
    let id: ID
    let element: Element
}

/// The children of one element of an outline group — a subtree, drawn as
/// another outline group. It erases that group's type, which is the same
/// as the one it is in: a type can't hold itself.
@View
public struct OutlineSubgroupChildren: View {
    let subtree: AnyView

    init(_ subtree: AnyView, _viewID: ViewID = #viewID) {
        self.subtree = subtree
        self._viewID = _viewID
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            subtree
        }
    }
}

// MARK: - In a list

extension OutlineGroup: ListContentSource {
    func _listItems<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>) {
        addRows(data, into: &walk)
    }

    /// A row per element, its id the element's; an element with children
    /// is a row that opens, and while open its children follow one level
    /// in.
    private func addRows<SelectionValue: Hashable>(_ elements: Data, into walk: inout ListWalk<SelectionValue>) {
        for element in elements {
            let id = identify(element)
            walk.child(id.hashValue) { walk in
                let tag = (id as? SelectionValue) ?? walk.implicitTag
                if let subtree = children(element) {
                    walk.appendDisclosure(content(element), tag: tag, isExpanded: nil) { walk in
                        addRows(subtree, into: &walk)
                    }
                } else {
                    walk.appendOutlineLeaf(content(element), tag: tag)
                }
            }
        }
    }
}
