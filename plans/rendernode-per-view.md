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

## Implementation — 2026-09-21

Built additively, beside the window canvas. Nothing in `HostingWindow` /
`PlatformWindow` / `AppRuntime` / `NucleantApp` changes; the window canvas
stays the root node and the fallback for every view that has not been
switched. A view is switched to its own node **per view**:

```swift
TrackList()          // a subtree rasterized into its own image
    .drawingGroup()  // SwiftUI's name for exactly this: an offscreen image,
                     // composited into the view's frame

ThorCanvas(          // a node the author draws into directly, ThorVG paints
    onInit: { context, size in … },     // once per node — the canvas is fresh
    renderer: { context, size in … }    // again whenever what it read changed,
)                                       // or the size did

ThorCanvasRender(context: instructions)  // the same, with the paints and the
                                         // two callbacks on an object
```

### Nodes and keys

- `RenderNodeManager` (`App/RenderNodeManager.swift`) keeps every per-view
  canvas node alive across the momentary view structs, keyed by
  `RenderNodeKey` = structural path + `ViewIdentity` (type + stamped
  `ViewID`) + an optional author-chosen `id`. The path is what tells the
  third row of a `ForEach` from the fourth; the `ViewID` is what tells two
  call sites apart at the same position — the same identity the builder
  and `@State` use. Typed storage (`[RenderNodeKey: CanvasNode]`), not the
  raw-pointer sketch: the node kind is fixed by the modifier / view that
  asked for it, so there is nothing to cast.
- Lifetime is per layout pass, as for shader slots: a node not placed this
  pass is retired at `endPass` (detached from the engine now, GPU objects
  freed at the top of the next frame). Its ThorVG canvas goes to a pool
  shared with `.shader` layers — a fresh wg canvas costs ~60ms (pipeline
  compile), a retargeted one <1ms, so a canvas is never thrown away while
  a spare might be wanted. This is also why every `@View` does *not* get a
  node automatically yet: a screen of thirty user views would pay 2s on
  first show. Flipping that on later is one line in `buildNode`; the
  opt-out question above then becomes real.
- **Update in place vs. new node.** Same key ⇒ the existing node is updated
  in place: its canvas is repainted and re-rasterized, and only when what
  the view draws actually changed (the display list is compared in
  node-local coordinates, so *moving* a node — scrolling — re-rasterizes
  nothing). A different key ⇒ a new node; the old one retires. The author
  gets that hook as `ThorCanvas(id:…)` / `ThorCanvasRender(id:…)`: a new
  `id` starts over — fresh canvas, `onInit` again. For `.drawingGroup()`
  starting over has no visible meaning (the list is the whole content), so
  it has no `id`.
- **Resize** keeps the node and retargets its canvas at a new image
  (`resizeThorNode`), as the window's own path does. Images are allocated
  rounded up to a multiple of 16px; `compositeRect` keeps the exact
  (pixel-snapped) frame at the image's own size so texels map 1:1, and
  `compositeScissor` = frame ∩ container clip cuts the slack and whatever a
  `ScrollView` above clips. Content inside the node is drawn unclipped by
  outside containers (the scissor does that), with inherited opacity and
  transform baked in — so as with `.shader`, clip *inside* the group, and
  a rotation outside it is cut at the image edge.
- **Z-order.** `engine.nodes` is composited in array order, so at `endPass`
  the manager reorders it to this pass's paint order: the window canvas
  first, then every per-view node and shader slot in the order they were
  placed (a `.shader` layer canvas just before the compute node that
  samples it). Shader slots used to composite in *creation* order; tree
  order is what was always meant.
- **What still paints into the window canvas is under every node** — the
  plan's model: whatever sits *above* a node in a `ZStack` has to be a node
  itself. Two things the framework draws last are therefore nodes of their
  own: the host's overlay slot (popovers, context menus) and the drag
  preview, in one topmost node that exists only while there is something
  to show. Inside a `.shader` layer, a `.hidden()` view or a drag snapshot,
  a drawing group flattens into the enclosing capture — the capture wants
  the pixels, and a separate node would composite over it.
- The window canvas is redrawn only when its own list changed:
  `ViewHost.update()` now returns exactly that, so a change inside a node
  leaves the window's ThorVG scene and rasterization alone. (`markNeedsRedraw`
  in `HostingWindow` is unchanged; it just gets told the truth.)

### `ThorCanvas` / `ThorCanvasRender`

- `ThorContext` wraps the node's `Tvg_Canvas` (`ThorGPUCanvas`, so `add` /
  `remove` / `insert` are there) and carries `scale`; sizes are in canvas
  pixels. `TCShape` / `TCScene` own their paint (`tvg_paint_ref` on init,
  `unref(free:)` on deinit), so an author's shapes survive the canvas
  dropping them and can be added to a fresh canvas after `onInit` runs
  again.
