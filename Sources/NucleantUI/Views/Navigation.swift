//
//  Navigation.swift
//  NucleantUI
//

import Observation

/// Which screen of a `NavigationStack` a view is on — what `.navigationTitle`
/// files its title under.
enum NavigationScreenID: Hashable {
    case root
    /// The screen for `path[index]`. The value is part of the identity, so a
    /// different value pushed to the same depth is a different screen, with
    /// none of the last one's state or title left over.
    case value(index: Int, NavigationPath.Element)
    /// A screen pushed by a `NavigationLink` that carries its destination.
    case view(Int)
}

/// One screen above a stack's root.
struct NavigationScreen: Identifiable, Equatable {
    enum Content {
        /// Resolved through the destinations `.navigationDestination(for:)`
        /// registered.
        case value(NavigationPath.Element)
        /// Built by the link when it was tapped.
        case view(title: String?, AnyView)
    }

    let id: NavigationScreenID
    let content: Content

    /// What a screen shows is fixed by its identity — a value screen by its
    /// value, a view screen by the push that made it.
    static func == (lhs: NavigationScreen, rhs: NavigationScreen) -> Bool {
        lhs.id == rhs.id
    }
}

/// What a `NavigationStack` keeps across builds for its descendants to write
/// into: the destinations `.navigationDestination(for:)` registered and the
/// titles `.navigationTitle` set. A child can't hand a value *up* the tree —
/// there is no preference system — so it reaches this through the router in
/// the environment instead. One per stack, held in the stack's `@State`.
@MainActor
@Observable
final class NavigationStackStorage {

    /// Keyed by the type a value was pushed as.
    @ObservationIgnored
    private var destinations: [ObjectIdentifier: (AnyHashable) -> AnyView?] = [:]

    @ObservationIgnored
    private var titles: [NavigationScreenID: String] = [:]

    /// The one observed property. The bar reads it, so a screen setting a
    /// new title rebuilds the bar and nothing else; dropping the titles of
    /// screens that are gone doesn't bump it, since none of them is showing.
    private var titlesVersion = 0

    func register<D: Hashable>(_ type: D.Type, _ destination: @escaping (D) -> AnyView) {
        destinations[ObjectIdentifier(D.self)] = { value in
            (value as? D).map(destination)
        }
    }

    func destination(for element: NavigationPath.Element) -> AnyView? {
        destinations[element.type]?(element.value)
    }

    func title(for screen: NavigationScreenID) -> String? {
        _ = titlesVersion
        return titles[screen]
    }

    func setTitle(_ title: String, for screen: NavigationScreenID) {
        guard titles[screen] != title else { return }
        titles[screen] = title
        titlesVersion &+= 1
    }

    func retainTitles(for screens: Set<NavigationScreenID>) {
        guard titles.keys.contains(where: { !screens.contains($0) }) else { return }
        titles = titles.filter { screens.contains($0.key) }
    }
}

/// The push/pop handle a `NavigationLink` reaches for.
///
/// A class, but a short-lived one: a fresh instance is made on every build,
/// wrapping the enclosing stack's bindings. The *state* lives in the stack's
/// `@State` (or the caller's, for `NavigationStack(path:)`), so pushing
/// invalidates only the stack's subtree.
@MainActor
public final class NavigationRouter {

    /// A screen a destination link pushed. It sits directly above the path
    /// value that was on top when it was pushed — `anchor`, `nil` for the
    /// root — so pushing a value from it stacks the value above it, and it
    /// goes away if that value is popped out from under it.
    struct PushedView {
        let id: Int
        let depth: Int
        let anchor: NavigationPath.Element?
        let title: String?
        let content: AnyView

        func stands(on path: NavigationPath) -> Bool {
            depth == 0 ? anchor == nil
                : depth <= path.count && path.elements[depth - 1] == anchor
        }
    }

    private let path: Binding<NavigationPath>
    private let pushed: Binding<[PushedView]>
    private let nextID: Binding<Int>
    let storage: NavigationStackStorage

