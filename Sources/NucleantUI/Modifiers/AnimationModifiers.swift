//
//  AnimationModifiers.swift
//  NucleantUI
//
//  `.animation` and `.transaction`: changing, for one subtree, how the
//  change being built animates. Each acts twice — on the transaction the
//  subtree is *built* under (which starts value animations and
//  transitions), and on the animation it is *placed* under in the same
//  frame (which starts geometry animations).
//

extension View {

    /// Animates this view with `animation` whenever `value` changes —
    /// whatever changed it, `withAnimation` or not. `nil` makes such a
    /// change happen at once.
    ///
    /// ```swift
    /// Circle()
    ///     .scaleEffect(isOn ? 1.5 : 1)
    ///     .animation(.bouncy, value: isOn)
    /// ```
    public func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        _ModifierView(content: self) { context in
            let changed = context.animations.valueChanged(value, at: context.path)
            // `disablesAnimations` is the change asking to be animated only
            // by its own transaction.
            let overrides = changed && !context.transaction.disablesAnimations
            if overrides {
                context.transaction.animation = animation
            }
            return AnimationScopeContent(
                frame: context.animations.frame,
                adjust: overrides ? { $0 = animation } : nil
            )
        }
    }

    /// Animates every change to this view with `animation`.
    @available(*, deprecated, message: "Use withAnimation or animation(_:value:) instead.")
    public func animation(_ animation: Animation?) -> some View {
        _ModifierView(content: self) { context in
            let overrides = !context.transaction.disablesAnimations
            if overrides {
                context.transaction.animation = animation
            }
            return AnimationScopeContent(
                frame: context.animations.frame,
                adjust: overrides ? { $0 = animation } : nil,
                appliesToEveryBuild: true
            )
        }
    }

    /// Adjusts the transaction of any change that reaches this view —
    /// `$0.animation = nil` to have this view jump while the rest animates.
    public func transaction(_ transform: @escaping (inout Transaction) -> Void) -> some View {
        _ModifierView(content: self) { context in
            transform(&context.transaction)
            return AnimationScopeContent(
                frame: context.animations.frame,
                adjust: { animation in
                    var transaction = Transaction(animation: animation)
                    transform(&transaction)
                    animation = transaction.animation
                },
                appliesToEveryBuild: true
            )
        }
    }
}

/// Places its child under an adjusted animation in the frame the change
/// was built in. Lays out as its child does.
struct AnimationScopeContent: NodeContent {
    /// The frame this node was built in.
    let frame: Int
    /// What happens to the animation the subtree is placed under.
    let adjust: ((inout Animation?) -> Void)?
    /// Whether the adjustment holds for any frame that builds something,
    /// not only the one that built this node — the value-free `.animation`
    /// and `.transaction`, which apply to every change.
    var appliesToEveryBuild = false

    func place(node: ViewNode, in rect: Rect, proposal: ProposedSize, context: DrawContext, into list: inout DisplayList) {
        var inner = context
        if let adjust, let store = AnimationStore.current, store.isCommitPass,
           appliesToEveryBuild || store.frame == frame {
            adjust(&inner.animation)
        }
        node.singleChild?.place(in: rect, proposal: proposal, context: inner, into: &list)
    }
}
