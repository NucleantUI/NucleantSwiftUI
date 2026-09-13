//
//  Group.swift
//  NucleantSwiftUI
//

/// Collects views without affecting layout — its children behave as siblings
/// of whatever contains the group.
@View
public struct Group<Content: View>: View {
    public let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: Never { bodyUnavailable() }
}

extension Group: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        let child = context.child(0) { ctx in buildNode(content, &ctx) }
        return ViewNode(content: GroupContent(), children: [child])
    }
}
