//
//  Commands.swift
//  NucleantUI
//
//  `Commands`, `CommandMenu`, `CommandGroup` and `Scene.commands(content:)`,
//  the SwiftUI shape over `NucleantWindow.MenuBar`. A `Commands` value lowers
//  itself into a `MenuBar`; the items inside a menu are views, turned into
//  rows by `MenuItems.swift`.
//

import NucleantWindow

/// Where a `CommandGroup` goes among the standard menus.
public typealias CommandGroupPlacement = MenuBar.Placement

/// A key and modifiers that trigger a command: `KeyboardShortcut("s")`,
/// `KeyboardShortcut(.delete, modifiers: [])`.
public typealias KeyboardShortcut = MenuBar.Shortcut

public typealias KeyEquivalent = MenuBar.Key

public typealias EventModifiers = MenuBar.Modifiers

/// Menus and their items, declared for a scene with `.commands { … }`.
///
/// ```swift
/// struct TransportCommands: Commands {
///     var body: some Commands {
///         CommandMenu("Transport") {
///             Button("Play") { player.play() }.keyboardShortcut(.space, modifiers: [])
///             Button("Stop") { player.stop() }.keyboardShortcut(".")
///         }
///         CommandGroup(replacing: .newItem) {}
///     }
/// }
/// ```
@MainActor
public protocol Commands {
    associatedtype Body: Commands

    @CommandsBuilder var body: Body { get }

    /// Add this value's menus and groups to `menuBar`. Composites go
    /// through `body`; `CommandMenu` and `CommandGroup` append directly.
    func _lower(into menuBar: MenuBar)
}

extension Commands {
    public func _lower(into menuBar: MenuBar) {
        body._lower(into: menuBar)
    }
}

extension Commands where Body == Never {
    public var body: Never {
        preconditionFailure("body should not be called on the primitive commands \(Self.self).")
    }
}

extension Never: Commands {}

/// No commands.
public struct EmptyCommands: Commands {
    public init() {}

    public var body: Never { fatalError() }

    public func _lower(into menuBar: MenuBar) {}
}

/// Several commands produced by one `@CommandsBuilder` block.
public struct TupleCommands<each Content: Commands>: Commands {
    public let value: (repeat each Content)

    public init(_ value: (repeat each Content)) {
        self.value = (repeat each value)
    }

    public var body: Never { fatalError() }

    public func _lower(into menuBar: MenuBar) {
        for commands in repeat (each value) {
            commands._lower(into: menuBar)
        }
    }
}

/// `Optional` is a set of commands when its wrapped type is — a bare `if`
/// in a builder.
extension Optional: Commands where Wrapped: Commands {
    public var body: Never { fatalError() }

    public func _lower(into menuBar: MenuBar) {
        self?._lower(into: menuBar)
    }
}

/// One branch of an `if`/`else` in a `@CommandsBuilder`.
extension _ConditionalContent: Commands where TrueContent: Commands, FalseContent: Commands {
    public var body: Never { fatalError() }

    public func _lower(into menuBar: MenuBar) {
        switch storage {
        case .trueContent(let commands): commands._lower(into: menuBar)
        case .falseContent(let commands): commands._lower(into: menuBar)
        }
    }
}

/// Constructs commands from closures. Multi-statement blocks become a
/// `TupleCommands`; `if`/`else` becomes `_ConditionalContent`; a bare `if`
/// becomes an `Optional`.
@resultBuilder
@MainActor
public struct CommandsBuilder {
    public static func buildExpression<Content: Commands>(_ content: Content) -> Content {
        content
    }

    public static func buildBlock() -> EmptyCommands {
        EmptyCommands()
    }

    public static func buildBlock<Content: Commands>(_ content: Content) -> Content {
        content
    }

    /// Everything past one child. Parameter packs cover any arity.
    @_disfavoredOverload
    public static func buildBlock<each Content: Commands>(
        _ content: repeat each Content
    ) -> TupleCommands<repeat each Content> {
        TupleCommands((repeat each content))
    }

