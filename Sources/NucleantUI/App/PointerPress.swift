//
//  PointerPress.swift
//  NucleantUI
//

/// The modifier keys held at the latest press of the primary pointer.
///
/// A `HitTarget`'s `onPress` gets only a point; a list or table choosing
/// between a click, a ⌘-click and a ⇧-click reads the keys here. Set by
/// `ViewHost.pointerDown` before any target hears of the press; `[]` on a
/// host whose platform reports none (touch).
@MainActor
enum PointerPress {
    static var modifiers: EventModifiers = []
}
