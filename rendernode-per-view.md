# RenderNode per view — the one-canvas model is wrong

## What the code does today (2026-09-20)

Every ordinary view (`Text`, `VStack`, shapes, images, …) draws into **one**
`NucleantRenderNode` — the window-filling ThorVG canvas made in
`HostingWindow.attachCanvas` (`App/HostingWindow.swift`). The whole tree is
placed into a `DisplayList`, `ThorDisplayRenderer` rebuilds the ThorVG scene
from it, and that single canvas is rasterized again whenever anything in the
tree changes.

The only views with their own node are `Shader` / `VertexShader` (one slot
each, `ShaderSlotRegistry`) and the hidden layer canvas behind a
`.shader(_:)` effect.

## Why that is a misunderstanding of the engine

`NucleantRenderNode` / the Vulkan engine's slot list exists so that *each
piece of UI owns its own node*: its own image, rasterized only when *it*
changes, composited into its rect. That is how the rest of Nucleant uses
render nodes. NucleantSwiftUI collapsed everything into one canvas, so:

- any state change anywhere ⇒ the full window canvas is re-rasterized
  (`canvas.draw()` + `sync()` over the entire scene);
- this is why the TouchBayUI demo sat at ~90% CPU while anything was
  changing — every knob tick repainted the whole window;
- the engine's per-node machinery — VkImage per slot, post-shader chain,
  `replace(id:)` in place, scissor, z-order — has gone unused from this lib
  because there was never more than one canvas node to hang it on.

## What it should be

- A view (or subtree) gets its own `NucleantRenderNode`, with a
  `compositeRect` = its placed frame, and re-rasterizes only when its own
  content changes. Unchanged siblings keep presenting their last image.
- The view layer controls **when a fresh node is created vs. the existing
  one is updated in place** — an explicit, visible decision (a modifier /
  view-level API), not something hidden in the renderer. Starting over with
  a new node must be a choice the view code can make; resize / identity
  change / source change are the obvious triggers, but the hook has to be
  there for the author to call.
- Node identity comes from `ViewID` — that is what it was built for: the
  `@View` macro stamps every view with its call site so the view can refer
  back to the render node it already owns, across rebuilds. Today `ViewID`
  stops one layer short: it only keys `ViewNode` reuse
  (`ViewNode.swift`, `ViewIdentity`) and `@State` storage
  (`DynamicProperty.swift`, `StateKey`); it never reaches a
  `NucleantRenderNode`. Even the shader slots key by structural
  `context.path`, not `ViewID`.

## Granularity — decided direction

Not a node for each and every view. The split falls out of what already
exists:

- **`BuiltinView`** (`Core/View.swift`: `Text`, the shapes, `Image`,
  `Color`, `Divider`, `Spacer`, `HStack`/`VStack`/`ZStack`, `ScrollView`,
  `ForEach`, `Group`, `TupleView`, `AnyView`, the `_ModifierView` /
  `_ShapeView` wrappers…) = **draw instructions for the current ThorVG
  canvas**. These are `body: Never` leaves/containers with a `makeNode`;
  they keep doing exactly what they do now, just into whichever node's
  canvas they are inside.
- **A user `View`** (one with a `body`, stamped by `@View` with a `ViewID`)
  = **its own `RenderNode`**. Its `body` is rendered into that node's
  canvas; the node re-rasterizes only when that view's state changes, and
  `ViewID` is how it finds its existing node across rebuilds.

`BuiltinView` is almost all `body: Never` already, so "builtin ⇒ canvas
instruction, body ⇒ render node" fits as a new case rather than a
reclassification. `Shader` / `VertexShader` are the exception among
builtins — they already own a node each — and stay as they are.

## Not yet decided

- Whether a user `View` can opt *out* of its own node (a tiny wrapper view
  inside a hot list may not want an image of its own), and if so how.
- What crosses node boundaries: clipping (`ScrollView`, `.clipped()`),
  opacity groups, blend modes — today ThorVG's scene handles these; with
  per-view nodes the compositor's `compositeScissor` has to.
- Text/vector sharpness under composite: the node's image is 1:1 with its
  frame (the shader slots already pin `pixelOrigin` to whole pixels).

## Constraints

- Additive. Nothing on the app run path (`HostingWindow`, `PlatformWindow`,
  `AppRuntime`, `NucleantApp`) is restructured to get there — see the
  standing rule. A per-view node path sits beside the canvas path and is
  switched to per view.
- No implementation until the granularity and the "new node vs. update"
  API are agreed.

## Composition inside a `View` — which element gets what (2026-09-21)

```swift
ZStack {
    Color.red                 // instruction into the current View's RenderNode
        .shader(ColorBend())  // post-processes a *region* of that node's VkImage
    SomeShader()              // new RenderNode by default: it draws on top of the Thor context
    Text("…")                 // has to be a new node here, because it sits above the shader
        .shader(SomeShader)   // uses that node's own post-process on its VkImage
}
```

The `View` struct the `ZStack` lives in is rendered to one VkImage by
joining all of its children's VkImages / surfaces, in order:

- `Color.red` is just added to the root node's instruction list. Once
  rasterized, that part does not re-render when `SomeShader` changes — only
  the current VkImage + the shader's result + the text's result get
  re-composed.
