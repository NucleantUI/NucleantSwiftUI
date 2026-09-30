//
//  KeyFocus.swift
//  NucleantUI
//
//  Where key presses go. A view that takes keys — a `TextField`, a
//  `TextureView` — puts a `FocusTarget` on its node; pressing the pointer on
//  such a node gives it the keys, pressing anywhere else takes them away.
//  `ViewHost` keeps the focused one and hands it every key press, with the
//  modifiers held as `EventModifiers` (Commands.swift). Tab and ⇧Tab move
//  the keys between the views that are tab stops, in layout order.
//

/// The standard editing commands — what the Edit menu sends (on macOS the
/// first-responder actions `undo:`, `cut:`, `copy:`, …) to the view that has
/// the keys.
public enum EditCommand: Hashable, Sendable, CaseIterable {
    case undo, redo, cut, copy, paste, selectAll
}

/// One key press or release, as the platform reported it: its virtual key
/// code (`NSEvent.keyCode` on macOS), the characters it typed, and the
/// modifiers held.
struct KeyEvent {
    let keyCode: UInt16
    let characters: String?
    let modifiers: EventModifiers
}

/// A node that can hold the keys.
///
/// Compared by path, as `HoverTarget` is: the focused view usually rebuilds
/// as it takes keys (a text field's text changes), which replaces this
/// object, and the focus must stay with the view. `ViewHost` looks the
/// current object up by path before each delivery.
@MainActor
final class FocusTarget {
    let path: [Int]
    let isEnabled: Bool
    let onFocusChange: @MainActor (Bool) -> Void
    let onKeyDown: @MainActor (KeyEvent) -> Void
    let onKeyUp: @MainActor (KeyEvent) -> Void
    /// The editing commands this view takes, and what it does with them. A
    /// command outside the set is left to the rest of the app (and its menu
    /// item disabled while this view has the keys).
    let editCommands: Set<EditCommand>
    let onEditCommand: @MainActor (EditCommand) -> Void
    /// Whether Tab and ⇧Tab from another tab stop can land here — a text
    /// field, a text editor; not a `TextureView`, which wants its own Tab.
    let isTabStop: Bool
    /// Whether Tab typed here is the view's own (a text editor inserts it)
    /// rather than a move to the next tab stop; ⌃Tab moves on either way.
    let insertsTab: Bool

    init(
        path: [Int],
        isEnabled: Bool,
        onFocusChange: @escaping @MainActor (Bool) -> Void,
        onKeyDown: @escaping @MainActor (KeyEvent) -> Void,
        onKeyUp: @escaping @MainActor (KeyEvent) -> Void = { _ in },
        editCommands: Set<EditCommand> = [],
        onEditCommand: @escaping @MainActor (EditCommand) -> Void = { _ in },
        isTabStop: Bool = false,
        insertsTab: Bool = false
    ) {
        self.path = path
        self.isEnabled = isEnabled
        self.onFocusChange = onFocusChange
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
        self.editCommands = editCommands
        self.onEditCommand = onEditCommand
        self.isTabStop = isTabStop
        self.insertsTab = insertsTab
    }
}

extension ViewNode {
    /// The focus target at `path` in this subtree, if that view still stands.
    func focusTarget(at path: [Int]) -> FocusTarget? {
        if let target = content.focusTarget, target.path == path { return target }
        for child in children {
            if let found = child.focusTarget(at: path) { return found }
        }
        return nil
    }

    /// Every enabled tab stop in this subtree, in the order they are laid
    /// out — what Tab walks through.
    func tabStops(into stops: inout [FocusTarget]) {
        guard !content.isParked, removal == nil else { return }
        if let target = content.focusTarget, target.isTabStop, target.isEnabled {
            stops.append(target)
        }
        for child in children {
            child.tabStops(into: &stops)
        }
    }
}
