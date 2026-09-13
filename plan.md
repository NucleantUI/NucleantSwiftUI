# Goal

Recreate the TouchBay-UI-SDK concept — a SwiftUI-shaped declarative API — but
driven by the Nucleant libs that PyNucleantUI uses, and in pure Swift (no
Python, no SDL).

Same API *shape* as `research/TouchBay-UI-SDK/Sources/SDLUI`; same *engine* as
`PyNucleantUI` (NucleantApplication → NucleantVulkan → NucleantThorVG).

Progress notes and decisions live in [PROCESS.md](PROCESS.md).

# Research

* `research/TouchBay-UI-SDK` — original attempt to wrap SDL / Vulkan as a
  SwiftUI-style API. API shape to match; its render path was never finished
  (`renderNote()` is a `fatalError`), so only the surface is reused.
* `research/SwiftUI-api` — dump of the SwiftUI headers to match the API against.
* `research/OpenSwiftUI` — what TouchBay learned the internals from.
* `PyNucleantUI/PyApi` — the *working* engine wiring (WindowBase, RenderBinder,
  ThorCanvasBase, LayoutSystem). This is what gets ported to pure Swift.

# Architecture

```
NucleantApp (@main)
  └ WindowGroup { ContentView() }
      └ HostingWindow : NucleantWindow, WindowBaseDelegate     <- App/
          ├ PlatformWindow<HostingWindow>   (NucleantApplication)
          ├ VulkanRenderEngine<NucleantRenderNode>  (NucleantVulkan)
          ├ one window-filling ThorShaderNode  (NucleantThorVG)
          │     ↑ display list replayed onto its Tvg_Canvas
          ├ per `Shader` view: an OGLShaderNode composited into its rect
          └ per `.shader(_:)` effect: a ThorShaderNode the view is drawn into
                (never composited) + an OGLShaderNode that samples it
                │
        ViewNode tree  ──sizeThatFits/place──▶  DisplayList
                ↑
        View tree (structs, @ViewBuilder)
```

One ThorVG canvas for the whole window (not one node per view): the view tree
lays out to absolute rects, then emits a flat display list that the renderer
replays as `Tvg_Paint`s. Rebuild happens on invalidation, not per frame.

# TODO

## Phase 1 — foundations
- [x] Package skeleton, dependency graph builds with plain `swift build`
- [x] Geometry: `Point` / `Size` / `Rect` / `EdgeInsets` / `Angle` / `UnitPoint`
- [x] `Alignment`, `HorizontalAlignment`, `VerticalAlignment`, `Edge`, `Axis`
- [x] `Color` (+ sRGB storage, opacity, named colors)
- [x] `Font` (family/size/weight/design/italic) + font registry → ThorVG
- [x] `ProposedSize`

## Phase 2 — core view protocol
- [x] `View`, `Never: View`, `ViewBuilder` (incl. parameter packs)
- [x] `EmptyView`, `TupleView`, `AnyView`, `_ConditionalContent`, `Optional`
- [x] `ViewModifier` + `ModifiedContent`
- [x] `BuiltinView` erasure seam → `ViewNode`

## Phase 3 — layout + display list
- [x] `ViewNode` tree + `NodeContent` (sizeThatFits / place)
- [x] `DisplayList` + `DrawCommand`
- [x] Stack layout (flexibility-ordered, SwiftUI-like), ZStack, frame, padding

## Phase 4 — ThorVG renderer
- [x] `ThorDisplayRenderer` — replays a `DisplayList` onto a `Tvg_Canvas`
- [x] Shapes, rounded rects, ellipses, paths, strokes, gradients
- [x] Text via `tvg_text_*`, measured with `tvg_text_get_glyph_metrics`

