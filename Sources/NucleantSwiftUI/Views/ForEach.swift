//
//  ForEach.swift
//  NucleantSwiftUI
//

/// Builds one view per element of a collection.
///
/// Identity comes from `id`, not position: reordering a list keeps each row's
/// `@State` with its own element, which is the whole reason SwiftUI insists on
/// an id here.
public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    public let data: Data
    let identify: (Data.Element) -> ID
    let build: (Data.Element) -> Content

    public init(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.data = data
        self.identify = { $0[keyPath: id] }
        self.build = content
    }

    public var body: Never { bodyUnavailable() }
}

extension ForEach where Data.Element: Identifiable, ID == Data.Element.ID {
    public init(
        _ data: Data,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.init(data, id: \.id, content: content)
    }
}

extension ForEach where Data == Range<Int>, ID == Int {
    public init(
        _ data: Range<Int>,
        @ViewBuilder content: @escaping (Int) -> Content
    ) {
        self.init(data, id: \.self, content: content)
    }
}

extension ForEach: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let path = context.path
        let children = data.map { element in
            // The identity hash, not the ordinal, is the path component — so a
            // row keeps its state when the collection is reordered.
            context.child(identify(element).hashValue) { ctx in
                // The row closure is user code and may read an `@Observable`
                // model; those reads are the ForEach's, since the closure is
                // what decides what each row is.
                let row = trackingObservation(at: path) { build(element) }
                return buildNode(row, &ctx)
            }
        }
        return ViewNode(content: GroupContent(), children: children)
    }
}
