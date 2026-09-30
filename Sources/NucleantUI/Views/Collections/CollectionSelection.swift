//
//  CollectionSelection.swift
//  NucleantUI
//
//  What `List` and `Table` have in common about choosing rows: the
//  selection binding in each shape SwiftUI takes it — none, one value, one
//  optional value, a set — and what a click, a ⌘-click, a ⇧-click and the
//  arrow keys do to it.
//

import Foundation

/// The selection a list or a table edits.
struct CollectionSelection<Value: Hashable>: ViewInput {

    enum Storage {
        case none
        case single(Binding<Value>)
        case optional(Binding<Value?>)
        case multiple(Binding<Set<Value>>)
    }

    let storage: Storage

    init(storage: Storage) {
        self.storage = storage
    }

    init(_ binding: Binding<Set<Value>>?) {
        self.storage = binding.map { .multiple($0) } ?? .none
    }

    init(_ binding: Binding<Value?>?) {
        self.storage = binding.map { .optional($0) } ?? .none
    }

    init(_ binding: Binding<Value>) {
        self.storage = .single(binding)
    }

    var isSelectable: Bool {
        if case .none = storage { return false }
        return true
    }

    var allowsMultiple: Bool {
        if case .multiple = storage { return true }
        return false
    }

    /// What is selected now.
    var values: Set<Value> {
        switch storage {
        case .none: return []
        case .single(let binding): return [binding.wrappedValue]
        case .optional(let binding): return binding.wrappedValue.map { [$0] } ?? []
        case .multiple(let binding): return binding.wrappedValue
        }
    }

    func contains(_ value: Value) -> Bool {
        switch storage {
        case .none: return false
        case .single(let binding): return binding.wrappedValue == value
        case .optional(let binding): return binding.wrappedValue == value
        case .multiple(let binding): return binding.wrappedValue.contains(value)
        }
    }

    /// Make `values` the selection. A selection of one value takes
    /// `primary`; one that can't be empty keeps what it had when handed
    /// nothing.
    func set(_ values: Set<Value>, primary: Value?) {
        switch storage {
        case .none:
            return
        case .single(let binding):
            guard let value = primary ?? values.first, binding.wrappedValue != value else { return }
            binding.wrappedValue = value
        case .optional(let binding):
            let value = primary.flatMap { values.contains($0) ? $0 : nil } ?? values.first
            guard binding.wrappedValue != value else { return }
            binding.wrappedValue = value
        case .multiple(let binding):
            guard binding.wrappedValue != values else { return }
            binding.wrappedValue = values
        }
    }

    /// Same kind of selection through the same binding.
    func _isEquivalent(to other: CollectionSelection<Value>) -> Bool {
        switch (storage, other.storage) {
        case (.none, .none): return true
        case let (.single(a), .single(b)): return a._isEquivalent(to: b)
        case let (.optional(a), .optional(b)): return a._isEquivalent(to: b)
        case let (.multiple(a), .multiple(b)): return a._isEquivalent(to: b)
        default: return false
        }
    }
}

/// Where a run of clicks and arrow keys stands: the row a ⇧-click or ⇧-arrow
/// extends from, the row the arrow keys move from, and the clicks counted
/// towards a double click. A class held in `@State`: none of it is drawn,
/// so moving it must not rebuild anything.
@MainActor
final class SelectionCursor<Value: Hashable> {
    var anchor: Value?
    var cursor: Value?

    private var lastClick: UInt64 = 0
    private var lastClicked: Value?

    /// Register a press on `value`; whether it completes a double click —
    /// a second press on the same row within half a second.
    func click(_ value: Value) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let isDouble = lastClicked == value && now - lastClick <= 500_000_000
        lastClick = isDouble ? 0 : now
        lastClicked = value
        return isDouble
    }
}

extension CollectionSelection {