    init(
        path: Binding<NavigationPath>,
        pushed: Binding<[PushedView]>,
        nextID: Binding<Int>,
        storage: NavigationStackStorage
    ) {
        self.path = path
        self.pushed = pushed
        self.nextID = nextID
        self.storage = storage
    }

    /// Every screen above the root, bottom first.
    var screens: [NavigationScreen] {
        let path = self.path.wrappedValue
        let pushed = self.pushed.wrappedValue
        var screens: [NavigationScreen] = []
        // Depth 0 is the root; depth k the k-th path value. Each depth's
        // value first, then the views pushed on top of it.
        for depth in 0...path.elements.count {
            if depth > 0 {
                let element = path.elements[depth - 1]
                screens.append(NavigationScreen(id: .value(index: depth - 1, element), content: .value(element)))
            }
            for view in pushed where view.depth == depth && view.stands(on: path) {
                screens.append(NavigationScreen(id: .view(view.id), content: .view(title: view.title, view.content)))
            }
        }
        return screens
    }

    public var depth: Int { screens.count }

    func append(_ element: NavigationPath.Element) {
        path.wrappedValue.elements.append(element)
    }

    func push(title: String?, content: AnyView) {
        let path = self.path.wrappedValue
        let id = nextID.wrappedValue
        nextID.wrappedValue = id + 1
        var views = pushed.wrappedValue.filter { $0.stands(on: path) }
        views.append(PushedView(id: id, depth: path.count, anchor: path.elements.last, title: title, content: content))
        pushed.wrappedValue = views
    }

    public func pop() {
        switch screens.last?.id {
        case .view(let id):
            pushed.wrappedValue.removeAll { $0.id == id }
        case .value:
            path.wrappedValue.removeLast()
            let path = self.path.wrappedValue
            pushed.wrappedValue.removeAll { !$0.stands(on: path) }
        case .root, nil:
            break
        }
    }

    public func popToRoot() {
        pushed.wrappedValue.removeAll()
        path.wrappedValue = NavigationPath()
    }
}

extension NavigationRouter: ViewInput {
    /// A fresh router is made on every build of the stack, so identity says
    /// nothing; what matters is whether it writes to the same state.
    public func _isEquivalent(to other: NavigationRouter) -> Bool {
        path._isEquivalent(to: other.path)
            && pushed._isEquivalent(to: other.pushed)
            && nextID._isEquivalent(to: other.nextID)
            && storage === other.storage
    }
}

private struct NavigationRouterKey: EnvironmentKey {
    static let defaultValue: NavigationRouter? = nil
}

private struct NavigationScreenKey: EnvironmentKey {
    static var defaultValue: NavigationScreenID? { nil }
}

extension EnvironmentValues {
    /// The enclosing `NavigationStack`, if there is one.
    public var navigationRouter: NavigationRouter? {
        get { self[NavigationRouterKey.self] }
        set { self[NavigationRouterKey.self] = newValue }
    }

    /// The screen of the enclosing stack this view is on.
    var navigationScreen: NavigationScreenID? {
        get { self[NavigationScreenKey.self] }
        set { self[NavigationScreenKey.self] = newValue }
    }
}

/// A stack of screens with a title bar and a back button.
///
/// ```swift
/// NavigationStack {
///     RecipeList()
///         .navigationTitle("Recipes")
///         .navigationDestination(for: Recipe.self) { RecipeDetail(recipe: $0) }
/// }
/// ```
///
/// Screens are pushed by value (`NavigationLink(value:)`, or appending to the
/// `path` binding) and resolved through `.navigationDestination(for:)`, or
/// pushed as a view by a `NavigationLink` that carries its destination.
///
/// Two additions to SwiftUI's shape: the root's title can be given to the
/// stack (`NavigationStack("Library") { … }`), and a destination link's
/// `title:` names the screen it pushes. `.navigationTitle` on a screen
/// overrides either.
@View
public struct NavigationStack<Data, Root: View>: View {