- `SomeShader` is its own node, so the parent only has to add its VkImage
  as the next thing to draw.
- `Text` has to be its own node (it is above the shader's image), and
  `.shader` on it is then cheap: it is the node's post-process.

### `.shader` means different things depending on what it is applied to

```swift
VStack {
    Color.red  .shader(ColorBend())   // OverlayShaderNode
    Color.green.shader(ColorBend())   // OverlayShaderNode — same parent node
    Color.blue .shader(ColorBend())   // OverlayShaderNode — same parent node
}
    .shader(Wave())                   // the RenderNode's own postProcess
```

- On an element that is an *instruction* into the parent's canvas ⇒
  **`OverlayShaderNode`** (new, in NucleantVulkan): takes the parent's
  VkImage and post-processes a region of it. No new image.
- On a whole node ⇒ that node's own post-process chain.
- A layout whose subviews do not overlap (`VStack`, `HStack`, …) has no
  reason of its own to create a RenderNode.

## `HostingWindow` is not a RenderNode

That is where it first went wrong: one giant primary VkImage for the
window. There is no reason to believe one giant surface takes less memory
than 4–5 smaller RenderNodes with their own VkImages — and it costs every
change the whole surface.

## Resize ⇒ new VkImage for that node, and that is fine

Reallocating a VkImage on a size change can never be as expensive as what
happened in NucleantTouchBayUI: a single change ⇒ every ThorVG instruction
regenerated ⇒ 80–100% CPU when changes happened all over the place.

The NucleantUI concept: pay extra VRAM, and per frame only *dirty*
RenderNodes redraw; the rest just sample their already-rendered VkImages.

- Allocate VkImages rounded up to the nearest 8 / 16 / 32 px. A 128×128
  node that becomes 128×130 goes to 136×136 rather than reallocating at
  the exact size, so small jitters do not reallocate at all.
  `compositeRect` (already on `NucleantRenderNode`) keeps the exact frame.

## Type rules for the rendering layer

- `Any` — not accepted anywhere in rendering. If it is needed, the code is
  not written right.
- `AnyView` — last resort. Even `ForEach` has a type for `Element`; the
  type is masked only when there is no other way.
- `any Protocol` — last resort, only when multi-type conformance is too
  complicated to solve with generics.

TouchBayUI had no trouble with a generic class type inited by the root
view that defines the generic types down the node tree.

## Keeping nodes alive across momentary `View` structs

View structs are momentary and cannot hold a RenderNode. The window keeps
a dictionary instead — the view controls which node type its key
represents, so the cast is the view's responsibility; the node is removed
and freed on the view's final `.onDisappear`:

```swift
public final class RenderNodeManager: @unchecked Sendable {

    public static let shared: RenderNodeManager = .init()

    var nodes: [Int: UnsafeMutableRawPointer] = [:]

    public func getNode<T: NucleantRenderNode>(key: Int) -> T {
        // Views control what type the RenderNode is, so the cast from raw
        // to the requested type is "safe" enough. When a View fires its
        // final .onDisappear the node is removed and deallocated.
        if let raw = nodes[key] {
            return Unmanaged<T>.fromOpaque(raw).takeUnretainedValue()
        }
        fatalError("setup new rendernode")
    }

    public func deleteNode(key: Int) {
        if let node = nodes.removeValue(forKey: key) {
            node.deallocate() // or whatever cleanup is required
        }
    }
}
```

## `@View` and closures

```swift
@View @MainActor
public struct ThorCanvas {
    @State var canvas: ThorContext
    @State var onInit: (borrowing ThorContext, SIMD2<Float>) -> Void
    @State var renderer: (borrowing ThorContext, SIMD2<Float>) -> Void
    public var body: Never { bodyUnavailable() }
}
```

The macro today warns: *"'onInit' is a closure, so no two 'ThorCanvas'
values are ever equivalent and this view is rebuilt whenever its parent
is"*. Wrong direction for a canvas view: closures are simply not
comparable, and if there is nothing comparable then nothing about the view
is changing — its shader updates in its own pipeline, its size in another
— so `_isEquivalent(to:)` should say *unchanged* (skip the rebuild), not
"never equivalent". (The sketch writes `return false`; the intent is
"treat as equivalent / do not rebuild" — sort out the sign when wiring
it.)

## The views that surfaced this

Being prepared when the one-node problem was spotted — views that draw
straight into a canvas and obviously want their own RenderNode:

```swift
@View @MainActor
public struct ThorCanvas {
    @State var canvas: ThorContext
    @State var onInit: (borrowing ThorContext, SIMD2<Float>) -> Void
    @State var renderer: (borrowing ThorContext, SIMD2<Float>) -> Void
    public var body: Never { bodyUnavailable() }
}

@View @MainActor
public struct ThorCanvasRender<Context: ThorRenderContext> {
    @State var context: Context
    public init(context: Context) { self.context = context }
}

// later
@View @MainActor
public struct SkiaCanvasRender<Context: ThorRenderContext> {
    @State var context: Context
    public init(context: Context) { self.context = context }
}
```

More of these will come.