    /// A press on the row `value`, among the selectable rows `order` as
    /// they stand top to bottom — with the modifier keys held for it.
    ///
    /// As on macOS: a click selects that row alone; ⌘-click adds it or
    /// takes it out (for a single optional selection, only out); ⇧-click
    /// selects the run from the last row clicked to this one.
    func press(_ value: Value, modifiers: EventModifiers, order: [Value], cursor: SelectionCursor<Value>) {
        switch storage {
        case .none:
            return
        case .multiple:
            var next = values
            if modifiers.contains(.command) {
                if next.contains(value) { next.remove(value) } else { next.insert(value) }
                cursor.anchor = value
            } else if modifiers.contains(.shift),
                      let anchor = cursor.anchor,
                      let from = order.firstIndex(of: anchor),
                      let to = order.firstIndex(of: value) {
                next = Set(order[min(from, to)...max(from, to)])
            } else {
                next = [value]
                cursor.anchor = value
            }
            cursor.cursor = value
            set(next, primary: value)
        case .optional:
            cursor.anchor = value
            cursor.cursor = value
            if modifiers.contains(.command), contains(value) {
                set([], primary: nil)
            } else {
                set([value], primary: value)
            }
        case .single:
            cursor.anchor = value
            cursor.cursor = value
            set([value], primary: value)
        }
    }

    /// ↑ (`step` −1) or ↓ (+1): the next row from the cursor becomes the
    /// selection — or, with ⇧ and room for more than one, the run from the
    /// anchor to it. `toEnd` goes all the way (Home, End, ⌥↑/↓). Returns
    /// the row moved to.
    @discardableResult
    func move(by step: Int, toEnd: Bool = false, extending: Bool, order: [Value], cursor: SelectionCursor<Value>) -> Value? {
        guard isSelectable, !order.isEmpty else { return nil }
        let selected = values
        // Start from the cursor if it is still part of the selection; else
        // from the selection's edge in the direction of travel.
        let start: Int
        if let current = cursor.cursor, selected.contains(current), let index = order.firstIndex(of: current) {
            start = index
        } else if step > 0, let last = order.lastIndex(where: { selected.contains($0) }) {
            start = last
        } else if step < 0, let first = order.firstIndex(where: { selected.contains($0) }) {
            start = first
        } else {
            start = step > 0 ? -1 : order.count
        }
        let target = toEnd ? (step > 0 ? order.count - 1 : 0) : min(max(start + step, 0), order.count - 1)
        let value = order[target]
        if extending, allowsMultiple, let anchor = cursor.anchor, let from = order.firstIndex(of: anchor) {
            set(Set(order[min(from, target)...max(from, target)]), primary: value)
        } else {
            cursor.anchor = value
            set([value], primary: value)
        }
        cursor.cursor = value
        return value
    }

    /// ⌘A: every selectable row, when more than one can be selected.
    func selectAll(_ order: [Value]) {
        guard allowsMultiple else { return }
        set(Set(order), primary: nil)
    }

    /// A press on no row at all: nothing selected, where that is allowed.
    func clear() {
        switch storage {
        case .optional, .multiple: set([], primary: nil)
        case .none, .single: return
        }
    }
}

// MARK: - Key codes

/// The virtual key codes a list or table answers to — the same codes the
/// text views read (`NSEvent.keyCode`).
enum CollectionKey {
    static let upArrow: UInt16 = 0x7E
    static let downArrow: UInt16 = 0x7D
    static let leftArrow: UInt16 = 0x7B
    static let rightArrow: UInt16 = 0x7C
    static let home: UInt16 = 0x73
    static let end: UInt16 = 0x77
    static let returnKey: UInt16 = 0x24
    static let enter: UInt16 = 0x4C
    static let delete: UInt16 = 0x33
    static let forwardDelete: UInt16 = 0x75
}

// MARK: - Delete command

private struct DeleteCommandKey: EnvironmentKey {
    static var defaultValue: DeleteCommandAction? { nil }
}

/// What `.onDeleteCommand` asked to run. A class, so the environment
/// compares it by identity rather than trying to compare a closure.
@MainActor
final class DeleteCommandAction {
    let perform: @MainActor () -> Void

    init(_ perform: @escaping @MainActor () -> Void) {
        self.perform = perform
    }
}

extension EnvironmentValues {
    /// The action Delete runs in a list or table below this point.
    var deleteCommand: DeleteCommandAction? {
        get { self[DeleteCommandKey.self] }
        set { self[DeleteCommandKey.self] = newValue }
    }
}