    public static func buildIf<Content: Commands>(_ content: Content?) -> Content? {
        content
    }

    public static func buildEither<TrueContent: Commands, FalseContent: Commands>(
        first: TrueContent
    ) -> _ConditionalContent<TrueContent, FalseContent> {
        .init(storage: .trueContent(first))
    }

    public static func buildEither<TrueContent: Commands, FalseContent: Commands>(
        second: FalseContent
    ) -> _ConditionalContent<TrueContent, FalseContent> {
        .init(storage: .falseContent(second))
    }
}

/// A top-level menu of the app's own, placed after the standard Edit menu.
///
/// The content is views, as in a `.contextMenu`: `Button`s become rows,
/// `Divider` a rule, and `Group`, `ForEach` and `if` work as in any builder.
/// `.keyboardShortcut(_:)` on a button gives the row its key equivalent,
/// `.disabled(_:)` greys it out. Other views have no place in a native menu
/// and are skipped.
public struct CommandMenu<Content: View>: Commands {
    let name: String
    let content: Content

    public init(_ name: String, @ViewBuilder content: () -> Content) {
        self.name = name
        self.content = content()
    }

    public var body: Never { fatalError() }

    public func _lower(into menuBar: MenuBar) {
        menuBar.menus.append(MenuBar.Menu(title: name, items: menuItems(of: content)))
    }
}

/// Items put into one of the standard menus, relative to a group the
/// platform lays out itself: `CommandGroup(replacing: .newItem) {}` removes
/// New, `CommandGroup(after: .pasteboard) { … }` adds below Paste.
public struct CommandGroup<Content: View>: Commands {
    let placement: CommandGroupPlacement
    let position: MenuBar.Group.Position
    let content: Content

    public init(replacing placement: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {
        self.placement = placement
        self.position = .replacing
        self.content = addition()
    }

    public init(before placement: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {
        self.placement = placement
        self.position = .before
        self.content = addition()
    }

    public init(after placement: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {
        self.placement = placement
        self.position = .after
        self.content = addition()
    }

    public var body: Never { fatalError() }

    public func _lower(into menuBar: MenuBar) {
        menuBar.groups.append(MenuBar.Group(placement, position: position, items: menuItems(of: content)))
    }
}

// MARK: - Scene

extension Scene {
    /// Adds menus and menu items to the app's menu bar. Every scene's
    /// commands are collected into the one bar, in scene order.
    public func commands<Content: Commands>(@CommandsBuilder content: () -> Content) -> some Scene {
        CommandsScene(base: self, commands: content())
    }
}

/// `.commands(content:)`: the scene it wraps, plus commands.
struct CommandsScene<Base: Scene, Content: Commands>: Scene {
    let base: Base
    let commands: Content

    var body: Never { fatalError() }

    func _makeWindows() -> [HostingWindow] {
        base._makeWindows()
    }

    func _lowerCommands(into menuBar: MenuBar) {
        base._lowerCommands(into: menuBar)
        commands._lower(into: menuBar)
    }
}

// MARK: - Keyboard shortcuts

private struct KeyboardShortcutKey: EnvironmentKey {
    static let defaultValue: KeyboardShortcut? = nil
}

extension EnvironmentValues {
    /// The shortcut `.keyboardShortcut(_:)` set above this point. Read when
    /// a `Button` is lowered into a menu row; on screen it does nothing yet.
    var keyboardShortcut: KeyboardShortcut? {
        get { self[KeyboardShortcutKey.self] }
        set { self[KeyboardShortcutKey.self] = newValue }
    }
}

extension View {
    /// The key equivalent of this button when it is a menu row.
    public func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        keyboardShortcut(KeyboardShortcut(key, modifiers: modifiers))
    }

    public func keyboardShortcut(_ shortcut: KeyboardShortcut) -> some View {
        environment(\.keyboardShortcut, shortcut)
    }
}
