//
//  Navigation.swift
//  NucleantSwiftUI
//

/// The push/pop handle a `NavigationLink` reaches for.
///
/// A class, but a short-lived one: a fresh instance is made on every build,
/// wrapping the enclosing stack's `Binding`. The *state* lives in the stack's
/// `@State`, so pushing invalidates only the stack's subtree.
@MainActor
public final class NavigationRouter {

    /// One screen on the stack.
    struct Entry: Identifiable {
        let id: Int
        let title: String?
        let content: AnyView
    }

    private let entries: Binding<[Entry]>
    private let nextID: Binding<Int>

    init(entries: Binding<[Entry]>, nextID: Binding<Int>) {
        self.entries = entries
        self.nextID = nextID
    }

    public var depth: Int { entries.wrappedValue.count }

    func push(title: String?, content: AnyView) {
        let id = nextID.wrappedValue
        nextID.wrappedValue = id + 1
        entries.wrappedValue.append(Entry(id: id, title: title, content: content))
    }

    public func pop() {
        guard !entries.wrappedValue.isEmpty else { return }
        entries.wrappedValue.removeLast()
    }

    public func popToRoot() {
        entries.wrappedValue.removeAll()
    }
}

extension NavigationRouter: ViewInput {
    /// A fresh router is made on every build of the stack, so identity says
    /// nothing; what matters is whether it writes to the same state.
    public func _isEquivalent(to other: NavigationRouter) -> Bool {
        entries._isEquivalent(to: other.entries) && nextID._isEquivalent(to: other.nextID)
    }
}

private struct NavigationRouterKey: EnvironmentKey {
    static let defaultValue: NavigationRouter? = nil
}

extension EnvironmentValues {
    /// The enclosing `NavigationStack`, if there is one.
    public var navigationRouter: NavigationRouter? {
        get { self[NavigationRouterKey.self] }
        set { self[NavigationRouterKey.self] = newValue }
    }
}

/// A stack of screens with a title bar and a back button.
///
/// ```swift
/// NavigationStack("Library") {
///     List of links…
/// }
/// ```
///
/// Two deviations from SwiftUI, both for the same missing piece — there is no
/// preference system here, so a child cannot hand a value *up* to an ancestor:
///
/// * the root's title is given to `NavigationStack` rather than set with
///   `.navigationTitle` inside it;
/// * a pushed screen's title comes from the `NavigationLink` that pushed it.
@View
public struct NavigationStack<Root: View>: View {

    let title: String?
    let root: Root

    @State private var entries: [NavigationRouter.Entry] = []
    @State private var nextID: Int = 0

    public init(_ title: String? = nil, @ViewBuilder root: () -> Root) {
        self.title = title
        self.root = root()
    }

    public var body: some View {
        VStack(spacing: 0) {
            navigationBar

            // Every screen stays in the tree; only the top one is on screen.
            // A covered screen is parked — never laid out, drawn or hit
            // tested, and its shader slots are released — but it keeps its
            // identity, so its `@State` and scroll position are still there
            // on the way back. A screen that left the tree would lose them
            // at once, the way any departed view does.
            ZStack {
                root._parked(!entries.isEmpty)
                ForEach(entries) { entry in
                    entry.content._parked(entry.id != entries.last?.id)
                }
            }
        }
        .environment(\.navigationRouter, NavigationRouter(entries: $entries, nextID: $nextID))
    }

    private var currentTitle: String? {
        entries.last?.title ?? title
    }

    private var navigationBar: some View {
        HStack(spacing: 12) {
            if !entries.isEmpty {
                Text("‹ Back")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.blue)
                    .padding(horizontal: 10, vertical: 6)
                    .onTapGesture { entries.removeLast() }
            }

            Text(currentTitle ?? "")
                .font(.system(size: 17, weight: .semibold))
                // One line, truncated — a title bar that reflows its own
                // height as the window narrows is not a title bar, and a long
                // title would otherwise push the content down.
                .lineLimit(1)

            Spacer()
        }
        .padding(horizontal: 12, vertical: 10)
        // A stable bar height, independent of what the title happens to be.
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Color.secondaryBackground)
        .overlay(alignment: .bottom) {
            Color.separator.frame(height: 1)
        }
    }
}

/// A control that pushes a screen onto the enclosing `NavigationStack`.
///
/// ```swift
/// NavigationLink("Details") { DetailView() }
/// ```
public struct NavigationLink<Label: View, Destination: View>: View {

    let title: String?
    let destination: () -> Destination
    let label: Label

    @Environment(\.navigationRouter) private var router

    public init(
        title: String? = nil,
        @ViewBuilder destination: @escaping () -> Destination,
        @ViewBuilder label: () -> Label
    ) {
        self.title = title
        self.destination = destination
        self.label = label()
    }

    public var body: some View {
        label.onTapGesture {
            // Built at push time, not at link-build time: a destination that
            // reads state should see the state as it is when opened.
            router?.push(title: title, content: AnyView(destination()))
        }
    }
}

extension NavigationLink where Label == Text {
    /// A link whose label is its own title.
    public init(_ title: String, @ViewBuilder destination: @escaping () -> Destination) {
        self.init(title: title, destination: destination) {
            Text(title)
        }
    }
}
