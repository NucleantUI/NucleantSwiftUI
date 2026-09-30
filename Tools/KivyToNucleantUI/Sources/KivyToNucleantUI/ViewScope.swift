//
//  ViewScope.swift
//  KivyToNucleantUI
//
//  One generated `@View` struct's worth of names: what kv's `root.`, `self.`
//  and ids point at once they are Swift.
//

import KvParser

/// A widget's place in the source — how a widget is recognised again between
/// the pass that names its state and the pass that writes it.
struct WidgetKey: Hashable {
    let line: Int
    let column: Int

    init(_ widget: KvWidget) {
        line = widget.line
        column = widget.column
    }
}

/// A stored property of the generated struct.
struct Member {
    enum Kind {
        /// `@State private var` — the view owns and changes it.
        case state
        /// `var name: Type = default` — the parent may pass it.
        case parameter
    }

    let name: String
    let type: String
    let initial: String
    let kind: Kind

    var declaration: String {
        switch kind {
        case .state: "@State private var \(name): \(type) = \(initial)"
        case .parameter: "var \(name): \(type) = \(initial)"
        }
    }
}

/// The `@State` behind an input widget — a Slider's `value`, a TextInput's
/// `text` — which kv reads as `the_id.value` and Swift reads as a name.
struct WidgetState {
    let widget: String
    /// The kv property it stands for: `value`, `text`, `active`, `state`.
    let kvProperty: String
    let name: String

    /// How kv's `id.<kvProperty>` reads in Swift.
    var read: String {
        widget == "ToggleButton" ? "(\(name) ? \"down\" : \"normal\")" : name
    }
}

final class ViewScope {
    let name: String
    /// The widget the struct's body starts from; `self.` there is `root.`.
    var rootKey: WidgetKey?
    private(set) var members: [Member] = []
    private(set) var ids: [String: WidgetState] = [:]
    private(set) var widgetStates: [WidgetKey: WidgetState] = [:]
    /// kv that has no Swift counterpart here, listed over the struct.
    private(set) var notes: [String] = []
    /// `#:set` names, visible everywhere.
    let constants: Set<String>

    init(name: String, constants: Set<String>) {
        self.name = name
        self.constants = constants
    }

    func member(named name: String) -> Member? {
        members.first { $0.name == name }
    }

    func add(_ member: Member) {
        guard self.member(named: member.name) == nil else { return }
        members.append(member)
    }

    /// A free member name built from `base`: `value`, `value2`, …
    func freshName(_ base: String) -> String {
        var candidate = base
        var n = 2
        while member(named: candidate) != nil {
            candidate = "\(base)\(n)"
            n += 1
        }
        return candidate
    }

    func bind(_ state: WidgetState, to key: WidgetKey, id: String?) {
        widgetStates[key] = state
        if let id { ids[id] = state }
    }

    func state(for key: WidgetKey) -> WidgetState? {
        widgetStates[key]
    }

    func note(_ text: String) {
        if !notes.contains(text) { notes.append(text) }
    }

    // MARK: - Resolving kv names

    /// Swift for a dotted kv path (`root.ids.volume.value`, `self.text`,
    /// `count`), or nil when it names something kv has and Swift doesn't.
    func resolve(_ path: [String], selfKey: WidgetKey?) -> String? {
        guard let head = path.first else { return nil }
        let rest = Array(path.dropFirst())
        switch head {
        case "root":
            return resolveFromRoot(rest.first == "ids" ? Array(rest.dropFirst()) : rest)
        case "ids":
            return resolveFromRoot(rest)
        case "self":
            guard let selfKey else { return nil }
            if let state = widgetStates[selfKey], rest == [state.kvProperty] {
                return state.read
            }
            return selfKey == rootKey ? resolveFromRoot(rest) : nil
        default:
            if constants.contains(head), rest.isEmpty { return head }
            return resolveFromRoot(path)
        }
    }

    private func resolveFromRoot(_ path: [String]) -> String? {
        guard let head = path.first else { return nil }
        let rest = Array(path.dropFirst())
        if let state = ids[head] {
            return rest == [state.kvProperty] ? state.read : nil
        }
        if let member = member(named: head.lowerCamel) {
            return ([member.name] + rest.map(\.lowerCamel)).joined(separator: ".")
        }
        return nil
    }
}
