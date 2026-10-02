# Option for switching between Skia and current ThorVG as MainRender Node

atm everything but Shaders runs by ThorVG canvas stuff

i would like to try and see how it would now run with skia
but here is the catch

* IT MUST BE SOLVED IN AN GENERIC WAY
* NO ENUM SWITCHING BESIDES WHAT CURRENT ALREADY DOES

---

## Proposal (2026-10-02) — for review, nothing implemented yet

### Summary

- The backend is the **node type itself**, as in the original sketch:
  `ThorShaderNode<NucleantRenderNode>` or `SkiaShaderNode<NucleantRenderNode>`.
  - An app names it with `associatedtype PrimaryNode: PrimaryRenderNode`,
    which defaults to the Thor node. An app that says nothing runs exactly
    as it does today.
- Everything specific to a backend is a requirement of `PrimaryRenderNode`,
  with default implementations where one makes sense.
- **`NucleantRenderNode` stays non-generic.** Its existing `switch context`
  gets one more case, `.skia(SkiaShaderNode<NucleantRenderNode>)`, beside
  `.thor`. That is the same thing the enum already does for its other node
  kinds, and what PyNucleantUI's container does.
  - The "root trigger both sides have in common" is one requirement:
    `var slotContext: NucleantRenderNode.Context`. Thor returns
    `.thor(self)`, Skia returns `.skia(self)`.
  - Nothing above the container ever switches on the backend.
- `DisplayList` is already the seam between layout and drawing. Everything
  above it stays the same. What changes is who makes the canvas nodes, who
  draws a list into them, and who measures text.

### What is tied to ThorVG today

`ThorDisplayRenderer.swift`'s header says a Skia backend "would mean a
sibling of this file and nothing else". That is not true any more. These
files are tied to ThorVG:

| File | What ties it to ThorVG |
|---|---|
| `App/NucleantRenderNode.swift` | `case thor(ThorShaderNode<…>)` is the only 2D case; `resizeToFitWindow` calls `engine.resizeThorNode` |
| `App/HostingWindow.swift` | `thorNode: ThorShaderNode`, `attachCanvas` → `makeThorWidgetNode`, resize → `resizeThorNode`, `ThorDisplayRenderer(canvas:)` |
| `App/RenderNodeManager.swift` | `CanvasNode` holds `ThorShaderNode` + `ThorDisplayRenderer` + `ThorContext`; `acquire` → `makeThorWidgetNode`; `recycle`/`destroy` → `tvg_canvas_remove` / `tvg_canvas_destroy` |
| `Render/NodePainter.swift` | painter is a `CanvasNode`; image nodes copy out of it using the **wgpu** pixel order (`makeImageNode` default format) |
| `App/ShaderSlotRegistry.swift` | the `.shader` layer canvas is a `CanvasNode` drawn with `renderer.render(_:origin:flipHeight:)` |
| `App/ViewHost.swift` | `renderer: ThorDisplayRenderer?` |
| `Render/TextMeasurer.swift` | all layout text metrics come from ThorVG probes (`tvg_text_get_glyph_metrics`); also hosts `ThorEngine` |
| `Graphics/FontRegistry.swift` | resolves a `Font` **and** loads it into ThorVG (`tvg_font_load_from_data`) in one place |
| `App/App.swift` | `ThorEngine.ensureInitialized` at launch |
| `Views/Canvas/ThorVG/*` | `ThorCanvas`, `ThorCanvasRender`, `ThorContext`, `TCShape`, `TCScene` are public API that is ThorVG by design |

`ShaderPipeline`, `VertexShaderPipeline`, `TextureNodeManager` and
`TextureSource` are not tied to ThorVG. Because the container and
`NucleantRenderEngine` stay non-generic, they **don't change at all**, and
`TextureSource` keeps its public API.

### The types

I compiled this shape in a scratch probe (Swift 6, `-swift-version 6`).
Both backends dispatch through the existing switch, and an app that doesn't
name a node gets Thor.

