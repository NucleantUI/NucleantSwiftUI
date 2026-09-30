//
//  TextEditingSupport.swift
//  NucleantUI
//
//  Pieces the editable text views keep between key presses: an undo
//  history, a click counter for double and triple clicks, and where words
//  begin and end.
//

import Foundation
#if os(macOS)
import AppKit
#endif

/// The text, caret and anchor of an editable view at one moment — what
/// undo puts back.
struct TextSnapshot: Equatable {
    var text: String
    var caret: Int
    var anchor: Int
}

/// One editable view's undo and redo stacks.
///
/// Typing runs and deletion runs coalesce into one step each, as AppKit's
/// do: the step ends when the caret is moved, something else edits the
/// text, or the view loses the keys. A class held in `@State`, so recording
/// a step does not rebuild the view by itself — the edit that goes with it
/// does.
@MainActor
final class TextUndoHistory {
    /// What kind of edit a step was, so runs of the same kind coalesce.
    enum Kind {
        case typing
        case deleting
        case other
    }

    private var undoStack: [TextSnapshot] = []
    private var redoStack: [TextSnapshot] = []
    /// The kind of the step still open for coalescing, if any.
    private var openKind: Kind?
    /// The text as the view last left it. Anything else found at undo time
    /// was written by someone else, and the stacks no longer describe it.
    private var expectedText: String?

    private static let limit = 200

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Record that the text is about to change from `before` to `after`.
    func record(_ before: TextSnapshot, after: String, kind: Kind) {
        if let expectedText, expectedText != before.text {
            clear()
        }
        if kind == .other || openKind != kind || undoStack.isEmpty {
            undoStack.append(before)
            if undoStack.count > Self.limit { undoStack.removeFirst() }
        }
        openKind = kind == .other ? nil : kind
        redoStack.removeAll()
        expectedText = after
    }

    /// The next edit starts a step of its own.
    func endCoalescing() {
        openKind = nil
    }

    /// The state to go back to from `current`, if there is one.
    func undo(from current: TextSnapshot) -> TextSnapshot? {
        guard isCurrent(current), let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        openKind = nil
        expectedText = previous.text
        return previous
    }

    /// The state an undo left, from `current`, if there is one.
    func redo(from current: TextSnapshot) -> TextSnapshot? {
        guard isCurrent(current), let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        openKind = nil
        expectedText = next.text
        return next
    }

    private func isCurrent(_ current: TextSnapshot) -> Bool {
        if let expectedText, expectedText != current.text {
            clear()
            return false
        }
        return true
    }

    private func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        openKind = nil
        expectedText = nil
    }
}

/// Counts presses that land close together in time and place — the second
/// is a double click, the third a triple. A press has no click count of its
/// own here, so the view keeps one.
@MainActor
final class TextClickCounter {
    private var lastTime: UInt64 = 0
    private var lastIndex = -1
    private(set) var count = 0
    /// The range the double or triple click selected, which a drag that
    /// follows extends from.
    var origin: Range<Int> = 0..<0

    /// Register a press at character offset `index`, and say which click of
    /// a run it is — 1, 2, 3 …
    func press(at index: Int) -> Int {
        let now = DispatchTime.now().uptimeNanoseconds
        let interval = UInt64(Self.doubleClickInterval * 1_000_000_000)
        if now - lastTime <= interval, abs(index - lastIndex) <= 1 {
            count += 1
        } else {
            count = 1
        }
        lastTime = now
        lastIndex = index
        return count
    }

    private static var doubleClickInterval: Double {
        #if os(macOS)
        NSEvent.doubleClickInterval
        #else
        0.5
        #endif
    }
}

/// Where words begin and end, for ⌥-arrows, ⌥-delete and double clicks.
enum TextWords {
    /// Start of the word before `index` — back over spaces, then over the word.
    static func start(in characters: [Character], before index: Int) -> Int {
        var i = index
        while i > 0, !isWordCharacter(characters[i - 1]) { i -= 1 }
        while i > 0, isWordCharacter(characters[i - 1]) { i -= 1 }
        return i
    }

    /// End of the word after `index`.
    static func end(in characters: [Character], after index: Int) -> Int {
        var i = index
        while i < characters.count, !isWordCharacter(characters[i]) { i += 1 }
        while i < characters.count, isWordCharacter(characters[i]) { i += 1 }
        return i
    }

    /// The word a double click at `index` selects: the run of word
    /// characters around it, or the run of anything else (spaces,
    /// punctuation) when it is not on a word. Never crosses a line break.
    static func range(in characters: [Character], at index: Int) -> Range<Int> {
        guard !characters.isEmpty else { return 0..<0 }
        // A click past the last character of a line picks what is before it.
        var probe = min(index, characters.count - 1)
        if probe > 0, characters[probe].isNewline || index == characters.count { probe -= 1 }
        guard !characters[probe].isNewline else { return index..<index }
        let kind = isWordCharacter(characters[probe])
        var lower = probe
        var upper = probe + 1
        while lower > 0, !characters[lower - 1].isNewline, isWordCharacter(characters[lower - 1]) == kind {
            lower -= 1
        }
        while upper < characters.count, !characters[upper].isNewline, isWordCharacter(characters[upper]) == kind {
            upper += 1
        }
        return lower..<upper
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}

/// Whether ⇧ is down now — a press has no modifiers of its own.
@MainActor
var textShiftHeld: Bool {
    #if os(macOS)
    NSEvent.modifierFlags.contains(.shift)
    #else
    false
    #endif
}

/// The printable part of what a key typed: not the function keys (arrows
/// and F-keys report characters in the private-use range U+F700–U+F8FF on
/// macOS), not control characters.
func printableCharacters(of typed: String) -> String {
    typed.filter { character in
        character.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }
}