- `renderer` / `update` run with dependency tracking attributed to the
  view's path: a `@State` read through a captured binding, or an
  `@Observable` property read, dirties the canvas view alone — the next
  frame rebuilds just it and runs the closure again, then the node
  rasterizes. Nothing read ⇒ nothing re-run ⇒ the node keeps its image.
  SwiftUI's `Canvas` contract, on ThorVG paints that persist.

### `@View` and closures — done as decided above

A stored closure no longer takes part in `_isEquivalent(to:)`: it is
skipped, so a view differing only in a closure is equivalent and is reused.
The warning is gone. The consequence to design around: a closure a `@View`
stores is the one from the build that created the view — capture a
`Binding`, a `@State` holder or a model object, never a plain value the
parent may change. (`Button`, `ForEach`, `NavigationLink`, `AnyView` and
`_ModifierView` without a key still say "never equivalent" by hand — they
are the framework's, not `@View`'s.) The generated init now marks a
wrapped closure (`@State var onInit: () -> Void`) `@escaping`, which is
what stopped the sketch above from compiling.

### Found while running it

- `tvg_canvas_draw` does not repaint a paint changed in place; the
  `ThorCanvas` path calls `tvg_canvas_update` after the closures.
- The composite drops a viewport whose *dimensions* exceed the swapchain's
  (a smaller one hanging past an edge is fine). Images are therefore capped
  at the window size — the manager gets it at `beginPass` — and a view
  larger than the window composites through an image of its visible part
  (frame ∩ clip ∩ window), which repaints on scroll. A `ThorCanvas` larger
  than the window is not shown.
- A fresh canvas: ~70ms each on this machine; a pooled one ~1–2ms. First
  show of the test scene with four nodes and two shader slots: ~400ms.

### Not in this step

- `OverlayShaderNode` (post-processing a region of the parent's image) is
  engine work in NucleantVulkan. Until it exists, `.shader` on an
  instruction keeps making its own layer + compute node.
- `Shader` / `VertexShader` slots keep their own registry; they are nodes
  already. They now composite in tree order rather than creation order.

## Automatic nodes — 2026-09-21, later the same day

The opt-in step above did not deliver what this document asks for, and
TouchBayUI was the proof: an app that never writes `.drawingGroup()` (none
do) turned one knob and paid for the whole window — 58% CPU in release for
a 60Hz value change, every one of them a full ThorVG pass over every panel,
knob, slider and image strip on screen. The plan says a user view is its
own node; nothing in the framework made that true on its own. Now it is,
without the app doing anything, and the same drives cost 21–28%.

### Why not a canvas per view

A fresh ThorVG wg canvas costs ~72ms *whatever its size* (a 64×96 one
measured the same as the window): `WgRenderer::target` initialises the
context, compiles its pipelines and allocates its target pool per canvas.
Twenty-eight nodes was a 2s first frame; a screen of user views would be
many seconds. And a composited node costs ~0.036% CPU per frame idle (the
engine presents every tick), so the count has to stay in the tens, not the
hundreds a "node per `@View`" taken literally would make. Two decisions
follow.

### One painter, an image per node

Automatic nodes own no canvas. The engine's `ImageNode`
(NucleantVulkan, `Nodes/ImageNode.swift`, branch `render_updates`) is a
plain `VkImage` — `TRANSFER_DST | SAMPLED`, device-local, the painter's
byte layout viewed as BGRA like every imported canvas image,
`engine.makeImageNode(width:height:)` — behind a fourth
`NucleantRenderNode.Context` case, `.image`. It is filled by copying a
region out of another node's image: the host sets `pendingCopy` (an
`ImageCopy`: source image, source rect, destination), and the node's own
`update` records the barriers and the `vkCmdCopyImage` into the frame's
command buffer, then publishes itself (`readable`). The source is one
shared, window-sized ThorVG canvas node, the *painter* (`NodePainter`),
listed in the engine at order −1 with `compositesToWindow = false` — the
`.shader` layer precedent: a canvas the engine draws but never
composites, consumed by the nodes listed after it. At `endPass`, every
image whose content changed this pass is packed into the painter side by
side (tallest first on shelves, a granule of gutter between them,
`ThorDisplayRenderer.render(packed:)` — each list under a root scene
translated to its slot), the painter is marked dirty, and each image gets
its `pendingCopy`. The frame then does the rest in list order: the
painter's `ThorShaderNode.update` draws, syncs and *waits for wgpu*
(`waitForExternalCompletion`), and the copies follow it in the same
command buffer, the composite that samples them after that — no separate
submit, no queue wait. A pass that paints the painter again while the
last frame's copies may still be reading it waits for that frame first
(`engine.waitForPreviousFrame()`, the fence the engine already keeps per
frame in flight). Creating a `VkImage` is microseconds; freed images are
pooled by size (32). The painter grows (to 8192 rows) when a pass needs
more than the window, and what still does not fit is painted at the
next frame (`frameWillDraw`).

