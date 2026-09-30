//
//  SelectionContextMenu.swift
//  NucleantUI
//
//  `.contextMenu(forSelectionType:menu:primaryAction:)`: a menu for the
//  rows of a list or table, handed the rows it is for, and the action a
//  double click or Return runs on the selection.
//

extension View {
    /// Adds a menu for the rows of the lists and tables in this view, and
    /// an action for opening them.
    ///
    /// ```swift
    /// Table(issues, selection: $selection) { … }
    ///     .contextMenu(forSelectionType: Issue.ID.self) { ids in
    ///         Button("Close") { tracker.close(ids) }
    ///         Button("Delete") { tracker.delete(ids) }
    ///     } primaryAction: { ids in
    ///         tracker.open(ids)
    ///     }
    /// ```
    ///
    /// A right click on a selected row opens the menu for the whole
    /// selection; on a row that isn't selected, for that row alone; below
    /// the rows, for none. `primaryAction` runs on a double click, and on
    /// Return while the list or table has the keys. `itemType` must be the
    /// list's or table's selection type — the menu is left out otherwise.
    public func contextMenu<I: Hashable, M: View>(
        forSelectionType itemType: I.Type = I.self,
        @ViewBuilder menu: @escaping (Set<I>) -> M,
        primaryAction: ((Set<I>) -> Void)? = nil
    ) -> some View {
        environment(
            \.selectionContextMenu,
            SelectionContextMenuBox(TypedSelectionContextMenu(menu: menu, primaryAction: primaryAction))
        )
    }
}

/// The menu as the environment holds it: one type whatever the item type,
/// the menu itself in a subclass that knows it.
struct SelectionContextMenuBox: ViewInput {
    let storage: SelectionContextMenuStorage

    init(_ storage: SelectionContextMenuStorage) {
        self.storage = storage
    }

    /// The same menu object. A new one comes with every build of the view
    /// that set it, which is also when its closures may have changed.
    func _isEquivalent(to other: SelectionContextMenuBox) -> Bool {
        storage === other.storage
    }
}

@MainActor
class SelectionContextMenuStorage {
    /// The menu for `values`, or `nil` when they aren't this menu's type.
    func items<V: Hashable>(for values: Set<V>) -> AnyView? {
        fatalError("SelectionContextMenuStorage is abstract")
    }

    func runPrimaryAction<V: Hashable>(_ values: Set<V>) {
        fatalError("SelectionContextMenuStorage is abstract")
    }
}

final class TypedSelectionContextMenu<I: Hashable, M: View>: SelectionContextMenuStorage {
    let menu: (Set<I>) -> M
    let primaryAction: ((Set<I>) -> Void)?

    init(menu: @escaping (Set<I>) -> M, primaryAction: ((Set<I>) -> Void)?) {
        self.menu = menu
        self.primaryAction = primaryAction
    }

    override func items<V: Hashable>(for values: Set<V>) -> AnyView? {
        guard let values = values as? Set<I> else { return nil }
        return AnyView(menu(values))
    }

    override func runPrimaryAction<V: Hashable>(_ values: Set<V>) {
        guard let values = values as? Set<I> else { return }
        primaryAction?(values)
    }
}

private struct SelectionContextMenuKey: EnvironmentKey {
    static var defaultValue: SelectionContextMenuBox? { nil }
}

extension EnvironmentValues {
    /// The menu for the rows of lists and tables below this point.
    var selectionContextMenu: SelectionContextMenuBox? {
        get { self[SelectionContextMenuKey.self] }
        set { self[SelectionContextMenuKey.self] = newValue }
    }
}