```swift
/// A 2D node a `DisplayList` can be drawn into, usable as the app's primary node.
/// The constraint pins the container, so a conformance is
/// `ThorShaderNode<NucleantRenderNode>` / `SkiaShaderNode<NucleantRenderNode>`.
@MainActor
public protocol PrimaryRenderNode: VulkanRenderNode where ContainerNode == NucleantRenderNode {
    associatedtype Renderer: DisplayListRenderer
    associatedtype Text: TextBackend
    /// Per-engine state the backend shares between its nodes.
    /// Thor: nothing (ThorVG + WgpuContext are process-wide). Skia: the
    /// `SkiaVulkanContext` (one GrDirectContext per engine, not per canvas).
    associatedtype Shared = Void

    static func makeShared(engine: NucleantRenderEngine) throws -> Shared
    static func make(engine: NucleantRenderEngine, shared: Shared, width: Int, height: Int) -> Self?
    /// In place: same node, same slot id/z-order, new image.
    func resize(width: Int, height: Int, slotID: Int, engine: NucleantRenderEngine) -> Bool

    /// The root trigger: which case of the existing enum this node goes in.
    var slotContext: NucleantRenderNode.Context { get }

    /// Built once per canvas node and kept with it (as `ThorDisplayRenderer` is now).
    func makeRenderer() -> Renderer
    /// Drop everything drawn, keep the target. This is what a pooled node gets.
    func clear()
    /// The format of `image`. Image nodes copied out of the painter are made
    /// in it, so the copy is bytes with no swizzle. Thor: wgpu target order
    /// (BGRA on Apple). Skia: R8G8B8A8.
    static var copyFormat: VkFormat { get }
}

extension PrimaryRenderNode where Shared == Void {
    public static func makeShared(engine: NucleantRenderEngine) throws {}
}
extension PrimaryRenderNode {
    /// Default fill-in: the engine slot every primary node is wrapped in.
    public func makeSlot() -> NucleantRenderNode {
        let slot = NucleantRenderNode(id: Int.random(in: .min ... .max), context: slotContext)
        slot.observeContext()
        return slot
    }
}

extension ThorShaderNode: PrimaryRenderNode where C == NucleantRenderNode {
    public var slotContext: NucleantRenderNode.Context { .thor(self) }
    // make → engine.makeThorWidgetNode, resize → engine.resizeThorNode,
    // makeRenderer → ThorDisplayRenderer(canvas: canvas.base), clear → tvg_canvas_remove
    public typealias Text = ThorText
}

extension SkiaShaderNode: PrimaryRenderNode where ContainerNode == NucleantRenderNode {
    public var slotContext: NucleantRenderNode.Context { .skia(self) }
    public typealias Shared = SkiaVulkanContext
    // makeShared → engine.makeSkiaContext, make → makeSkiaWidgetNode,
    // resize → resizeSkiaNode, makeRenderer → SkiaDisplayRenderer
    public typealias Text = SkiaText
}

/// Turns a `DisplayList` into one node's draw calls. `ThorDisplayRenderer`
/// already has exactly this surface.
@MainActor
public protocol DisplayListRenderer: AnyObject {
    var scale: Double { get set }
    func render(_ list: DisplayList, origin: Point?, flipHeight: Int)
    func render(packed items: [(list: DisplayList, x: Int, y: Int)])
}
extension DisplayListRenderer {
    public func render(_ list: DisplayList) { render(list, origin: nil, flipHeight: 0) }
}

// MARK: - The app picks one

@MainActor
public protocol NucleantApp {
    /// Defaulted here, so it is optional without any extension trick.
    associatedtype PrimaryNode: PrimaryRenderNode = ThorShaderNode<NucleantRenderNode>
    associatedtype Body: Scene
    init()
    @SceneBuilder var body: Body { get }
}

@main
struct DemoApp: NucleantApp {
    typealias PrimaryNode = SkiaShaderNode<NucleantRenderNode>     // the whole switch
    var body: some Scene { WindowGroup("Demo") { ContentView() } }
}
```

The container is non-generic and keeps its switch, with one case added:

```swift
public final class NucleantRenderNode: RenderContainerNode {
    public enum Context: RenderNodeContext {
        case thor(ThorShaderNode<NucleantRenderNode>)    // as today: Thor primary canvases + ThorCanvas
        case skia(SkiaShaderNode<NucleantRenderNode>)    // new: Skia primary canvases
        case shader(OGLShaderNode<NucleantRenderNode>)
        case vertexShader(VertFragShaderNode<NucleantRenderNode>)
        case image(ImageNode<NucleantRenderNode>)
        case externalTexture(ExternalTextureNode<NucleantRenderNode>)
    }
    // observeContext / update / destroyResources / getImageView: one more `case .skia(let node)` line each,
    // same body as `.thor`.
    // resizeToFitWindow: `.skia` → engine.resizeSkiaNode, as `.thor` → resizeThorNode.
}
```

