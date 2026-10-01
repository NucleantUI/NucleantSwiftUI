//
//  FocusModifiers.swift
//  NucleantUI
//
//  `.focused`, `.focusable`, `.onKeyPress` and `.submitScope`. Where the
//  keys go is `ViewHost`'s (KeyFocus.swift); these mark views for it.
//

import Foundation

extension View {

    /// Ties `condition` to whether this view has the keys: it becomes
    /// `true` when the view (a text field, a `.focusable()` view, or one
    /// inside it) takes them and `false` when they go elsewhere — and
    /// setting it gives or takes the keys.
    public func focused(_ condition: FocusState<Bool>.Binding) -> some View {
        focused(condition, equals: true)
    }

    /// Ties `binding` to whether this view has the keys: it becomes `value`
    /// when the view takes them, and setting it to `value` gives them to
    /// this view.
    public func focused<Value: Hashable>(_ binding: FocusState<Value>.Binding, equals value: Value) -> some View {
        _ModifierView(content: self) { _ in
            FocusBindingContent(record: FocusBindingRecord(
                group: binding.identity,
                matches: { binding.peek() == value },
                take: { binding.wrappedValue = value },
                clear: { binding.wrappedValue = binding.empty },
                version: { binding.version }
            ))
        }
    }

    /// Lets this view take the keys: a press on it gives them, and Tab
    /// stops at it. What it does with them is `.onKeyPress`.
    ///
    /// ```swift
    /// board
    ///     .focusable()
    ///     .focused($boardFocused)
    ///     .onKeyPress(.leftArrow) { game.move(.left); return .handled }
    /// ```
    public func focusable(_ isFocusable: Bool = true) -> some View {
        focusable(isFocusable, onFocusChange: { _ in })
    }

    /// The same, telling `onFocusChange` when the view takes the keys and
    /// when it loses them.
    public func focusable(
        _ isFocusable: Bool = true,
        onFocusChange: @escaping @MainActor (_ isFocused: Bool) -> Void
    ) -> some View {
        _ModifierView(content: self) { context in
            FocusableContent(target: FocusTarget(
                path: context.path,
                isEnabled: isFocusable && context.environment.isEnabled,
                onFocusChange: onFocusChange,
                onKeyDown: { _ in },
                isTabStop: true
            ))
        }
    }

    // MARK: - Keys

    /// Runs `action` when `key` is pressed while this view, or one inside
    /// it, has the keys — held down, it runs again on each repeat. Return
    /// `.handled` to keep the press from the view that has the keys and
    /// from the `.onKeyPress` actions further out.
    public func onKeyPress(_ key: KeyEquivalent, action: @escaping @MainActor () -> KeyPress.Result) -> some View {
        onKeyPress(keys: [key], phases: [.down, .repeat]) { _ in action() }
    }

    /// Runs `action` for `key` in the given phases.
    public func onKeyPress(
        _ key: KeyEquivalent,
        phases: KeyPress.Phases,
        action: @escaping @MainActor (KeyPress) -> KeyPress.Result
    ) -> some View {
        onKeyPress(keys: [key], phases: phases, action: action)
    }

    /// Runs `action` for any of `keys` in the given phases.
    public func onKeyPress(
        keys: Set<KeyEquivalent>,
        phases: KeyPress.Phases = [.down, .repeat],
        action: @escaping @MainActor (KeyPress) -> KeyPress.Result
    ) -> some View {
        keyPressModifier(KeyPressHandler(phases: phases, matches: { keys.contains($0.key) }, action: action))
    }

    /// Runs `action` for a press whose characters are all in `characters`.
    public func onKeyPress(
        characters: CharacterSet,
        phases: KeyPress.Phases = [.down, .repeat],
        action: @escaping @MainActor (KeyPress) -> KeyPress.Result
    ) -> some View {
        keyPressModifier(KeyPressHandler(
            phases: phases,
            matches: { press in
                !press.characters.isEmpty && press.characters.unicodeScalars.allSatisfy(characters.contains)
            },
            action: action
        ))
    }

    /// Runs `action` for every key in the given phases.
    public func onKeyPress(
        phases: KeyPress.Phases = [.down, .repeat],
        action: @escaping @MainActor (KeyPress) -> KeyPress.Result
    ) -> some View {
        keyPressModifier(KeyPressHandler(phases: phases, matches: { _ in true }, action: action))
    }

    private func keyPressModifier(_ handler: KeyPressHandler) -> some View {
        _ModifierView(content: self) { _ in KeyPressContent(handler: handler) }
    }

    // MARK: - Submit

    /// Keeps a submission inside this view — a text field's Return — from
    /// running the `.onSubmit` actions outside it.
    public func submitScope(_ isBlocking: Bool = true) -> some View {
        _ModifierView(
            content: self,
            key: ["submitScope", isBlocking] as [AnyHashable],
            environment: { environment in
                if isBlocking { environment.submitActions = [] }
            },
            node: { context in EnvironmentContent(colorScheme: context.environment.colorScheme) }
        )
    }
}

/// A key press offered to `.onKeyPress`.
public struct KeyPress: Sendable {

