//
//  Popover.swift
//  NucleantSwiftUI
//
//  `.popover(isPresented:content:)`. The modifier records where its view is
//  placed; while the binding is true the host draws the content on a panel
//  in its overlay slot — over the whole window, clipped by nothing — with
//  an arrow pointing at the view, and a scrim under it that closes it on a
//  press anywhere else. The panel goes above the view when there is room,
//  else below, else beside it.
//

import Observation

extension View {

    /// Presents `content` in a popover anchored to this view while
    /// `isPresented` is true.
    ///
    /// ```swift
    /// Button("Options") { showOptions = true }
    ///     .popover(isPresented: $showOptions) {
    ///         VStack {
    ///             Text("Gain")
    ///             Fader(level: $gain)
    ///             Button("Done") { showOptions = false }
    ///         }
    ///     }
    /// ```
    ///
    /// The content is whatever you build; buttons in it are ordinary
    /// buttons. The panel is placed above the view, or below it when the
    /// space above is short, or to its trailing then leading side when
    /// neither fits — always inside the window — and carries an arrow that
    /// points at the view. A press outside sets `isPresented` false and
    /// goes no further.
    public func popover<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        PopoverModifier(content: self, isPresented: isPresented, popover: AnyView(content()))
    }
}

/// `.popover(isPresented:content:)`: keeps the host's list of open popovers
/// in step with the binding, and records the anchor's frame for the panel
/// to hang off.
struct PopoverModifier<Content: View>: View {
    let content: Content
    let isPresented: Binding<Bool>
    let popover: AnyView

    /// Identity across rebuilds, and where the view was placed. A class so
    /// the same handle survives the rebuilds the binding causes.
    @State private var handle = PopoverHandle()
    @Environment(\.popoverPresenter) private var presenter

    var body: some View {
        if let presenter {
            handle.presenter = presenter
            if isPresented.wrappedValue {
                let isPresented = self.isPresented
                let id = handle.id
                presenter.present(PopoverPresenter.Popover(
                    id: id,
                    anchor: handle,
                    content: popover,
                    // Taken off the list at once, so the overlay is dirty
                    // this frame; the binding follows on the next.
                    dismiss: {
                        presenter.dismiss(id: id)
                        isPresented.wrappedValue = false
                    }
                ))
            } else {
                presenter.dismiss(id: handle.id)
            }
        }
        return content._recordFrame(into: handle)
    }
}

/// See `PopoverModifier.handle`.
@MainActor
final class PopoverHandle: FrameBox {
    var id: ObjectIdentifier { ObjectIdentifier(self) }
    weak var presenter: PopoverPresenter?

    override init() {}

    /// The list holds the handle weakly, so a view that leaves the tree
    /// while presenting takes its popover with it — the `@State` slot was
    /// the last thing holding this.
    deinit {
        guard let presenter else { return }
        let id = ObjectIdentifier(self)
        MainActor.assumeIsolated { presenter.dismiss(id: id) }
    }
}

// MARK: - The host's list

/// The popovers open in a host, for its overlay to draw. One per host, in
/// the environment of every tree it builds.
///
/// `@Observable`, so the overlay — which reads `popovers` — is rebuilt when
/// one opens or closes, and only it.
@MainActor @Observable
public final class PopoverPresenter {

    /// One open popover: what it holds, the view it hangs off, and how to
    /// close it.
    struct Popover: Identifiable {
        let id: ObjectIdentifier
        weak var anchor: PopoverHandle?
        let content: AnyView
        let dismiss: @MainActor () -> Void
    }

    /// What the overlay reads. Innermost last.
    private(set) var popovers: [Popover] = []

    /// The same list, read without being tracked — `present` runs inside
    /// the modifier's own build, and a tracked read there would make the
    /// modifier a reader of what it writes.
    @ObservationIgnored private var entries: [Popover] = []

    init() {}

    /// Open `popover`, or replace the one already open with its id.
    func present(_ popover: Popover) {
        if let index = entries.firstIndex(where: { $0.id == popover.id }) {
            entries[index] = popover
        } else {
            entries.append(popover)
        }
        popovers = entries
    }