    let title: String?
    let externalPath: Binding<NavigationPath>?
    let root: Root

    @State private var ownPath = NavigationPath()
    @State private var pushed: [NavigationRouter.PushedView] = []
    @State private var nextID: Int = 0
    @State private var storage = NavigationStackStorage()

    init(title: String?, path: Binding<NavigationPath>?, root: Root, _viewID: ViewID) {
        self.title = title
        self.externalPath = path
        self.root = root
        self._viewID = _viewID
    }

    public var body: some View {
        let router = NavigationRouter(
            path: externalPath ?? $ownPath,
            pushed: $pushed,
            nextID: $nextID,
            storage: storage
        )
        let screens = router.screens
        let top = screens.last
        let _ = storage.retainTitles(for: Set(screens.map(\.id) + [.root]))

        // Every screen stays in the tree; only the top one is on screen.
        // A covered screen is parked — never laid out, drawn or hit
        // tested, and its shader slots are released — but it keeps its
        // identity, so its `@State` and scroll position are still there
        // on the way back. A screen that left the tree would lose them
        // at once, the way any departed view does.
        ZStack {
            root
                .environment(\.navigationScreen, .root)
                ._parked(top != nil)
            ForEach(screens) { screen in
                NavigationScreenView(screen: screen, storage: storage)
                    ._parked(screen.id != top?.id)
            }
        }
        // The stack takes everything offered, bar or no bar — the bar is an
        // overlay and has no say in the size.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, NavigationBar.height)
        // An overlay rather than the first row of a VStack, so it is built
        // *after* the screens: a screen's `.navigationTitle` is filed while
        // the screen builds, and the bar then reads it in the same pass.
        .overlay(alignment: .top) {
            NavigationBar(
                screen: top?.id ?? .root,
                fallbackTitle: fallbackTitle(for: top),
                showsBack: top != nil,
                router: router,
                storage: storage
            )
        }
        .environment(\.navigationRouter, router)
    }

    private func fallbackTitle(for top: NavigationScreen?) -> String? {
        switch top?.content {
        case nil: title
        case .view(let title, _): title
        case .value: nil
        }
    }
}

extension NavigationStack where Data == NavigationPath {
    /// A stack that keeps its own path.
    public init(_ title: String? = nil, _viewID: ViewID = #viewID, @ViewBuilder root: () -> Root) {
        self.init(title: title, path: nil, root: root(), _viewID: _viewID)
    }

    /// A stack whose path the caller owns, of values of any mix of types.
    public init(path: Binding<NavigationPath>, _viewID: ViewID = #viewID, @ViewBuilder root: () -> Root) {
        self.init(title: nil, path: path, root: root(), _viewID: _viewID)
    }
}

extension NavigationStack
where Data: MutableCollection, Data: RandomAccessCollection, Data: RangeReplaceableCollection, Data.Element: Hashable {
    /// A stack whose path the caller owns, as a collection of one type.
    ///
    /// A value of another type pushed onto it (by a `NavigationLink(value:)`
    /// of that type) can't be stored in `Data`, and is dropped.
    public init(path: Binding<Data>, _viewID: ViewID = #viewID, @ViewBuilder root: () -> Root) {
        // The caller's slot is the source: two stacks over the same `$path`
        // are the same input, however the conversion closures differ.
        let navigationPath = Binding<NavigationPath>(
            source: path.source,
            get: { _ in NavigationPath(path.wrappedValue) },
            set: { newValue, _ in
                path.wrappedValue = Data(newValue.elements.compactMap { $0.value as? Data.Element })
            }
        )
        self.init(title: nil, path: navigationPath, root: root(), _viewID: _viewID)
    }
}

/// One screen above the root, resolved to its content.
@View
private struct NavigationScreenView {
    let screen: NavigationScreen
    let storage: NavigationStackStorage

