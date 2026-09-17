//
//  MenuItems.swift
//  NucleantSwiftUI
//
//  Views as native menu rows. A `CommandMenu`'s content is a view tree, but
//  the platform wants `MenuBar.Item`s — so the structural views walk their
//  children, `Button` and `Divider` produce a row, and everything else is
//  skipped. Nothing is built or laid out: this reads stored fields only,
//  and never asks a view for its `body`, which would trip `@Environment`
//  and `@State` outside a tree.
//

import NucleantWindow

/// What the lowering pass carries down the tree: the environment as the
/// modifiers above the item set it — `.disabled` and `.keyboardShortcut`
/// are both environment writes.
struct MenuLowering {
    var environment = EnvironmentValues()
}

/// A view that contributes rows to a native menu.
@MainActor
protocol MenuItemSource {
    func _menuItems(_ lowering: inout MenuLowering) -> [MenuBar.Item]
}

@MainActor
func menuItems<V: View>(of view: V) -> [MenuBar.Item] {
    var lowering = MenuLowering()
    return menuItems(of: view, &lowering)
}

@MainActor
func menuItems<V: View>(of view: V, _ lowering: inout MenuLowering) -> [MenuBar.Item] {
    (view as? MenuItemSource)?._menuItems(&lowering) ?? []
}

/// A view with a title a menu row can show: `Text`, or a modifier over one.
@MainActor
protocol MenuTitled {
    var _menuTitle: String { get }
}

extension Text: MenuTitled {
    var _menuTitle: String { content }
}

extension _ModifierView: MenuTitled {
    var _menuTitle: String { (content as? MenuTitled)?._menuTitle ?? "" }
}

// MARK: - Rows

extension Button: MenuItemSource {
    func _menuItems(_ lowering: inout MenuLowering) -> [MenuBar.Item] {
        [.command(MenuBar.Command(
            title: (label as? MenuTitled)?._menuTitle ?? "",
            shortcut: lowering.environment.keyboardShortcut,
            isEnabled: lowering.environment.isEnabled,
            action: { action() }
        ))]
    }
}

extension Divider: MenuItemSource {
    func _menuItems(_ lowering: inout MenuLowering) -> [MenuBar.Item] {
        [.divider]
    }
}

// MARK: - Structure

extension EmptyView: MenuItemSource {
    func _menuItems(_ lowering: inout MenuLowering) -> [MenuBar.Item] {
        []
    }
}

extension TupleView: MenuItemSource {
    func _menuItems(_ lowering: inout MenuLowering) -> [MenuBar.Item] {
        var items: [MenuBar.Item] = []
        for view in repeat (each value) {
            items += menuItems(of: view, &lowering)
        }
        return items
    }
}

extension _ViewArray: MenuItemSource {
    func _menuItems(_ lowering: inout MenuLowering) -> [MenuBar.Item] {
        var items: [MenuBar.Item] = []
        for element in elements {
            items += menuItems(of: element, &lowering)
        }
        return items
    }
}

extension _ConditionalContent: MenuItemSource {
    func _menuItems(_ lowering: inout MenuLowering) -> [MenuBar.Item] {
        switch storage {
        case .trueContent(let content): return menuItems(of: content, &lowering)
        case .falseContent(let content): return menuItems(of: content, &lowering)
        }
    }
}

extension Optional: MenuItemSource where Wrapped: View {
    func _menuItems(_ lowering: inout MenuLowering) -> [MenuBar.Item] {
        switch self {
        case .some(let wrapped): return menuItems(of: wrapped, &lowering)
        case .none: return []
        }
    }
}

extension Group: MenuItemSource {
    func _menuItems(_ lowering: inout MenuLowering) -> [MenuBar.Item] {
        menuItems(of: content, &lowering)
    }
}

extension ForEach: MenuItemSource {
    func _menuItems(_ lowering: inout MenuLowering) -> [MenuBar.Item] {
        var items: [MenuBar.Item] = []
        for element in data {
            items += menuItems(of: build(element), &lowering)
        }
        return items
    }
}

extension AnyView: MenuItemSource {
    func _menuItems(_ lowering: inout MenuLowering) -> [MenuBar.Item] {
        lowerMenuItems(&lowering)
    }
}

extension _ModifierView: MenuItemSource {
    /// The modifier's environment change applies to the rows inside, as it
    /// would to the views: `.disabled(true)` over a `Group` greys out every
    /// button in it.
    func _menuItems(_ lowering: inout MenuLowering) -> [MenuBar.Item] {
        var inner = lowering
        modifyEnvironment?(&inner.environment)
        return menuItems(of: content, &inner)
    }
}