Nothing of this is Vulkan or wgpu code in NucleantSwiftUI: `NodePainter`
packs and schedules, `RenderNodeManager` keeps the nodes, and the engine
copies. Three things the engine lacked for it, all on `render_updates`:
a sampled image node filled by copy (`ImageNode`, `ImageCopy`,
`makeImageNode`); `WgpuContext.waitForGPUCompletion()`, which on Apple
waited for nothing — this wgpu-native returns no native Metal queue, and
the guard returned early — and now falls back to the blocking
`wgpuDevicePoll`, as off Apple; and `waitForPreviousFrame()`, a wait on
the last frame's fence short of `vkDeviceWaitIdle`.

### Which views are nodes

A user view becomes a node boundary once **a change can originate at it**:
it read `@State` while its body ran (`Entry.reads`, known at build time),
or a rebuild started at its path — which is how an `@Observable` reader
announces itself, since observation only registers a change handler that
dirties the view's own path. The flag is sticky (`Entry.isBoundary`,
carried across every rebuild of the same view at that position) and goes
with the view. Views that only pass values down never become nodes; their
drawing lands in the nearest node above, or the window canvas. So a screen
has as many nodes as it has things that change — TouchBayUI's turning knob
is two: the knob's `BaseView` and the `KnobCell` label reading the same
value. The first change to a view still repaints the window once (it was
drawn there); every change after that repaints the node alone.

Two exclusions: a view whose body dissolves into the parent's layout (a
`Group`, a `ForEach` — a transparent node) cannot be one laid-out box, and
a view covering the whole window *is* the window canvas and draws through.
`buildNode` wraps a boundary's node in `RenderBoundaryContent`
(`Layout/RenderBoundary.swift`), a pass-through for size, flexibility and
hit testing whose `place` gives the body a list of its own.

### What a node holds, and runs