`ThorCanvas` keeps using `.thor` under any primary node, the same way
`Shader` keeps its own node, so it works in a Skia app too.

### The hard seam: two statics the generic can't reach

The view layer reaches the backend through two statics:

- `ShaderHost.current: ShaderSlotRegistry?` is set by `ViewHost.update` and
  read in `place` by `DrawingGroup`, `ShaderModifiers`, `RenderBoundary`,
  `PrimitiveViews`, `ShaderView`, `VertexShaderView`, `TextureView` and
  `ThorCanvas`.
- `TextMeasurer` is called from `LeafContent` (`Text`), `TextField` and
  `MultilineTextEditing`.

Once the registry holds `CanvasNode<Primary>`, it is
`ShaderSlotRegistry<Primary>` and can't sit in a static. Swift has no
static stored properties in generic types, and a non-generic static would
need `any`. The proposal is to **pass it down instead of reaching up**:

- `NodeContent.place(…)` gains a generic host parameter:
  `func place<Primary: PrimaryRenderNode>(node:in:proposal:context:into:host: ShaderSlotRegistry<Primary>?)`.
- `sizeThatFits` gains `_ primary: Primary.Type`, which is how `Text`
  reaches `Primary.Text`.
- `ViewNode` still stores `any NodeContent` as it does today. Calling a
  generic method on it is plain generic dispatch, not erasure.
- This is a **mechanical** signature change in all ~36 `NodeContent`
  conformers. Most of them just forward the parameter to their children,
  and their logic does not change.
- `TextField` / `MultilineTextEditing` work out caret positions in event
  handlers, outside layout. They capture `Primary.Text.self` (a metatype,
  which is generic) into those closures at `place` time.
- `ShaderHost.current` and the static `TextMeasurer` entry points are
  removed.

I ruled out two alternatives. A pointer-erased non-generic host is the
"`any` inside a generic" you said no to. Package traits / `#if SKIA` is
compile-time switching, not generic.

### What changes in NucleantUI, file by file

**Owning layer: becomes generic over `Primary`, logic unchanged**

- `App/App.swift`: `AppRuntime<A>` holds `[HostingWindow<A.PrimaryNode>]`.
  `ThorEngine.ensureInitialized` stays at launch, because `ThorCanvas` can
  appear in any app and the call is cheap.
- `Scene/Scene.swift`, `WindowGroup.swift`, `TupleScene.swift`,
  `App/Commands.swift`: `_makeWindows()` becomes
  `_makeWindows<Primary: PrimaryRenderNode>(_: Primary.Type) -> [HostingWindow<Primary>]`.
- `App/HostingWindow.swift` → `HostingWindow<Primary>`:
  - `thorNode` becomes `primaryNode: Primary?`, plus
    `shared: Primary.Shared` made once per engine.
  - `attachCanvas` uses `Primary.make`, `node.makeSlot()` and
    `node.makeRenderer()`.
  - The window resize path uses `node.resize`.
- `App/NucleantRenderNode.swift`: the `.skia` case, as above. It stays
  non-generic, and so does the `NucleantRenderEngine` typealias.
- `App/ViewHost.swift` → `ViewHost<Primary>`: `renderer: Primary.Renderer?`.
  It passes `shaderSlots` into the root `place` instead of setting
  `ShaderHost.current`.
- `App/RenderNodeManager.swift` → `RenderNodeManager<Primary>`:
  - `CanvasNode` becomes `CanvasNode<Node: PrimaryRenderNode>`, holding
    `node: Node` and `renderer: Node.Renderer`.
  - `thorContext` moves off the shared type and onto the ThorCanvas pool's
    nodes only.
  - There are two pools. `CanvasNode<Primary>` serves `.drawingGroup`,
    `.shader` layers and the painter.
    `CanvasNode<ThorShaderNode<NucleantRenderNode>>` serves `ThorCanvas`.
  - `acquire` uses `Primary.make`, `resize` uses `node.resize`, `recycle`
    uses `node.clear()`, and `destroy` uses `destroyResources` (already on
    `VulkanRenderNode`). All the
    `tvg_canvas_remove`/`tvg_canvas_destroy` calls leave this file.
- `Render/NodePainter.swift` → generic. Image nodes are made with
  `makeImageNode(format: Primary.copyFormat, viewFormat: <same order>)`.
  Without this, a Skia painter (RGBA) copied into a wgpu-order image (BGRA)
  comes out red/blue swapped.