## Phase 5 — views
- [x] `Text`, `Color` as a view, `Spacer`, `Divider`
- [x] `Rectangle`, `RoundedRectangle`, `Circle`, `Ellipse`, `Capsule`, `Path`
- [x] `VStack`, `HStack`, `ZStack`, `Group`, `ForEach`
- [x] `Button`, `ScrollView`
- [x] `NavigationStack`, `NavigationLink`
- [x] `Shader` — GLSL 450 compute on its own GPU node (`OGLShaderNode`), with
      file-scope `functions:` alongside the per-pixel body
- [x] `ShaderLibrary` — 8 bundled shaders, 5 ported from TouchBay's collection
- [x] `ShaderFunction(shaderToy:)` — paste an unmodified `mainImage` shader;
      `iTime`/`iTimeDelta`/`iFrame`/`iResolution`/`iMouse` in ShaderToy's types,
      and shader space is y-up (origin bottom-left) as ShaderToy defines it
- [x] `.shader(_:isEnabled:)` — any view as a shader's texture input: the
      view is drawn into a canvas of its own (`layer(uv)`, `uContent`,
      ShaderToy's `iChannel0`) and the shader's output composites in its
      place; input, state and layout untouched. `ShaderLibrary.effects` has
      eight. Static shaders dispatch once; canvases are pooled (§19)

## Phase 6 — modifiers
- [x] `.frame`, `.padding`, `.background`, `.overlay`, `.border`
- [x] `.foregroundColor` / `.foregroundStyle`, `.opacity`, `.offset`
- [x] `.cornerRadius`, `.clipShape`, `.hidden`, `.rotationEffect`, `.scaleEffect`
- [x] `.onAppear`, `.onTapGesture`, `.fill`, `.stroke`
- [x] `DragGesture` (`.gesture(_:)`), `.relativeSize(width:height:)`

## Phase 7 — state
- [x] `@State` with identity-keyed storage across rebuilds
- [x] `@Binding`
- [x] `@Environment` + `EnvironmentValues`
- [x] Invalidation → rebuild on next frame
- [x] `@View` macro: `View` conformance, call-site `ViewID` (stamped by
      `ViewBuilder`), generated `_isEquivalent(to:)` and static wrapper
      binding; subtrees whose view is equivalent are reused

## Phase 8 — app runtime
- [x] `NucleantApp`, `Scene`, `WindowGroup`
- [x] `HostingWindow`: NucleantApplication + Vulkan engine + Thor node
- [x] Input routing + hit testing (mouse/touch → `Button` / `.onTapGesture`)
- [x] Demo executable

## Verified on macOS

`swift build && .build/debug/NucleantSwiftUIDemo`:

- window, text, gradients, shapes, scroll clipping all draw
- three synthetic clicks on `+` take the counter 0 → 3
- `Show/Hide mixer` swaps the `if`/`else` branch; wheel events reach the `ScrollView`
- dragging a fader sets its level (82% → 29%); `Reset` restores the defaults
- the navigation title stays one line and truncates (`…`) from 900pt down to
  280pt; the bar's height no longer depends on the title
- `Shaders` opens a gallery whose three rows each carry a live shader — three
  GPU nodes at once — and pushing a row opens it full screen; `Back` tears the
  slots down without crashing
- `Effects` opens a gallery of eight `.shader` effects over one card, each a
  canvas of its own; a row opens the mixer under that effect, still
  interactive (fader drag, `+`), with the effect toggled off and on, the
  window resized and maximized, then `Back`, `Back`

See [PROCESS.md](PROCESS.md) §4, §7, §8.

Two fixes landed outside this package: `Platform_MacOS.PlatformWindow.mouseUp`
routed to `mouseDown` (and `rightMouseUp` to `rightMouseDown`), so pointer
release never reached any consumer — PyNucleantUI's Python `on_mouse_up`
included. `NucleantApplication/Sources/Platform_MacOS/Platform_MacOS.swift:93,109`.

`scrollWheel` in the same file forwarded the legacy line-based `event.deltaY`
rather than `scrollingDeltaY`, so one wheel notch scrolled 1–4 points instead of
~48, and a trackpad drag barely moved at all. See [PROCESS.md](PROCESS.md) §13.

## Change detection

A write to `@State` dirties **the view that declared it and every view that
read it** — by path, not a global flag — and a read through a `Binding`
counts at the granularity of its key path, so `$tracks[3].level` dirties row
3 and not row 2. The next frame rebuilds from those views downwards. When a
rebuilt body produces a child that is *equivalent* to the one already
standing at that position — same type and `ViewID`, equivalent inputs, same
environment, nothing dirty beneath — the child's whole subtree is kept and
its body is not run. `@View` generates the comparison; `Binding` compares by
source, not value; closures never compare equal.

Canvas rasterization is gated separately: an idle frame does no layout and no
ThorVG drawing at all.

```
full        13.7ms  built=234              first build
scoped(1)    1.1ms  built=4   reused=1     @State on a leaf view
scoped(3)    3.2ms  built=29  reused=21    fader drag — state on the *root* view
full         1.9ms  built=1   reused=2     window resize
```

Traces: `NUCLEANT_SWIFTUI_TRACE_PERF=1` (rebuild kind, timing, cache misses,
`.shader` canvases redrawn; `=2` also names every view built or reused and
why, and each shader slot built with its cost),
`NUCLEANT_SWIFTUI_TRACE_INPUT=1` (hit testing),
`NUCLEANT_SWIFTUI_TRACE_LAYOUT=1` (the placed display list).
[PROCESS.md](PROCESS.md) §5–7, §16.

## Known limits

- **Views holding closures always rebuild.** `Button`, `NavigationLink`,
  `ForEach`, `AnyView` and any modifier taking an action can't be compared,
  so a parent that re-runs rebuilds them — their children are still compared
  and kept. `@View` warns at the declaration when a stored property is a
  closure.
- No `GeometryReader` — `.relativeSize(width:height:)` covers the common case
  (an extent as a fraction of what the parent offered), and
  `DragGesture.Value.bounds` covers the rest.
- A shader with `iChannel` textures, screen-space derivatives (`fwidth`,
  `dFdx`) or `gl_FragCoord` will not compile — the target is a compute shader,
  not a fragment one.
- A `Shader` view is composited by the engine rather than painted into the
  canvas, so `.cornerRadius` on a `Shader` has no effect and it always
  composites as a rectangle. Container clipping *does* reach it — a shader in a
  `ScrollView` is cropped at the edge — via the slot's `compositeScissor`.
- A `.shader(_:)` effect composites as a rectangle too, so clip *inside* it
  (`.cornerRadius(10).shader(fx)`) — the rounding then lands in the texture.
  Effects do not nest: a `Shader` view or another `.shader` inside one is a
  slot of its own, composited over the effect's output rather than through
  it. The canvas is the view's full size, so keep effects on what is on
  screen rather than on a long scroll content.
- `NavigationStack` takes the root title as an argument and a pushed screen's
  title from its `NavigationLink` — there is no preference system, so a child
  cannot hand `.navigationTitle` up to an ancestor.
- `.clipShape` honours a shape's bounding box and corner rounding, not an
  arbitrary outline — the display list carries a (rounded) rect clip, which is
  what ThorVG's clipper wants.
- A modifier applied to a multi-child `Group` affects the first child only;
  SwiftUI distributes it over each.
- Text wrapping is computed twice — in `TextMeasurer` for layout, by ThorVG for
  drawing. Same metrics, so they agree, but they are not one code path.

## Later / not done
- [ ] Animation + transitions
- [ ] `List`, `TabView`
- [ ] Text input / focus
- [x] Post-process shaders over a view (`.shader(_:)`, the `CanvasShader`
      path) — see §19; still open: a whole-window post pass, which is the
      same thing applied to the root
- [ ] `GeometryReader` (needs building a child during layout, not before it)
- [ ] Per-command dirty-region diffing instead of clear-and-re-add
- [ ] iOS run (the code is `#if`-gated and compiles; only macOS was run)