A node's image is the **paint bounds** of what its view drew — every
command says conservatively where its pixels can land (`Render/
PaintBounds.swift`: path box ∪ shape rect, stroke reach with the miter
limit, glyph overshoot, transform, clip; `Color.clear` paints nothing) —
not the view's frame, so a glow that reaches past the frame is not cut and
a wide frame with a small drawing does not cost a wide image. Bounds ∩
window, rounded to the 16px granule, kept up to two granules of shrink;
content is compared in the image's own coordinates, so a view that moved
by whole pixels is not painted again (TouchBayUI's knob turn: `nodes=2`,
no `window`; the test scene's moved glow: nothing painted at all). The
container's rectangular clip becomes the composite scissor rather than
staying in the commands, so a row scrolling under a `ScrollView` compares
equal too — and travels on as `DrawContext.nodeClip`, so a node or shader
slot *inside* that row is still cut to the viewport (`compositeClip`); a
rounded clip has no scissor and stays in the commands. A node scrolled
entirely out of its clip paints nothing and holds no image.

A node whose list changed in a few commands only — TouchBayUI's
`GalleryView` reads the XY pad's values in its own body, for a label, so
the *gallery* is the node that changes — repaints the part those commands
touch, not the image: the old and new lists share a prefix and a suffix,
the commands between them bound the damage (`damage(from:to:in:)`), and
the painter draws only the commands reaching into that rect, cut to it
(`DrawCommand.clipped(to:)`), copying just that region into the image.
Whole pixels, so the cut has no partial coverage; not when a rounded clip
runs through the damage (a rect clip could not reproduce it), nor when
the damage is most of the image. The XY drive with the gallery as a node:
60% whole, 27% partial — "2 images (1 partial) in 0.9ms".

Nested nodes cut the enclosing view's drawing into **runs**. The window
canvas is the outermost frame (`RenderNodeManager.Frame`); every node
kind — automatic, `.drawingGroup()`, `ThorCanvas`, shader slot — reports
where in the enclosing list it was placed and what it covers
(`noteNested`). Run 0 and everything that lands over no node placed before
it merge into the primary image, which took its paint position before
anything inside it; a command that lands over an earlier nested node, and
then any command over one of those (it was drawn after it), goes into an
image of its own, ordered after that node (`splitRuns`, per command with
the moved set transitive across runs). That is what makes a `ZStack`'s
stroke and label drawn after two hot meters sit *over* them, and it
retires the old rule that a later sibling had to be a group too — for
drawing groups as well. `ViewHost.endRootFrame` does the same for the
window's own list. The host's overlay slot (popovers, menus, drag preview)
is a frame of its own and an image node now, not a canvas: a popover
costs no 70ms canvas on first open.

### Measured (release, TouchBayUI's gallery, one control driven at 60Hz)

| | window canvas | automatic nodes |
|---|---|---|
| idle | 4.4% | 4.5–5.2% |
| canvas knob | 58.2% | 20.7–24.2% |
| canvas slider | 57.9% | 22.3–22.9% |
| ADSR | 56.4% | 21.1–21.2% |
| XY pad | 63.9% | 27.1–27.2% |

(Ranges over runs an hour apart; the idle end of the range has ~15 image
nodes standing — every `Button`, the popup slider — at ~0.036% each, the
composite pass the engine runs every tick whether or not anything moved.
Skipping the present when nothing changed is `HostingWindow` / engine
ground.)

Per pass now (profile): the user's views' scoped rebuild ~0.6ms (22 nodes
built — plain structs with closures rebuild every time), the place pass
over the whole tree ~0.7ms, painter ~1ms. What is left is the view layer,
not rasterization.

After the move into the engine (2026-09-22, same method, same machine):
knob 22.5–22.8%, slider 21.6%, idle 5.1% — against 25.0 / 23.4 / 5.7
straight after the move, and 21.8 / 22.4 / 5.5 before it. The pass is
cheaper than before (painter 0.1ms; the draw and the wait moved into the
frame, where they were anyway) and neither wait costs CPU (A/B skipping
each: same numbers). The three points were found with `sample` and were
all bookkeeping: an `@Observable` tracked property on a *generic* class
(`ImageNode<ContainerNode>.width/height`) instantiates its key path —
demangling and all — on every access, and the manager read them on every
lookup (`@ObservationIgnored` on everything the container does not
observe; the engine's `ThorShaderNode.image` getter costs the same, so
it is read once per paint); a closure passed to `contains(where:)` or
`sort` from a `@MainActor` type pays `swift_task_isCurrentExecutor` per
call, per command and rect in `splitRuns` (plain loops now); the engine
list sort looked its orders up per comparison (ranked once). Left as is,
older than this work and visible in the same profile:
`ViewNode.layoutChildren` (~1% of the main thread, a closure and a
`flatMap` per stack layout) and the observation registrar's per-access
cost on every tracked property. Screenshots of the gallery are identical to the window
path except 1px anti-aliased edges of rounded rects in nodes (601 pixels,
all under 96/255), which is the engine-side blend: ThorVG's wg backend
blends `One / OneMinusSrcAlpha` and blits premultiplied pixels into its
target, and `CompositePipeline` samples them with `SRC_ALPHA /
ONE_MINUS_SRC_ALPHA` — a double alpha on every non-opaque node, drawing
groups and `.shader` layers included, invisible on the opaque window
canvas. `srcColorBlendFactor = VK_BLEND_FACTOR_ONE` there is the fix;
NucleantVulkan's call.

### Found while running it

- A pass-through wrapper (`Optional`, `_ConditionalContent`) records its
  child's `ViewNode` as its own. After a *scoped* rebuild replaced that
  child, the wrapper's record still pointed at the old node, and the next
  reuse of the wrapper grafted the stale subtree back — a meter under an
  `if` showed its first-build value after an unrelated rebuild of the
  parent. Older than this work; `RebuildRecords.replaceNode` now walks the
  ancestors that recorded the replaced node.
- An observation registration outlives its view: a popover's meter, gone
  with the popover, still dirties its old path on the next change, and a
  dirty path with no record is a full rebuild (`fallback`). Pre-existing,
  harmless, and visible in the trace.
- `.shader(backdrop: true)` seeds its layer with what the enclosing list
  painted beneath the view; what nested nodes painted there is no longer
  in that list.
- BabyLights on an iPad (2026-09-22): START and About invisible at launch,
  and after Settings → Back the −/+ buttons stuck to the main screen in
  START's place. The copy out of the painter had run *before* ThorVG's
  draw landed — `tvg_canvas_sync` proves the blit was queued on wgpu's
  queue, the copy is a Vulkan command on the engine's, and the painter
  node's `waitForExternalCompletion` (`WgpuContext.waitForGPUCompletion`)
  fenced wgpu's Metal queue only where the build exposes it: this
  wgpu-native returns no native queue, so on Apple it waited for
  nothing. A canvas node lives with that: the composite samples it again
  next frame. An image is filled once, so a copy that wins the race keeps
  what the painter held before — nothing, or the previous pass's shelves.
  The simulator only ever lost it on the overflow path (a second batch in
  one pass). An engine lack, fixed in the engine: the wait now falls back
  to the blocking `wgpuDevicePoll` (see above). Every Thor canvas node
  gets the real wait with it; costs nothing measurable (A/B with the wait
  skipped: 24.6% vs 24.8% knob).
