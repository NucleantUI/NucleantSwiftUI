//
//  EditCommandResponder.swift
//  NucleantUI
//
//  The Edit menu's commands, for the view that has the keys.
//
//  On macOS ⌘Z/⌘X/⌘C/⌘V/⌘A never arrive as key presses: they are the Edit
//  menu's key equivalents, and AppKit sends the menu item's action (`copy:`,
//  `paste:`, …) up the responder chain instead. The window's content view is
//  the first responder and knows nothing of views inside the tree, so this
//  responder sits right behind it and hands each action to `ViewHost`, which
//  gives it to the focused view (`FocusTarget.onEditCommand`).
//
//  It only answers for an action the focused view actually takes
//  (`responds(to:)`), so with nothing focused — or a view that doesn't edit —
//  the action carries on up the chain, and AppKit disables the menu item.
//

#if os(macOS)
import AppKit

@MainActor
final class EditCommandResponder: NSResponder {
    private unowned let host: ViewHost

    init(host: ViewHost) {
        self.host = host
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("EditCommandResponder is never decoded")
    }

    /// Put this responder right behind `view` in its window's chain.
    func insert(after view: NSView) {
        nextResponder = view.nextResponder
        view.nextResponder = self
    }

    private static let commands: [Selector: EditCommand] = [
        Selector(("undo:")): .undo,
        Selector(("redo:")): .redo,
        #selector(NSText.cut(_:)): .cut,
        #selector(NSText.copy(_:)): .copy,
        #selector(NSText.paste(_:)): .paste,
        #selector(NSText.selectAll(_:)): .selectAll,
    ]

    override func responds(to selector: Selector!) -> Bool {
        if let command = Self.commands[selector] {
            return host.canPerform(command)
        }
        return super.responds(to: selector)
    }

    // The sender is whatever sent the action — a menu item, a toolbar
    // button; only the command matters here.
    @objc func undo(_ sender: NSObject?) { host.perform(.undo) }
    @objc func redo(_ sender: NSObject?) { host.perform(.redo) }
    @objc func cut(_ sender: NSObject?) { host.perform(.cut) }
    @objc func copy(_ sender: NSObject?) { host.perform(.copy) }
    @objc func paste(_ sender: NSObject?) { host.perform(.paste) }
    @objc func selectAll(_ sender: NSObject?) { host.perform(.selectAll) }
}
#endif