- `App/ShaderSlotRegistry.swift` → generic, because it holds the `.shader`
  layer's `CanvasNode<Primary>`. Its shader slots themselves are unchanged.

**View layer: signature only**

- `Layout/ViewNode.swift` (`NodeContent`, `ViewNode.place`/layout recursion)
  and all `NodeContent` conformers get the host / `Primary.Type` parameter.
- `DrawingGroup`, `ShaderModifiers`, `RenderBoundary`, `PrimitiveViews`,
  `ShaderView`, `VertexShaderView`, `TextureView`, `ThorCanvas`: use the
  passed host instead of `ShaderHost.current`.

**Drawing**

- `Render/ThorDisplayRenderer.swift`: conforms to `DisplayListRenderer` as it
  is.
- `Render/SkiaDisplayRenderer.swift` (new): see the Skia backend section.
- `Graphics/PrimaryViewRender.swift`: the current stubs (`ViewRender`,
  `AppRenderContext`, `ThorViewRender`) are replaced. This file becomes the
  home of `PrimaryRenderNode`, `DisplayListRenderer` and `TextBackend`.
  The two conformances go in `ThorShaderNode+PrimaryRenderNode.swift` and
  `SkiaShaderNode+PrimaryRenderNode.swift`.

**Text: split "which face" from "load it into the engine"**

- `Graphics/FontRegistry.swift` keeps resolution (`Font` → face name +
  bytes, bundled Roboto first, system faces after) and stops calling ThorVG.
  Loading goes through `Primary.Text.load(name:data:)`.
  - While it's being touched: the `#if canImport(CoreText)` system-font
    lookup in this shared file breaks the platform rule. It moves to
    `FontRegistry+MacOS.swift` / `+iOS` / `+Linux` / `+Android`.
- `Render/TextMeasurer.swift` keeps its caches and `wrap`/`size`, and gets
  advances and line metrics from `Primary.Text`. The ThorVG probe code moves
  into `ThorText: TextBackend`. `ThorEngine` moves to its own file.

```swift
@MainActor
public protocol TextBackend {
    static func load(name: String, data: [UInt8]) -> Bool
    static func advance(of character: Character, family: String?, size: Double, italic: Bool) -> Double?
    static func lineMetrics(family: String?, size: Double) -> (ascent: Double, descent: Double, lineHeight: Double)?
}
```

**ThorVG-only public API: unchanged**

`ThorCanvas`, `ThorCanvasRender`, `ThorContext`, `TCShape` and `TCScene`
keep their API and keep drawing with ThorVG under any primary node, through
the `.thor` pool.

### Skia backend (in NucleantUI)

- `SkiaShaderNode: PrimaryRenderNode`.
  - `copyFormat` is `R8G8B8A8_UNORM`.
  - `clear()` is `canvas.surface?.clear(0,0,0,0)`.
  - `makeRenderer()` returns `SkiaDisplayRenderer`.
- `SkiaDisplayRenderer: DisplayListRenderer`. It mirrors
  `ThorDisplayRenderer` one-to-one.
  - Skia is immediate mode, so `render` is clear + draw. That matches what
    Thor does now, which also rebuilds fully.
  - Paths: move/line/cubic/close, rrect with rx/ry, oval.
  - Fill and stroke: width, cap, join, dash (`SkDashPathEffect`).
  - Linear gradient. Radial gradient as two-point conical with the same
    centre, r0 = startRadius, r1 = endRadius.
  - Clip: `save` → `clipRRect` in the *untransformed* space → `concat` the
    paint's transform → draw → `restore`. This keeps Thor's rule that a
    paint's transform does not move its clipper.
  - Layer render (`origin`/`flipHeight`): the same translate + y-flip
    matrix Thor's root scene gets.
  - Packed render: per item, `save` → `translate(x, y)` → draw → `restore`.
  - Images: `RasterImage` is premultiplied ARGB `UInt32`, i.e. BGRA8 premul
    on little-endian. Raster `SkImage` copy → `drawImageRect` with paint
    alpha = opacity.
  - Text: no paragraph layout. The renderer draws the lines
    `TextMeasurer.wrap` produced (the same function layout used), at
    baseline = top + ascent + i·lineHeight, with x from the alignment and
    the measured line width. Ellipsis = trim + "…" when `isTruncated`.
    Synthetic italic = `setSkewX(-0.2)` when no italic face resolved.
    `DisplayList` does not change.