    /// Close the popover with `id`, if it is open.
    func dismiss(id: ObjectIdentifier) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        popovers = entries
    }
}

extension PopoverPresenter: ViewInput {
    /// One per host, for its lifetime.
    public func _isEquivalent(to other: PopoverPresenter) -> Bool {
        self === other
    }
}

private struct PopoverPresenterKey: EnvironmentKey {
    static let defaultValue: PopoverPresenter? = nil
}

extension EnvironmentValues {
    /// The host's list of open popovers, set for every tree it builds.
    public var popoverPresenter: PopoverPresenter? {
        get { self[PopoverPresenterKey.self] }
        set { self[PopoverPresenterKey.self] = newValue }
    }
}

// MARK: - The overlay

/// What `ViewHost` puts over the tree while popovers are open: a scrim
/// that closes the innermost on any press, and each popover's panel
/// placed around the view it hangs off.
struct PopoverOverlay: View {
    let presenter: PopoverPresenter

    var body: some View {
        let popovers = presenter.popovers
        return ZStack(alignment: .topLeading) {
            if let innermost = popovers.last {
                // Pressing outside closes the popover and goes no further —
                // the press is not delivered to what is under the scrim.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ._hitTarget(HitTarget(onPress: { _ in innermost.dismiss() }))
            }
            ForEach(popovers) { popover in
                PopoverPanel(content: popover.content)
                    ._popoverPlaced(around: popover.anchor)
            }
        }
    }
}

/// The content on a panel.
struct PopoverPanel: View {
    let content: AnyView

    static let cornerRadius = 10.0
    static let inset = 12.0

    var body: some View {
        content
            .padding(Self.inset)
            .background(Color.secondaryBackground)
            .border(Color.separator, cornerRadius: Self.cornerRadius)
            .cornerRadius(Self.cornerRadius)
    }
}

extension View {
    /// Places this view at its own size beside `anchor`'s frame — above it
    /// when there is room, else below, else trailing, else leading — kept
    /// inside the parent's rect, and draws an arrow from it to the anchor.
    func _popoverPlaced(around anchor: PopoverHandle?) -> some View {
        _ModifierView(content: self) { _ in PopoverPlacementContent(anchor: anchor) }
    }
}

/// `_popoverPlaced(around:)`: fills what it is offered, and puts its child
/// on the first side of the anchor that has room for it.
struct PopoverPlacementContent: NodeContent {
    weak var anchor: PopoverHandle?

    static let arrowWidth = 24.0
    static let arrowHeight = 12.0
    /// Between the anchor's edge and the arrow's tip, so the arrow reads
    /// as pointing at the view rather than touching it.
    static let tipGap = 6.0
    /// From the anchor's edge to the panel's.
    static var spacing: Double { arrowHeight + tipGap }
    /// Kept from the window's edges.
    static let margin = 8.0

    func sizeThatFits(_ proposal: ProposedSize, node: ViewNode) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        guard let child = node.singleChild, let anchor else { return }
        let target = anchor.frame
        let available = rect.insetBy(Self.margin)
        let spacing = Self.spacing

        var size = child.sizeThatFits(.unspecified)
        size.width = min(size.width, available.width)
        size.height = min(size.height, available.height)

        let edge: Edge
        if target.minY - spacing - size.height >= available.minY {
            edge = .top
        } else if target.maxY + spacing + size.height <= available.maxY {
            edge = .bottom
        } else if target.maxX + spacing + size.width <= available.maxX {
            edge = .trailing
        } else if target.minX - spacing - size.width >= available.minX {
            edge = .leading
        } else {
            // Nowhere fits: the taller side, and the panel is pulled inside
            // the window over the anchor.
            edge = target.midY >= rect.midY ? .top : .bottom
        }

        var origin: Point
        switch edge {
        case .top:
            origin = Point(x: target.midX - size.width / 2, y: target.minY - spacing - size.height)
        case .bottom:
            origin = Point(x: target.midX - size.width / 2, y: target.maxY + spacing)
        case .trailing:
            origin = Point(x: target.maxX + spacing, y: target.midY - size.height / 2)
        case .leading:
            origin = Point(x: target.minX - spacing - size.width, y: target.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, available.minX), available.maxX - size.width)
        origin.y = min(max(origin.y, available.minY), available.maxY - size.height)
        let panel = Rect(origin: origin, size: size)