    /// When in its life a key press is reported.
    public struct Phases: OptionSet, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// The key went down.
        public static let down = Phases(rawValue: 1 << 0)
        /// The key, held, repeated.
        public static let `repeat` = Phases(rawValue: 1 << 1)
        /// The key came up.
        public static let up = Phases(rawValue: 1 << 2)
        public static let all: Phases = [.down, .repeat, .up]
    }

    /// What an `.onKeyPress` action did with a press.
    public enum Result: Sendable {
        /// Used: nothing else sees it.
        case handled
        /// Not used: the next action out, then the view with the keys, sees it.
        case ignored
    }

    public var phase: Phases
    /// The key, without the shift that may have changed its character.
    public var key: KeyEquivalent
    /// What the key typed, modifiers applied.
    public var characters: String
    public var modifiers: EventModifiers

    public init(phase: Phases, key: KeyEquivalent, characters: String, modifiers: EventModifiers) {
        self.phase = phase
        self.key = key
        self.characters = characters
        self.modifiers = modifiers
    }

    /// The press a platform key event describes — `keyCode` is the virtual
    /// key code (`NSEvent.keyCode` on macOS, mapped to the same codes on
    /// the other platforms), as `KeyEvent` carries it.
    init(phase: Phases, keyCode: UInt16, characters: String?, modifiers: EventModifiers) {
        let typed = characters ?? ""
        let key: KeyEquivalent
        switch keyCode {
        case 0x24, 0x4C: key = .return
        case 0x35: key = .escape
        case 0x33: key = .delete
        case 0x30: key = .tab
        case 0x31: key = .space
        case 0x7E: key = .upArrow
        case 0x7D: key = .downArrow
        case 0x7B: key = .leftArrow
        case 0x7C: key = .rightArrow
        case 0x73: key = .home
        case 0x77: key = .end
        case 0x74: key = .pageUp
        case 0x79: key = .pageDown
        default:
            key = .character(typed.lowercased().first ?? " ")
        }
        self.init(phase: phase, key: key, characters: typed, modifiers: modifiers)
    }
}

/// One `.onKeyPress` action, with what it answers to.
@MainActor
final class KeyPressHandler {
    let phases: KeyPress.Phases
    let matches: @MainActor (KeyPress) -> Bool
    let action: @MainActor (KeyPress) -> KeyPress.Result

    init(
        phases: KeyPress.Phases,
        matches: @escaping @MainActor (KeyPress) -> Bool,
        action: @escaping @MainActor (KeyPress) -> KeyPress.Result
    ) {
        self.phases = phases
        self.matches = matches
        self.action = action
    }

    /// Offer `press`; whether it was used.
    func handle(_ press: KeyPress) -> Bool {
        guard phases.contains(press.phase), matches(press) else { return false }
        return action(press) == .handled
    }
}

/// One `.focused` mark: which focus state it belongs to, and how to read
/// and write that state for this view.
@MainActor
final class FocusBindingRecord {
    /// The focus state — every mark of one state is kept in step together.
    let group: ObjectIdentifier
    /// The state holds this view's value.
    let matches: @MainActor () -> Bool
    /// Make the state this view's value.
    let take: @MainActor () -> Void
    /// Make the state empty — `false`, `nil`.
    let clear: @MainActor () -> Void
    /// The state's write count, to tell the host's own writes from a view's.
    let version: @MainActor () -> UInt32

    init(
        group: ObjectIdentifier,
        matches: @escaping @MainActor () -> Bool,
        take: @escaping @MainActor () -> Void,
        clear: @escaping @MainActor () -> Void,
        version: @escaping @MainActor () -> UInt32
    ) {
        self.group = group
        self.matches = matches
        self.take = take
        self.clear = clear
        self.version = version
    }
}

/// `.focused`.
struct FocusBindingContent: NodeContent {
    let record: FocusBindingRecord

    var focusBinding: FocusBindingRecord? { record }
}

/// `.focusable()`.
struct FocusableContent: NodeContent {
    let target: FocusTarget

    var focusTarget: FocusTarget? { target }
}

/// `.onKeyPress`.
struct KeyPressContent: NodeContent {
    let handler: KeyPressHandler

    var keyPressHandler: KeyPressHandler? { handler }
}

extension ViewNode {

    /// The node holding the focus target at `path`, if that view still
    /// stands.
    func focusNode(at path: [Int]) -> ViewNode? {
        if let target = content.focusTarget, target.path == path { return self }
        for child in children {
            if let found = child.focusNode(at: path) { return found }
        }
        return nil
    }

    /// The nodes whose marks apply to this focused node, innermost first:
    /// the run of single-child modifiers inside it (`.onKeyPress { … }
    /// .focusable()` puts the action inside the focusable node) down to the
    /// next view that takes keys of its own, then the node itself and
    /// every node around it.
    var focusScope: [ViewNode] {
        var inside: [ViewNode] = []
        var probe = self
        while true {
            let inner = probe.layoutChildren
            guard inner.count == 1, inner[0].content.focusTarget == nil else { break }
            probe = inner[0]
            inside.append(probe)
        }
        var scope = Array(inside.reversed())
        var cursor: ViewNode? = self
        while let node = cursor {
            scope.append(node)
            cursor = node.parent
        }
        return scope
    }

    /// Every `.focused` mark standing in this subtree, with its node.
    func focusBindings(into records: inout [(record: FocusBindingRecord, node: ViewNode)]) {
        guard !content.isParked, removal == nil else { return }
        if let record = content.focusBinding {
            records.append((record, self))
        }
        for child in children {
            child.focusBindings(into: &records)
        }
    }

    /// The first enabled view under this node that takes keys — where the
    /// keys go when a focus state names this node's view.
    func firstFocusTarget() -> FocusTarget? {
        guard !content.isParked, removal == nil else { return nil }
        if let target = content.focusTarget, target.isEnabled { return target }
        for child in children {
            if let found = child.firstFocusTarget() { return found }
        }
        return nil
    }
}
