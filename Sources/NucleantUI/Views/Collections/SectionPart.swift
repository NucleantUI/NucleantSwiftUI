//
//  SectionPart.swift
//  NucleantUI
//

/// A `Section`'s header or footer, marked as such on its node so a lazy
/// stack or grid with `pinnedViews` can find it. Anywhere else it is
/// invisible: the node it hands back is its content's own.
@View
struct _SectionPart<Content: View>: View {
    let role: SectionTag.Role
    let content: Content

    var body: Never { bodyUnavailable() }
}

extension _SectionPart: BuiltinView {
    func makeNode(_ context: inout BuildContext) -> ViewNode {
        // A section's header and footer sit side by side in its body, so
        // their shared parent path names the section — and pairs them.
        let section = context.path.dropLast().hashValue
        let node = context.child(0) { ctx in buildNode(content, &ctx) }
        // An empty header is no node at all; nothing to pin.
        if !node.content.isTransparent {
            node.sectionTag = SectionTag(role: role, section: section)
        }
        return node
    }
}
