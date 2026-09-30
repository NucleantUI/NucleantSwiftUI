//
//  PreferenceModifiers.swift
//  NucleantUI
//
//  `.preference`, `.transformPreference` and `.onPreferenceChange`. The
//  first two are nodes that change what flows up through them (see
//  `PreferenceContent`); the third registers the node it builds with the
//  pass's effects, which read its subtree's value once the tree stands.
//

extension View {

    /// Sets this view's value for `key`, replacing whatever its own subtree
    /// set.
    ///
    /// ```swift
    /// Text(message.subject)
    ///     .preference(key: UnreadCountKey.self, value: message.isRead ? 0 : 1)
    /// ```
    public func preference<K: PreferenceKey>(key: K.Type = K.self, value: K.Value) -> some View {
        _ModifierView(content: self) { _ in PreferenceWriterContent<K>(value: value) }
    }

    /// Edits the value for `key` that this view's subtree produced, as it
    /// passes up through this view. `callback` starts from the key's
    /// `defaultValue` when nothing below set one.
    public func transformPreference<K: PreferenceKey>(
        _ key: K.Type = K.self,
        _ callback: @escaping (inout K.Value) -> Void
    ) -> some View {
        _ModifierView(content: self) { _ in PreferenceTransformContent<K>(transform: callback) }
    }

    /// Runs `action` with the value this view's subtree produces for `key`
    /// — once when the view appears, then whenever that value changes.
    ///
    /// Like `onAppear`, the action runs after the pass that produced the
    /// value, so a state write inside it lands in the next frame.
    ///
    /// ```swift
    /// Inbox()
    ///     .onPreferenceChange(UnreadCountKey.self) { unread = $0 }
    /// ```
    public func onPreferenceChange<K: PreferenceKey>(
        _ key: K.Type = K.self,
        perform action: @escaping @MainActor (K.Value) -> Void
    ) -> some View where K.Value: Equatable {
        _PreferenceChangeView<K, Self>(content: self, action: action)
    }
}

// MARK: - Nodes

/// `.preference(key:value:)`: the subtree's value for `K` is this one.
struct PreferenceWriterContent<K: PreferenceKey>: NodeContent, PreferenceContent {
    let value: K.Value

    func preference<Key: PreferenceKey>(_ key: Key.Type, below: Key.Value?) -> Key.Value? {
        guard key == K.self else { return below }
        return value as? Key.Value
    }
}

/// `.transformPreference(_:_:)`: the subtree's value for `K`, edited.
struct PreferenceTransformContent<K: PreferenceKey>: NodeContent, PreferenceContent {
    let transform: (inout K.Value) -> Void

    func preference<Key: PreferenceKey>(_ key: Key.Type, below: Key.Value?) -> Key.Value? {
        guard key == K.self else { return below }
        var value = (below as? K.Value) ?? K.defaultValue
        transform(&value)
        return value as? Key.Value
    }
}

/// `.onPreferenceChange`'s view: its content, in a node registered with
/// the pass's effects so the value beneath it is checked once the tree is
/// built.
@View
struct _PreferenceChangeView<K: PreferenceKey, Content: View>: View where K.Value: Equatable {
    let content: Content
    let action: @MainActor (K.Value) -> Void

    var body: Never { bodyUnavailable() }
}

extension _PreferenceChangeView: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let child = context.child(0) { ctx in buildNode(content, &ctx) }
        let node = ViewNode(content: PreferenceObserverContent(), children: [child])
        node.transitionTrait = child.transitionTrait
        node.gridCellTraits = child.gridCellTraits
        node.layoutValues = child.layoutValues
        context.effects.preferenceObservers.observe(
            PreferenceObservation(K.self, node: node, action: action),
            at: context.path
        )
        return node
    }
}

/// Lays out as what it wraps; it is only here to be observed.
struct PreferenceObserverContent: NodeContent {}
