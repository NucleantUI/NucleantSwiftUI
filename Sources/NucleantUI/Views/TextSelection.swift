//
//  TextSelection.swift
//  NucleantUI
//
//  What part of a text field's or text editor's text is selected, for a
//  caller that wants to read or set it (`TextField(_:text:selection:)`,
//  `TextEditor(text:selection:)`).
//

/// The selected range of an editable text, or where its insertion point is.
///
/// ```swift
/// @State private var selection: TextSelection?
///
/// TextEditor(text: $notes, selection: $selection)
/// ```
///
/// The indices are into the bound text. A selection whose indices no longer
/// fit the text (it was changed under it) is clamped to the text's end.
public struct TextSelection: Equatable, Hashable, Sendable {

    /// The selected indices. SwiftUI's `multiSelection(RangeSet<String.Index>)`
    /// is left out: the editors here hold one range, and `RangeSet` needs a
    /// newer system than this package's minimum.
    public enum Indices: Equatable, Hashable, Sendable {
        case selection(Range<String.Index>)
    }

    public var indices: Indices

    /// Which side of a line break an insertion point sits on. Always
    /// `.automatic` here — a caret at a soft line break is drawn at the start
    /// of the next line.
    public var affinity: TextSelectionAffinity { .automatic }

    /// A selection of `range`.
    public init(range: Range<String.Index>) {
        self.indices = .selection(range)
    }

    /// An insertion point — a caret with nothing selected — at `insertionPoint`.
    public init(insertionPoint: String.Index) {
        self.indices = .selection(insertionPoint..<insertionPoint)
    }

    /// Whether this is an insertion point rather than a range of text.
    public var isInsertion: Bool {
        switch indices {
        case .selection(let range): range.isEmpty
        }
    }
}

/// Which side of a line break a caret belongs to, where the same index is
/// both the end of one line and the start of the next.
public enum TextSelectionAffinity: Hashable, Sendable {
    case automatic
    case upstream
    case downstream
}

// MARK: - Offsets

extension TextSelection {
    /// The selection as character offsets into `text`, lower bound first.
    func offsets(in text: String) -> (lower: Int, upper: Int) {
        switch indices {
        case .selection(let range):
            (Self.offset(of: range.lowerBound, in: text), Self.offset(of: range.upperBound, in: text))
        }
    }

    /// A selection from `anchor` to `caret`, character offsets into `text`.
    init(anchor: Int, caret: Int, in text: String) {
        let lower = text.index(text.startIndex, offsetBy: max(0, min(min(anchor, caret), text.count)))
        let upper = text.index(text.startIndex, offsetBy: max(0, min(max(anchor, caret), text.count)))
        self.init(range: lower..<upper)
    }

    private static func offset(of index: String.Index, in text: String) -> Int {
        guard index < text.endIndex else { return text.count }
        return text.distance(from: text.startIndex, to: index)
    }
}

/// The caller's selection binding, if they passed one. A type of its own so
/// `@View`'s equivalence compares it by source, as `Binding` itself is —
/// `Optional<Binding<TextSelection?>>` would go through `Equatable` and
/// compare values.
struct TextSelectionSource: ViewInput {
    let binding: Binding<TextSelection?>?

    func _isEquivalent(to other: TextSelectionSource) -> Bool {
        switch (binding, other.binding) {
        case (nil, nil): true
        case let (mine?, theirs?): mine._isEquivalent(to: theirs)
        default: false
        }
    }

    /// The caret and anchor to show for `text`: the bound selection when
    /// there is one, `own` otherwise. A bound range that matches `own`'s keeps
    /// `own`'s direction (which end the caret is at); another range puts the
    /// caret at its upper end.
    func resolve(_ own: (caret: Int, anchor: Int), in text: String) -> (caret: Int, anchor: Int) {
        let count = text.count
        let clamped = (caret: min(own.caret, count), anchor: min(own.anchor, count))
        guard let selection = binding?.wrappedValue else { return clamped }
        let (lower, upper) = selection.offsets(in: text)
        if lower == min(clamped.caret, clamped.anchor), upper == max(clamped.caret, clamped.anchor) {
            return clamped
        }
        return (caret: upper, anchor: lower)
    }

    /// Tell the caller the selection is now `anchor`…`caret` in `text`.
    func write(caret: Int, anchor: Int, in text: String) {
        guard let binding else { return }
        let selection = TextSelection(anchor: anchor, caret: caret, in: text)
        if binding.wrappedValue != selection { binding.wrappedValue = selection }
    }
}
