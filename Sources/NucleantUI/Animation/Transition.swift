//
//  Transition.swift
//  NucleantUI
//
//  How a view enters and leaves: the effect it has while "active" — fully
//  faded, fully slid off — which an insertion animates away from and a
//  removal animates towards. Every built-in transition reduces to the same
//  four placement effects (opacity, offset, scale about an anchor, and
//  their combinations), applied by the node as it is placed, so nothing
//  the view builds changes while it transitions.
//

/// A view's entrance and exit — SwiftUI's `AnyTransition`.
///
/// ```swift
/// if isShowing {
///     Banner()
///         .transition(.move(edge: .top).combined(with: .opacity))
/// }
/// ```
///
/// The transition runs when the view is inserted into or removed from an
/// `if`, a `switch` or a `ForEach` by a change that animates — inside
/// `withAnimation`, or under an `.animation(_:value:)` watching that
/// change. Without a `.transition` a view fades (`.opacity`).
public struct AnyTransition: Hashable, Sendable {

    indirect enum Effect: Hashable, Sendable {
        case identity
        case opacity
        case scale(Double, anchor: UnitPoint)
        case offset(x: Double, y: Double)
        case move(Edge)
        case combined(Effect, Effect)
        case asymmetric(insertion: Effect, removal: Effect)
    }

    let effect: Effect
    /// The animation this transition runs with, whatever the change's own.
    let animation: Animation?

    init(_ effect: Effect, animation: Animation? = nil) {
        self.effect = effect
        self.animation = animation
    }

    /// No effect: the view is simply there, or simply gone.
    public static let identity = AnyTransition(.identity)

    /// Fades in and out.
    public static let opacity = AnyTransition(.opacity)

    /// Grows from, and shrinks to, nothing.
    public static var scale: AnyTransition { scale(scale: 0) }

    /// Grows from, and shrinks to, `scale` about `anchor`.
    public static func scale(scale: Double, anchor: UnitPoint = .center) -> AnyTransition {
        AnyTransition(.scale(scale, anchor: anchor))
    }

    /// Slides in from, and out to, an offset.
    public static func offset(x: Double = 0, y: Double = 0) -> AnyTransition {
        AnyTransition(.offset(x: x, y: y))
    }

    public static func offset(_ offset: Size) -> AnyTransition {
        AnyTransition(.offset(x: offset.width, y: offset.height))
    }

    /// Slides in from, and out towards, `edge` — by the view's own size.
    public static func move(edge: Edge) -> AnyTransition {
        AnyTransition(.move(edge))
    }

    /// In from the leading edge, out to the trailing.
    public static var slide: AnyTransition {
        AnyTransition(.asymmetric(insertion: .move(.leading), removal: .move(.trailing)))
    }

    /// In from `edge` and out the opposite side, fading both ways — a
    /// new screen pushing the old one along.
    public static func push(from edge: Edge) -> AnyTransition {
        AnyTransition(.asymmetric(
            insertion: .combined(.move(edge), .opacity),
            removal: .combined(.move(edge.opposite), .opacity)
        ))
    }

    /// One transition for coming in, another for going out.
    public static func asymmetric(insertion: AnyTransition, removal: AnyTransition) -> AnyTransition {
        AnyTransition(
            .asymmetric(insertion: insertion.effect, removal: removal.effect),
            animation: insertion.animation ?? removal.animation
        )
    }

    /// Both at once.
    public func combined(with other: AnyTransition) -> AnyTransition {
        AnyTransition(.combined(effect, other.effect), animation: animation ?? other.animation)
    }

    /// Runs this transition with `animation`, whatever the change's own.
    public func animation(_ animation: Animation?) -> AnyTransition {
        AnyTransition(effect, animation: animation)
    }

    /// True when the transition does nothing either way — no need to keep
    /// a removed view on screen for it.
    var isIdentity: Bool { effect.isIdentity }
}

extension AnyTransition.Effect {
    var isIdentity: Bool {
        switch self {
        case .identity: return true
        case .combined(let a, let b): return a.isIdentity && b.isIdentity
        case .asymmetric(let insertion, let removal): return insertion.isIdentity && removal.isIdentity
        default: return false
        }
    }
}

extension Edge {
    var opposite: Edge {
        switch self {
        case .top: return .bottom
        case .bottom: return .top
        case .leading: return .trailing
        case .trailing: return .leading
        }
    }
}

/// What a transition does to a node at one moment.
struct TransitionEffect {
    var opacity = 1.0
    var offset = Point.zero
    var scaleX = 1.0
    var scaleY = 1.0
    var anchor = UnitPoint.center

    /// `transition` applied `amount` of the way — 0 is the view as it is,
    /// 1 fully active — to a view of `size`, on the way in or out.
    init(_ transition: AnyTransition, isInsertion: Bool, amount: Double, size: Size) {
        apply(transition.effect, isInsertion: isInsertion, amount: amount, size: size)
    }

    private mutating func apply(_ effect: AnyTransition.Effect, isInsertion: Bool, amount: Double, size: Size) {
        switch effect {
        case .identity:
            break
        case .opacity:
            opacity *= min(max(1 - amount, 0), 1)
        case .scale(let scale, let anchor):
            let factor = 1 + (scale - 1) * amount
            scaleX *= factor
            scaleY *= factor
            self.anchor = anchor
        case .offset(let x, let y):
            offset.x += x * amount
            offset.y += y * amount
        case .move(let edge):
            switch edge {
            case .leading: offset.x -= size.width * amount
            case .trailing: offset.x += size.width * amount
            case .top: offset.y -= size.height * amount
            case .bottom: offset.y += size.height * amount
            }
        case .combined(let a, let b):
            apply(a, isInsertion: isInsertion, amount: amount, size: size)
            apply(b, isInsertion: isInsertion, amount: amount, size: size)
        case .asymmetric(let insertion, let removal):
            apply(isInsertion ? insertion : removal, isInsertion: isInsertion, amount: amount, size: size)
        }
    }

    /// Apply to a node about to be placed in `rect` under `context`.
    func apply(to rect: inout Rect, context: inout DrawContext) {
        rect = rect.offsetBy(dx: offset.x, dy: offset.y)
        context.opacity *= opacity
        if scaleX != 1 || scaleY != 1 {
            context.transform = context.transform
                .concatenating(.around(anchor.resolved(in: rect), .scale(x: scaleX, y: scaleY)))
        }
    }
}

// MARK: - The modifier

extension View {
    /// How this view enters and leaves when an animated change inserts or
    /// removes it.
    public func transition(_ transition: AnyTransition) -> some View {
        _ModifierView(content: self, key: ["transition", transition] as [AnyHashable]) { _ in
            TransitionTraitContent(transition: transition)
        }
    }
}

/// Carries the transition up to the container that inserts or removes the
/// view; lays out and draws exactly as what it wraps.
struct TransitionTraitContent: NodeContent {
    let transition: AnyTransition

    var transitionTrait: AnyTransition? { transition }
}
