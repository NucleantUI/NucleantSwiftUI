//
//  Section.swift
//  NucleantUI
//

/// Rows of a list, a form or a picker gathered under a header, with an
/// optional footer.
///
/// ```swift
/// List(selection: $mailbox) {
///     Section("Favorites") {
///         Text("Inbox").tag(Mailbox.inbox)
///         Text("Sent").tag(Mailbox.sent)
///     }
///     Section(isExpanded: $showsSmart) {
///         ForEach(smartMailboxes) { Text($0.name) }
///     } header: {
///         Text("Smart Mailboxes")
///     }
/// }
/// ```
///
/// How it looks is the container's: a heading over its rows in a list, a
/// rounded group in a grouped list or form, a heading in the label column
/// of a columns form. In a sidebar a section can be collapsed from its
/// header; given `isExpanded`, it can be in any list. Anywhere else a
/// section is just its header, content and footer, one after the other in
/// whatever stack holds it.
@View
public struct Section<Parent: View, Content: View, Footer: View>: View {
    let header: Parent
    let content: Content
    let footer: Footer
    let isExpandedSource: ExpansionSource

    public init(
        _viewID: ViewID = #viewID,
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Parent,
        @ViewBuilder footer: () -> Footer
    ) {
        self.header = header()
        self.content = content()
        self.footer = footer()
        self.isExpandedSource = ExpansionSource(binding: nil)
        self._viewID = _viewID
    }

    public init(header: Parent, footer: Footer, _viewID: ViewID = #viewID, @ViewBuilder content: () -> Content) {
        self.header = header
        self.content = content()
        self.footer = footer
        self.isExpandedSource = ExpansionSource(binding: nil)
        self._viewID = _viewID
    }

    init(header: Parent, content: Content, footer: Footer, isExpanded: Binding<Bool>?, _viewID: ViewID) {
        self.header = header
        self.content = content
        self.footer = footer
        self.isExpandedSource = ExpansionSource(binding: isExpanded)
        self._viewID = _viewID
    }

    public var body: some View {
        // Transparent, like a `Group`: in a stack the three are siblings.
        // The header and footer are marked, for a lazy stack or grid that
        // pins them.
        Group {
            _SectionPart(role: .header, content: header)
            if isExpandedSource.binding?.wrappedValue ?? true {
                content
            }
            _SectionPart(role: .footer, content: footer)
        }
    }
}

extension Section where Parent == EmptyView {
    public init(_viewID: ViewID = #viewID, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(header: EmptyView(), content: content(), footer: footer(), isExpanded: nil, _viewID: _viewID)
    }

    public init(footer: Footer, _viewID: ViewID = #viewID, @ViewBuilder content: () -> Content) {
        self.init(header: EmptyView(), content: content(), footer: footer, isExpanded: nil, _viewID: _viewID)
    }
}

extension Section where Footer == EmptyView {
    public init(_viewID: ViewID = #viewID, @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Parent) {
        self.init(header: header(), content: content(), footer: EmptyView(), isExpanded: nil, _viewID: _viewID)
    }

    public init(header: Parent, _viewID: ViewID = #viewID, @ViewBuilder content: () -> Content) {
        self.init(header: header, content: content(), footer: EmptyView(), isExpanded: nil, _viewID: _viewID)
    }

    /// A section whose rows show only while `isExpanded` is true — its
    /// header gets a chevron to open and close it.
    public init(
        isExpanded: Binding<Bool>,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Parent
    ) {
        self.init(header: header(), content: content(), footer: EmptyView(), isExpanded: isExpanded, _viewID: _viewID)
    }
}

extension Section where Parent == EmptyView, Footer == EmptyView {
    public init(_viewID: ViewID = #viewID, @ViewBuilder content: () -> Content) {
        self.init(header: EmptyView(), content: content(), footer: EmptyView(), isExpanded: nil, _viewID: _viewID)
    }
}

extension Section where Parent == Text, Footer == EmptyView {
    public init(_ title: String, _viewID: ViewID = #viewID, @ViewBuilder content: () -> Content) {
        self.init(header: Text(title), content: content(), footer: EmptyView(), isExpanded: nil, _viewID: _viewID)
    }

    public init<S: StringProtocol>(_ title: S, _viewID: ViewID = #viewID, @ViewBuilder content: () -> Content) {
        self.init(header: Text(title), content: content(), footer: EmptyView(), isExpanded: nil, _viewID: _viewID)
    }

    public init(
        _ title: String,
        isExpanded: Binding<Bool>,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: () -> Content
    ) {
        self.init(header: Text(title), content: content(), footer: EmptyView(), isExpanded: isExpanded, _viewID: _viewID)
    }

    public init<S: StringProtocol>(
        _ title: S,
        isExpanded: Binding<Bool>,
        _viewID: ViewID = #viewID,
        @ViewBuilder content: () -> Content
    ) {
        self.init(header: Text(title), content: content(), footer: EmptyView(), isExpanded: isExpanded, _viewID: _viewID)
    }
}

// MARK: - In a list or form

extension Section: ListContentSource {
    /// A header item, the rows, a footer item — the rows only while the
    /// section is open. A section can be closed when it has a binding for
    /// that, or when it is in a sidebar and has a header to close it from.
    func _listItems<SelectionValue: Hashable>(into walk: inout ListWalk<SelectionValue>) {
        walk.beginSection()
        let hasHeader = Parent.self != EmptyView.self
        let expansion: Binding<Bool>?
        if let binding = isExpandedSource.binding {
            expansion = binding
        } else if hasHeader && walk.sectionsCollapse {
            var key = 0
            walk.child(0) { key = $0.identity }
            expansion = walk.sectionExpansion(for: key)
        } else {
            expansion = nil
        }
        let isOpen = expansion?.wrappedValue ?? true
        if hasHeader {
            let header = self.header
            walk.child(0) { walk in
                walk.appendSectionItem(
                    .header,
                    AnyView(header),
                    disclosure: expansion.map { ListDisclosure(isExpanded: isOpen, binding: $0) }
                )
            }
        }
        if isOpen {
            walk.child(1) { listItems(of: content, into: &$0) }
        }
        if Footer.self != EmptyView.self {
            let footer = self.footer
            walk.child(2) { $0.appendSectionItem(.footer, AnyView(footer), disclosure: nil) }
        }
        walk.endSection()
    }
}

// MARK: - In a picker

extension Section: PickerContentSource {
    /// A picker's choices can be in sections: each section's choices, with
    /// a rule between sections.
    func _pickerEntries<SelectionValue: Hashable>(
        into entries: inout [PickerEntry<SelectionValue>],
        implicitTag: SelectionValue?
    ) {
        if let last = entries.last, last.option != nil {
            entries.append(.divider)
        }
        pickerEntries(of: content, into: &entries, implicitTag: implicitTag)
    }
}