- `SkiaText: TextBackend`: typeface from bytes
  (`SkFontMgr::makeFromData`) keyed by our name, with advances and metrics
  from `SkFont`. Use linear metrics, no hinting, subpixel on, so advances
  match the unhinted ones ThorVG reports.

Keep the shared painter path for Skia at first, even though a Skia node is
cheap to make (a VkImage + a surface wrap, against Thor's ~60–70 ms wg
canvas). That keeps the comparison like for like. Dropping the painter for
Skia (one node per image) is a follow-up you can decide on once there are
numbers.

### Packaging

- The `.skia` case names `SkiaShaderNode`, so the `NucleantUI` target
  depends on NucleantSkia. `NucleantSkia` joins `nucleantDependencies()`
  (`master`).
- That means the Skia conformance lives **in NucleantUI**, not in
  NucleantSkia as the original sketch had it. NucleantSkia can't import
  NucleantUI, because NucleantUI would then import it back.
- Cost: every NucleantUI app links Skia, even one that stays on Thor.

### Needed outside NucleantUI first (NucleantSkia)

The CSkia C API is only clear/rect/rrect/circle/line/text-with-default-face
today. It needs:

- path building + draw path
- paint: style, width, cap, join, dash, color, shader
- linear and two-point-conical gradients
- save/restore/translate/scale/concat
- clipRRect
- raster image from pixels + drawImageRect with alpha
- typeface from data, `SkFont` size/skew, glyph advances + font metrics,
  draw text with a given typeface

Three other fixes:

- `makeSkiaContext()` hardcodes `VK_EXT_metal_surface`. That's right for
  Apple only; Linux/Android need their own lists (better: read what the
  engine actually enabled).
- `NucleantSkia/Package.swift` has `devMode = true` hardcoded. It must adopt
  the same `NUCLEANT_LOCAL_DEV`/sibling rule as the other packages, or
  NucleantUI's remote resolve breaks.
- `SkiaShaderNode.currentLayout` is internal, but `NucleantUI`'s
  conformance doesn't need it, so this is only a check, not a change.

### Order of work (macOS only, per the one-platform rule)

1. **NucleantSkia**: the C API above + Swift wrappers, with tests in
   `NucleantSkiaTests`.
2. **NucleantUI plumbing with the Thor node only**: generic `Primary`
   through the owning layer, host passed through `NodeContent`,
   `ShaderHost.current` removed, `ThorShaderNode: PrimaryRenderNode`. No
   behaviour change. The existing `NucleantUITests` pass unchanged apart
   from `ViewHost<ThorShaderNode<NucleantRenderNode>>`.
3. **Text split**: `TextBackend`, `ThorText`, FontRegistry load/resolve
   split. Still Thor only, still no behaviour change.
4. **Skia**: the `.skia` case, `SkiaShaderNode: PrimaryRenderNode`,
   `SkiaDisplayRenderer`, `SkiaText`.
5. **Example + tests + numbers**:
   - A Skia showcase app with text-heavy + shape/gradient/clip-heavy
     screens.
   - Tests:
     - `NucleantApp` with no `PrimaryNode` resolves to the Thor node.
     - `ThorText`/`SkiaText` advance parity on bundled Roboto within an
       epsilon.
     - Skia renderer output against Thor's for the same `DisplayList`,
       wherever the existing tests already stand up an engine.
   - `PerfTrace` numbers for both backends on the same screens.

### Decisions for you

1. **`.skia` case in the existing `NucleantRenderNode.Context`.** Is that
   within "no enum switching besides what current already does"? It is a
   case in the switch that's already there; nothing new switches on it.
2. **Pass the host through `NodeContent` (~36 conformers, mechanical)** to
   replace `ShaderHost.current` and static `TextMeasurer`. This is my
   recommendation; the only alternative that avoids it is an erased static.
3. **Skia conformance in NucleantUI**, and NucleantUI depending on
   NucleantSkia. Every app then links Skia. OK?
4. **Example**: a dedicated Skia showcase app, or split the existing demo's
   views into a library so `NucleantUIDemo` and a `NucleantUIDemoSkia` run
   the identical tree side by side? The split refactors the existing demo.
5. **Painter for Skia**: keep the shared painter first for a like-for-like
   comparison, then decide whether Skia gets one node per image.