extension View {
    /// Runs `action` when Delete (or ⌦) is pressed while a list or table in
    /// this view has the keys — how selected rows are deleted on macOS.
    ///
    /// ```swift
    /// List(tracks, selection: $selection) { TrackRow($0) }
    ///     .onDeleteCommand { library.remove(selection) }
    /// ```
    public func onDeleteCommand(perform action: (@MainActor () -> Void)?) -> some View {
        environment(\.deleteCommand, action.map(DeleteCommandAction.init))
    }
}

// MARK: - Visibility and edges

/// Whether something is shown — `.automatic` leaves it to the container.
public enum Visibility: Hashable, CaseIterable, Sendable {
    case automatic
    case visible
    case hidden
}

/// The top or bottom edge of a row.
public enum VerticalEdge: Int8, Hashable, CaseIterable, Sendable {
    case top
    case bottom

    public struct Set: OptionSet, Hashable, Sendable {
        public let rawValue: Int8

        public init(rawValue: Int8) {
            self.rawValue = rawValue
        }

        public init(_ edge: VerticalEdge) {
            self.rawValue = 1 << edge.rawValue
        }

        public static let top = Set(.top)
        public static let bottom = Set(.bottom)
        public static let all: Set = [.top, .bottom]
    }
}

/// Whether rows alternate their background — `.alternatingRowBackgrounds()`.
public enum AlternatingRowBackgroundBehavior: Hashable, Sendable {
    case automatic
    case enabled
    case disabled
}

private struct AlternatingRowBackgroundsKey: EnvironmentKey {
    static let defaultValue = AlternatingRowBackgroundBehavior.automatic
}

extension EnvironmentValues {
    var alternatingRowBackgrounds: AlternatingRowBackgroundBehavior {
        get { self[AlternatingRowBackgroundsKey.self] }
        set { self[AlternatingRowBackgroundsKey.self] = newValue }
    }
}

extension View {
    /// Gives every other row of the lists and tables in this view a shaded
    /// background.
    public func alternatingRowBackgrounds(_ behavior: AlternatingRowBackgroundBehavior = .enabled) -> some View {
        environment(\.alternatingRowBackgrounds, behavior)
    }
}

// MARK: - Background prominence

/// How prominent the background behind a view is — `.increased` on a
/// selected row of a list or table that has the keys, where the row is
/// drawn on the tint. A view that picks its own colours reads it to stay
/// legible there:
///
/// ```swift
/// @Environment(\.backgroundProminence) private var prominence
///
/// Text(issue.key)
///     .foregroundColor(prominence == .increased ? .white : .secondary)
/// ```
public struct BackgroundProminence: Hashable, Sendable {
    let isIncreased: Bool

    public static let standard = BackgroundProminence(isIncreased: false)
    public static let increased = BackgroundProminence(isIncreased: true)
}

private struct BackgroundProminenceKey: EnvironmentKey {
    static let defaultValue = BackgroundProminence.standard
}

extension EnvironmentValues {
    public var backgroundProminence: BackgroundProminence {
        get { self[BackgroundProminenceKey.self] }
        set { self[BackgroundProminenceKey.self] = newValue }
    }
}

// MARK: - Colours

/// The colours a selected row is drawn in.
enum SelectionColors {
    /// Behind a selected row of a list or table that doesn't have the keys.
    static let unfocused = Color.dynamic(light: Color(white: 0.86), dark: Color(white: 0.3))
    /// Behind a selected sidebar row.
    static let sidebar = Color.dynamic(light: Color(white: 0, opacity: 0.1), dark: Color(white: 1, opacity: 0.16))
    /// Behind a selected sidebar row while the sidebar has the keys.
    static let sidebarFocused = Color.dynamic(light: Color(white: 0, opacity: 0.16), dark: Color(white: 1, opacity: 0.24))
    /// Every other row, when rows alternate.
    static let alternate = Color.dynamic(light: Color(white: 0, opacity: 0.035), dark: Color(white: 1, opacity: 0.04))
}
