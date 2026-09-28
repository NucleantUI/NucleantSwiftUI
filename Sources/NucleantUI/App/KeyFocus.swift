//
//  KeyFocus.swift
//  NucleantUI
//
//  Where key presses go. A view that takes keys — a `TextField`, a
//  `TextureView` — puts a `FocusTarget` on its node; pressing the pointer on
//  such a node gives it the keys, pressing anywhere else takes them away.
//  `ViewHost` keeps the focused one and hands it every key press, with the
//  modifiers held as `EventModifiers` (Commands.swift).
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

    init(
        path: [Int],
        isEnabled: Bool,
        onFocusChange: @escaping @MainActor (Bool) -> Void,
        onKeyDown: @escaping @MainActor (KeyEvent) -> Void,
        onKeyUp: @escaping @MainActor (KeyEvent) -> Void = { _ in },
        editCommands: Set<EditCommand> = [],
        onEditCommand: @escaping @MainActor (EditCommand) -> Void = { _ in }
    ) {
        self.path = path
        self.isEnabled = isEnabled
        self.onFocusChange = onFocusChange
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
        self.editCommands = editCommands
        self.onEditCommand = onEditCommand
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
}