        // Proposed its final size, so content with `maxWidth: .infinity`
        // stretches to the panel rather than to its own label.
        child.place(in: panel, proposal: ProposedSize(size), context: context, into: &list)
        appendArrow(on: edge, of: panel, toward: target, context: context, into: &list)
    }

    /// The arrow: a triangle on the panel's edge that faces the anchor,
    /// its tip at the anchor's centre line, filled like the panel and
    /// stroked like its border on the two sides that show.
    private func appendArrow(on edge: Edge, of panel: Rect, toward target: Rect, context: DrawContext, into list: inout DisplayList) {
        let half = Self.arrowWidth / 2
        let height = Self.arrowHeight
        // Kept off the panel's rounded corners.
        let corner = PopoverPanel.cornerRadius + half

        /// `value` within `low...high`, or the middle when the panel is too
        /// small for the range to exist.
        func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
            low <= high ? min(max(value, low), high) : (low + high) / 2
        }

        let tip: Point
        let baseA: Point
        let baseB: Point
        switch edge {
        case .top:
            let x = clamp(target.midX, panel.minX + corner, panel.maxX - corner)
            tip = Point(x: x, y: panel.maxY + height)
            baseA = Point(x: x - half, y: panel.maxY)
            baseB = Point(x: x + half, y: panel.maxY)
        case .bottom:
            let x = clamp(target.midX, panel.minX + corner, panel.maxX - corner)
            tip = Point(x: x, y: panel.minY - height)
            baseA = Point(x: x - half, y: panel.minY)
            baseB = Point(x: x + half, y: panel.minY)
        case .trailing:
            let y = clamp(target.midY, panel.minY + corner, panel.maxY - corner)
            tip = Point(x: panel.minX - height, y: y)
            baseA = Point(x: panel.minX, y: y - half)
            baseB = Point(x: panel.minX, y: y + half)
        case .leading:
            let y = clamp(target.midY, panel.minY + corner, panel.maxY - corner)
            tip = Point(x: panel.maxX + height, y: y)
            baseA = Point(x: panel.maxX, y: y - half)
            baseB = Point(x: panel.maxX, y: y + half)
        }

        // The fill's base sits a point inside the panel, over the border
        // there, so the arrow and the panel read as one shape.
        let inward: Point
        switch edge {
        case .top:      inward = Point(x: 0, y: -1)
        case .bottom:   inward = Point(x: 0, y: 1)
        case .trailing: inward = Point(x: 1, y: 0)
        case .leading:  inward = Point(x: -1, y: 0)
        }
        let bounds = Rect(
            x: min(tip.x, baseA.x, baseB.x), y: min(tip.y, baseA.y, baseB.y),
            width: abs(max(tip.x, baseA.x, baseB.x) - min(tip.x, baseA.x, baseB.x)),
            height: abs(max(tip.y, baseA.y, baseB.y) - min(tip.y, baseA.y, baseB.y))
        )
        list.append(.shape(ShapeDraw(
            path: Path {
                $0.move(to: Point(x: baseA.x + inward.x, y: baseA.y + inward.y))
                $0.addLine(to: tip)
                $0.addLine(to: Point(x: baseB.x + inward.x, y: baseB.y + inward.y))
                $0.closeSubpath()
            },
            bounds: bounds,
            fill: .color(context.resolve(Color.secondaryBackground)),
            transform: context.transform,
            clip: context.clip,
            clipCornerRadius: context.clipCornerRadius
        )))
        list.append(.shape(ShapeDraw(
            path: Path {
                $0.move(to: baseA)
                $0.addLine(to: tip)
                $0.addLine(to: baseB)
            },
            bounds: bounds,
            stroke: .color(context.resolve(Color.separator)),
            strokeStyle: StrokeStyle(lineWidth: 1, lineJoin: .round),
            transform: context.transform,
            clip: context.clip,
            clipCornerRadius: context.clipCornerRadius
        )))
    }
}