    var body: some View {
        Group {
            switch screen.content {
            case .value(let element):
                // No destination registered for this type: an empty screen,
                // as SwiftUI shows.
                if let destination = storage.destination(for: element) {
                    destination
                }
            case .view(_, let content):
                content
            }
        }
        .environment(\.navigationScreen, screen.id)
    }
}

@View
private struct NavigationBar {
    static let height: Double = 44

    let screen: NavigationScreenID
    let fallbackTitle: String?
    let showsBack: Bool
    let router: NavigationRouter
    let storage: NavigationStackStorage

    var body: some View {
        HStack(spacing: 12) {
            if showsBack {
                Text("‹ Back")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.blue)
                    .padding(horizontal: 10, vertical: 6)
                    .onTapGesture { router.pop() }
            }

            Text(storage.title(for: screen) ?? fallbackTitle ?? "")
                .font(.system(size: 17, weight: .semibold))
                // One line, truncated — a title bar that reflows its own
                // height as the window narrows is not a title bar, and a long
                // title would otherwise push the content down.
                .lineLimit(1)

            Spacer()
        }
        .padding(horizontal: 12, vertical: 0)
        // A fixed height: the screens are inset by exactly this much.
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
        .background(Color.secondaryBackground)
        .overlay(alignment: .bottom) {
            Color.separator.frame(height: 1)
        }
    }
}

/// A control that pushes a screen onto the enclosing `NavigationStack`.
///
/// ```swift
/// NavigationLink("Details") { DetailView() }          // pushes the view
/// NavigationLink(recipe.name, value: recipe)          // pushes the value
/// ```
///
/// A value link's screen comes from the `.navigationDestination(for:)` for
/// the value's type. A `nil` value makes the link do nothing.
@View
public struct NavigationLink<Label: View, Destination: View>: View {

    let title: String?
    let destination: (() -> Destination)?
    let value: NavigationPath.Element?
    let label: Label

    @Environment(\.navigationRouter) private var router

    init(
        title: String?,
        destination: (() -> Destination)?,
        value: NavigationPath.Element?,
        label: Label,
        _viewID: ViewID
    ) {
        self.title = title
        self.destination = destination
        self.value = value
        self.label = label
        self._viewID = _viewID
    }

    public init(
        title: String? = nil,
        _viewID: ViewID = #viewID,
        @ViewBuilder destination: @escaping () -> Destination,
        @ViewBuilder label: () -> Label
    ) {
        self.init(title: title, destination: destination, value: nil, label: label(), _viewID: _viewID)
    }

    public var body: some View {
        label.onTapGesture {
            if let value {
                router?.append(value)
            } else if let destination {
                // Built at push time, not at link-build time: a destination
                // that reads state should see the state as it is when opened.
                router?.push(title: title, content: AnyView(destination()))
            }
        }
    }
}

extension NavigationLink where Label == Text {
    /// A link whose label is its own title.
    public init(_ title: String, _viewID: ViewID = #viewID, @ViewBuilder destination: @escaping () -> Destination) {
        self.init(title: title, destination: destination, value: nil, label: Text(title), _viewID: _viewID)
    }
}

extension NavigationLink where Destination == Never {
    /// A link that pushes `value`, shown by the `.navigationDestination(for:)`
    /// for its type.
    public init<P: Hashable>(value: P?, _viewID: ViewID = #viewID, @ViewBuilder label: () -> Label) {
        self.init(title: nil, destination: nil, value: value.map(NavigationPath.Element.init), label: label(), _viewID: _viewID)
    }
}

extension NavigationLink where Label == Text, Destination == Never {
    /// A value link whose label is `title`.
    public init<S: StringProtocol, P: Hashable>(_ title: S, value: P?, _viewID: ViewID = #viewID) {
        self.init(
            title: nil,
            destination: nil,
            value: value.map(NavigationPath.Element.init),
            label: Text(title),
            _viewID: _viewID
        )
    }
}
