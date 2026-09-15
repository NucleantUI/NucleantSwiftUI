# Process log

Running notes: what was decided, why, and what state the build is in.
The checklist lives in [plan.md](plan.md).

## 0. Research pass

Read, in order:

| Source | What was taken from it |
| --- | --- |
| `research/TouchBay-UI-SDK/Sources/SDLUI` | The API shape: `View`/`ViewBuilder`/`TupleView`, `Text`/`VStack`/`Shape`, the modifier-struct style (`FrameModifier`, `BackgroundModifier`), `Alignment`, `ShapeStyle`. |
| `PyNucleantUI/PyApi/Window/WindowBase.swift` | The exact bring-up order for a Nucleant window: `PlatformWindow` → `VulkanRenderEngine(metalLayer:)` → build tree → bind → show → seed initial size. |
| `PyNucleantUI/PyApi/Core/RenderBinder.swift` | How a canvas becomes an engine slot: build node, `RenderNode(id:context:)`, `observeContext()`, `engine.append`. |
| `PyNucleantUI/PyApi/Core/Canvas/ThorCanvasBase.swift` | Node adoption (`makeThorWidgetNode(adopting:)`), `markDirty()`, resize-in-place. |
| `NucleantVulkan/.../RenderNode.swift`, `VulkanRenderNode.swift` | `RenderContainerNode` / `RenderNodeContext` — the protocols a host must satisfy. |
| `NucleantThorVG/.../ThorShape.swift`, `ThorText.swift`, `ThorPaint.swift` | The drawing verbs available: `append_rect`, `append_circle`, `append_path`, fill/stroke/gradient, `tvg_text_*`. |
| `NucleantApplication/.../Platform_MacOS.swift` | `PlatformWindow<W>` + `WindowBaseDelegate`, and that the display link calls `win_delegate?.onFrame(dt)`. |

### Findings that shaped the design

* **TouchBay never finished its render path.** `RenderNode` is an empty class,
  `ViewGraph.evaluate` only calls `evalBody()`, `renderNote()` is a
  `fatalError`. So the SDLUI sources are a *specification of the surface*, not
  an implementation to port. Everything below the `View` protocol is new.
* **`View: AnyObject` in `SwiftNucleatUI` was a dead end.** SwiftUI views are
  value types; making them classes breaks `@ViewBuilder` ergonomics and
  identity. `NucleantSwiftUI` uses structs, like SDLUI did.
* **One canvas, not one per view.** `RenderBinder` gives each *widget* its own
  GPU node because a Kivy-style widget tree is coarse. A SwiftUI tree is not —
  a node per `Text` would be hundreds of wgpu targets. So: one window-filling
  `ThorShaderNode`, and the view tree emits a display list into its canvas.
  Per-view nodes stay possible later (that is what the `Later` list means).
* **`CThorVG` is visible transitively.** It is not a product of
  `NucleantThorVG`, but Swift re-exports imported Clang modules, so
  `import NucleantThorVG` is enough to name `Tvg_Paint` / `tvg_shape_new()` —
  confirmed by a probe build before any real code was written. This is the same
  thing `PyNucleantUI/PyApi/Core/Canvas/ThorCanvasBase.swift` relies on.
* **Plain `swift build` works here.** The "only build via ksproject" rule is
  about the *Python wheel*; this package is pure Swift/SPM and resolves the
  three path dependencies directly.

## 1. Build state

**Package graph builds with plain `swift build`.** A probe target confirmed the
three path dependencies (`NucleantVulkan`, `NucleantThorVG`,
`NucleantApplication`) resolve and that `CThorVG` is reachable, before any real
code existed.

## 2. Design decisions taken while writing it

### Views are structs; the tree is rebuilt, the state is not

`SwiftNucleatUI` (the earlier stub in this repo) made `View: AnyObject`. That
was abandoned: `@State` identity has to come from *structural* position — the
path of child indices from the root — and reference identity is exactly the
thing a rebuilt tree doesn't preserve. So:

* `View` is a value protocol, as in SwiftUI and SDLUI.
* `BuildContext.path` accumulates a child index per level.
* `StateStore` keys every `@State` slot on `(path, propertyIndex, viewType)`.
* Property wrappers hold a `Holder` class; `Mirror` hands back a *copy* of the
  wrapper, but the copy shares that one reference — which is what makes binding
  through reflection work at all.
* `ForEach` uses the element's id hash as its path component, not the ordinal,
  so reordering a list carries each row's state with it.

### One canvas per window, not one per view

`RenderBinder` in PyNucleantUI gives every Kivy-style widget its own GPU node.
A SwiftUI tree is far finer-grained — a node per `Text` would mean hundreds of
wgpu targets and Vulkan image imports. So the whole tree lays out to absolute
rects and emits one flat `DisplayList`, replayed onto a single window-filling
`ThorShaderNode`'s canvas.

Consequences, all deliberate:

* A rebuild clears the canvas (`tvg_canvas_remove(canvas, nil)`) and re-adds
  paints. Diffing paints across passes buys nothing while rebuilds are already
  gated on invalidation — `ViewHost.update()` returns false and touches nothing
  on a frame where no state changed.
* Opacity is folded into colors at emit time rather than set per-paint, so a
  faded gradient fades.
* Clipping is a rect (optionally rounded) carried on each command and applied
  as a ThorVG clipper paint. `.clipShape` therefore honours a shape's bounding
  box and corner rounding, not an arbitrary outline.

### Text is measured through ThorVG's own metrics

`tvg_paint_get_aabb` is only meaningful after a canvas has updated the paint,
and layout runs before anything is on a canvas. `TextMeasurer` instead sums
per-glyph advances from `tvg_text_get_glyph_metrics` and takes line height from
`tvg_text_get_text_metrics`, caching both per face. Wrapping is done in Swift
for sizing and repeated by ThorVG for drawing — same metrics, so they agree.

Fonts are loaded with `tvg_font_load_data(name:…)` rather than
`tvg_font_load(path)`: the former lets us choose the key that
`tvg_text_set_font` will later match, instead of guessing the family name
inside the file. `FontRegistry` maps a `Font`'s design/weight/italic onto the
separate face files macOS actually ships (`Helvetica Bold.ttf`, …).

### Stack layout sizes least-flexible-first

`StackContent` groups children into `fixed` / `content` / `flexible` and sizes
each group against an equal share of what the stricter groups left. That is what
makes `HStack { Text; Spacer; Text }` give the texts their natural widths
instead of splitting the width three ways. A `Spacer` is `.flexible`, a
`.frame(width:)` is `.fixed`, everything else is `.content`.

`Spacer` and `Divider` need to know their stack's axis *before* the stack lays
out, so `BuildContext.stackAxis` carries it down the build.

### Isolation

`NucleantWindow` / `WindowBaseDelegate` are non-isolated protocols, and the view
layer is `@MainActor`. `HostingWindow` is therefore a non-isolated class whose
callbacks each wrap their body in `MainActor.assumeIsolated` — every one of them
is genuinely called on the main thread (AppKit dispatch, the display link), and
this asserts it rather than assuming it.

## 3. Bring-up on macOS

Three real failures, in the order they showed up.

1. **`tvg_wgcanvas_create` returned null.** ThorVG's engine has to be started
   before *any* canvas exists — `PyApp.init` calls `tvg_engine_init(threads)`
   and nothing in this package did. `AppRuntime.onStart` now calls
   `ThorEngine.ensureInitialized` first; the renderer and text measurer keep
   their own backstop call for a `ViewHost` driven without `NucleantApp`.

2. **The window was invisible.** A window built from a bare `contentRect`
   lands at AppKit's origin — the *bottom-left* of a screen — which on a
   two-display setup is easy to lose entirely. `presentMacOS` now centres it.

3. **`mouseUp` never arrived.** `Platform_MacOS.PlatformWindow.mouseUp` called
   `win_delegate?.mouseDown(...)`, and `rightMouseUp` called
   `rightMouseDown` — a copy-paste bug in NucleantApplication, not in this
   package. It makes pointer release unreachable for *every* consumer,
   PyNucleantUI's Python `on_mouse_up` hook included. Fixed in place
   (`NucleantApplication/Sources/Platform_MacOS/Platform_MacOS.swift:93,109`),
   since `Button` fires its action on release and cannot work without it.

Diagnostics note: Swift's `print` is fully buffered when stdout isn't a
terminal, so the engine's own failure messages vanish if the process is killed.
`HostingWindow` flushes stdout before writing its own failure line to stderr,
which is what made (1) visible at all.

## 4. Verified on macOS

`swift build` at the package root, then `.build/debug/NucleantSwiftUIDemo`.

* The window comes up, the ThorVG node imports as a VkImage
  (`VK_EXT_metal_objects`), and the tree draws: text, gradients, rounded
  rects, capsules, a scroll region, buttons.
* Input works end to end. Three synthetic clicks on the demo's `+` button take
  the counter from 0 to 3 — press → release-inside → action → `@State` write →
  `Invalidator` → rebuild on the next display-link tick → repaint.
* `NUCLEANT_SWIFTUI_TRACE_INPUT=1` traces hit testing to stderr; it is what
  distinguished "the click missed" from "the click never arrived" while
  chasing the `mouseUp` bug above.

Note on driving it from a script: `System Events`' `click at` only exercises
the accessibility layer, which an `NSWindow` with no AX children ignores
entirely — it reports success and does nothing. Real verification needs a
`CGEvent` posted to `.cghidEventTap`.

## 5. The UI was unusably slow — measured, then fixed

Reported as "ultra slow responsive UI". Instrumented rather than guessed at, and
the numbers were unambiguous:

```
[perf] rebuild 356.4ms  measures=258 resolves=280 nodes=195 sizeThatFits=567
[font] load Helvetica from /System/Library/Fonts/Helvetica.ttc -> FAIL (1.4ms, attempt #29)
...1963 load attempts over one 25s run, nearly all the same failing file
```

Every interaction cost a ~356ms rebuild. Three compounding causes:

### 1. ThorVG cannot load `.ttc`, and failures were not cached (~85% of the cost)

macOS ships Helvetica and Menlo *only* as TrueType Collections. ThorVG's loader
rejects a collection outright — but `FontRegistry` remembered only successes, so
every call re-read the whole ~1MB file and re-failed, at ~1.3ms a go. Font
resolution sits on the layout hot path (every text measurement asks for it), so
one rebuild burned ~300ms re-reading one unparseable file 280 times.

Fixed three ways, all of which were missing: a `Font → face name` resolution
cache so the search runs once per distinct font; a `failed` set so an unusable
face is never retried; and `.ttc` dropped from the searched extensions, which
turns the whole thing into a `stat` miss. The built-in face lists were also
reordered to put a `.ttf` that actually parses first (Helvetica Neue / Monaco
ahead of Helvetica / Menlo).

### 2. Layout re-measured the same subtrees over and over

195 nodes took 567 `sizeThatFits` calls, because `place` re-measures what the
measuring pass already computed — a stack measures every child to size the run,
then measures again to position them, and every level above repeats that for its
whole subtree. `ViewNode` now memoizes measurements by proposal, and
`TextMeasurer` caches measured boxes by (string, font, proposal, line limit).
Nodes are rebuilt each pass, so there is nothing to invalidate.

### 3. The canvas was re-rasterized every frame, changed or not

`RenderContainerNode.needsRender` starts `true`, and the upstream ThorVG node
deliberately never clears it (the comment in `ThorShaderNode.update` says so —
it predates anything actually driving updates). So `canvas.draw()` + `sync()`
re-ran on every display-link tick over an unchanged scene.

`NucleantRenderNode.update` now clears the flag once it has drawn, and
`HostingWindow.markNeedsRedraw()` re-arms it when — and only when — a rebuild
actually repainted. Compositing is unaffected: the engine walks every slot and
samples its image regardless of the flag, and a slot stays in the engine's
`readable` set once published, so the last-drawn frame keeps being presented.

Re-arming is done on the slot directly rather than through the Observation
chain: that only fires on a *change* to `node.dirty`, so a repaint while `dirty`
was already `true` would post no notification and the canvas would never redraw
again.

### Result

```
[perf] rebuild 10.2ms nodes=195 measured=307 text=165   <- first, cold caches
[perf] rebuild  4.0ms nodes=195 measured=307 text=0     <- click on "+"
[perf] rebuild  4.1ms nodes=195 measured=307 text=6     <- only the changed label
font load attempts: 0 after warm-up                      (was 1963)
```

**356ms → 4ms on the interactive path** (~89×), and idle frames now skip
canvas rasterization entirely. `text=0` on the second pass is the measurement
cache surviving across rebuilds — only a label whose string actually changed
gets re-measured. `measured=307` stays flat because the *node* cache is
per-pass by design: nodes are rebuilt each time, so their caches die with them. `NUCLEANT_SWIFTUI_TRACE_PERF=1` prints the rebuild line; its counters are cache
*misses*, so numbers that climb pass over pass mean something is defeating a
cache.

Still on the list, and a different thing from the above: the renderer clears the
canvas and re-adds every paint on a repaint. That is now only paid when the tree
actually changed, but a per-command diff would make a small change cost a small
repaint rather than a whole-scene one.

## 6. Real change detection — I was wrong about TouchBay

I claimed in §0 that TouchBay's `@State` never detected changes. That is true of
`SDLUI` — `isUpdated` is hardcoded `return true` and `wrappedValue`'s getter is
a `fatalError` — but **not** of `TouchBayUI_old`, the older framework in the
same repo, which has the real thing:

* `State.Storage` carries a `version`, bumped on every write.
* Reading `wrappedValue` during a body evaluation calls
  `ViewGraph.registerStateOwner` and `node.recordStateDependency(key:version:)`.
* Writing calls `markStateDirty(stateKey:)`, which dirties **only the node that
  owns that state** and propagates a `hasDirtyDescendant` flag up its ancestors.
* `ViewNode.hasChangedDependencies()` compares recorded versions against current
  ones, so a clean subtree can skip its body entirely.

My first version had none of that: one global boolean, and a full rebuild of the
whole tree on any write. It detected *that* something changed, never *what*.
Measured on the demo, the build phase was 2.6–3.1ms of a 4ms rebuild — so this
was also the largest remaining cost, not just an architectural complaint.

### What replaced it

* `StateStorage` carries a `version` and the `ownerPath` of the view that
  declared it. `@State`'s setter and any `Binding` derived from it both go
  through one `set(_:)`, so neither can bump the version without invalidating.
* `DependencyTracker` publishes the identity currently being built;
  `@State`'s *getter* reports reads against it. Same shape as
  `ViewGraphBuilder.currentBuildNode`.
* `Invalidator` collects dirty **paths** instead of a boolean.
* `buildNode` files a `RebuildRecords` entry per path: the environment at that
  point and a closure that rebuilds *that view* there, plus the node it
  produced.
* `ViewHost.rebuildScoped` rebuilds only the dirty subtrees and splices each
  one into its parent (`ViewNode.replaceChild`), then clears the cached
  measurements of every ancestor — each of those was computed from the subtree
  just replaced.

Rebuilding from the state's owner *downwards* is what makes this correct, not
just cheap. Nothing above the dirty view re-runs, so nothing above it can have
handed it different inputs — the stale-props hazard of skipping a child's body
never arises.

### Two bugs found while verifying, one hiding the other

The first scoped run reported `scoped` but still built all 195 nodes. Cause:
`buildNode` recorded *how* to rebuild each path but never *which node* that path
produced, so every scoped attempt found nothing to splice and silently fell
back. It was silent because the trace printed the rebuild kind decided *before*
the fallback — a log reporting the plan rather than the outcome. Both fixed; the
trace now distinguishes `full` / `scoped(n)` / `fallback`.

### Result

```
[perf] full        10.2ms built=209   <- first build
[perf] scoped(1)    1.3ms built=8     <- button press (@State on Button)
[perf] scoped(2)    2.1ms built=20    <- press + release (Button + Counter)
[perf] fallback     5.1ms built=209   <- @State owned by the *root* view
```

**Honest limit:** state declared on the root view still rebuilds everything,
because the dirty subtree *is* the tree — the demo's `tracks` array lives on
`ContentView`, so a fader drag takes the `fallback` path at ~5ms a frame (13
rebuilds over one drag, all inside a 16ms budget). Making that scoped needs
child-level view-value diffing — comparing a freshly built child view against
the previous one and reusing its subtree when equal, which is how SwiftUI avoids
re-running every row of a `ForEach`. `TouchBayUI_old` doesn't do that either.
Getting it wrong shows stale UI, so it is on the Later list rather than guessed
at.

## 7. Faders and Reset

Both reported broken. Both were:

* **Faders didn't move** — the framework had no drag gesture at all, only taps.
  Added `DragGesture` with `onChanged`/`onEnded`, a `minimumDistance`
  threshold, and drag routing in `ViewHost.pointerMoved` that keeps reporting to
  the view the gesture *started* on even after the pointer leaves it.
  `DragGesture.Value` carries `bounds` — not a SwiftUI field, but without a
  `GeometryReader` a fader has no other way to turn a position into a fraction.
* **Reset did nothing** — `Button("Reset") {}`, an empty action I wrote. Now
  restores the default levels, which meant making the track list `@State` and
  passing each row a `Binding`.

### A layout bug the faders exposed

The fills rendered at the wrong width *and* the wrong position: an 82% fader
came out 443pt wide, centred inside a correct 541pt box. The fraction was being
applied twice — `place` re-derived each child's size by re-proposing
`ProposedSize(rect.size)`, and for a node whose size is a *function* of its
proposal that compounds.

Fixed by threading the proposal through placement:
`place(in:proposal:context:into:)`, where `proposal` is the one that produced
`rect`. SwiftUI's `placeSubviews(in:proposal:subviews:)` does the same, for the
same reason. `StackContent.layout` now returns the per-child proposals it used
so placement can reuse them rather than invent new ones. This was a latent bug
for any proposal-dependent sizing, not just faders — the fader is simply the
first view that had any.

`NUCLEANT_SWIFTUI_TRACE_LAYOUT=1` dumps the placed display list, which is what
turned "the bars look wrong" into "443.78 centred in 541.20" in one run.

## 8. NavigationStack and the Shader view

### NavigationStack

Pure view layer, no GPU work. `NavigationStack` owns the screen list in
`@State`; `NavigationLink` reaches the enclosing stack through a
`NavigationRouter` handed down the environment, which writes back through the
stack's own `Binding`. So a push invalidates the stack's subtree and nothing
else. Only the top screen is built — the ones underneath are off screen, and
building them would run their `onAppear` too.

Two deviations from SwiftUI, both from the same missing piece: there is no
preference system, so a child cannot hand a value *up*. The root's title is
therefore given to `NavigationStack(_:)` rather than set with
`.navigationTitle` inside it, and a pushed screen's title comes from the
`NavigationLink` that pushed it.

### The Shader view

A vector canvas cannot run a fragment shader, so a `Shader` view cannot draw
into the shared ThorVG canvas the way every other view does. It gets **its own
GPU node**, composited into its own rect — which is what
`RenderContainerNode.compositeRect` has always been for, and what the "make a
new OpenGL node" instruction pointed at.

What was already there, and what wasn't:

| Piece | Status |
| --- | --- |
| `OGLShaderNode` — dispatch, barriers, teardown | Complete, but **never constructed**: no factory anywhere, and the engine's own `update(_ node: OGLShaderNode…)` is commented out |
| `VKShaderCompiler.tryCompileCompute` (GLSL 450 → SPIR-V via shaderc) | Works, used as-is |
| `VulkanCore.createStorageImage` | Exists, but is a method on the `VulkanCore` bootstrap class, not on `VulkanContext` — unreachable from the render engine, so re-written against the engine |
| `VulkanContext.createBuffer`, `ShaderModuleLoader` | Used as-is |
| Descriptor/pipeline setup | New (`ShaderPipeline`), modelled on `CanvasShader`'s `CanvasPostPipeline` but with a storage-image output instead of a sampled input |

**Uniforms without touching the engine.** `OGLShaderNode.update` binds a
pipeline and dispatches; it never pushes constants. Rather than change the
engine, `time` / `resolution` / `mouse` go through a HOST_VISIBLE|COHERENT
uniform buffer at binding 1, rewritten from the host each frame — a plain
memcpy needing no command-buffer participation, so the existing `update` works
untouched.

**Slot lifetime is the real work.** A shader's node has to be created when the
view appears, moved and resized as it is laid out, and destroyed when it goes
away. `ShaderSlotRegistry` keys slots on the view's structural path — the same
identity `@State` uses — so a shader keeps its compiled pipeline across
rebuilds. `ShaderContent.place` claims its slot and writes its rect; anything
unclaimed at the end of the pass is torn down (drained first, then
`engine.remove(id:)` and `destroyResources`). Only a *resize* or a source
change rebuilds the GPU objects; moving a view just rewrites `compositeRect`,
which the engine re-reads every frame.

**Shaders are never idle.** §5 made idle frames free by clearing `needsRender`
after a draw. A shader is animated by definition, so `ShaderSlotRegistry.tick`
re-arms its slot and advances its clock every frame. A tree containing no
`Shader` view does nothing there — the cost is opt-in, per shader.

GLSL contract: the body is written in fragment terms (`uv`, `fragCoord`,
`time`, `resolution`, `mouse` in scope, assign `fragColor`) and wrapped into a
`local_size_x = 8, local_size_y = 8` compute shader — matching the `(w + 7) / 8`
dispatch in `OGLShaderNode.update` exactly. Source starting with `#version` is
passed through as a complete compute shader instead. TouchBay's
`Shaders/PlasmaShader.swift` ported across almost verbatim.

**Limit:** a shader view is composited by the engine, not painted into the
canvas, so canvas-level clipping does not apply to it — `.cornerRadius` on a
`Shader` has no effect, and it always composites as a rectangle.

### Two crashes tearing a shader slot down

Navigating *back* off the shader screen segfaulted. Both causes were mine.

1. **Double free.** `ShaderSlotRegistry.destroy` called
   `engine.remove(id:)` *and* `node.destroyResources(engine)`. But
   `VulkanRenderEngine.remove(id:)` already calls `destroyResources` on the
   slot it drops — so the image, view and memory were freed twice.

2. **Freeing inside the frame.** With the double free gone it still crashed, in
   `OGLShaderNode.destroyResources` → MoltenVK, null deref. `endPass` runs
   inside `ViewHost.layoutAndRender`, i.e. mid-frame, with command buffers for
   frames still in flight referencing the image — and a `vkDeviceWaitIdle`
   right there was not enough to make it safe.

   Fixed by splitting detach from free: `endPass` takes the slot out of
   `engine.nodes` and clears the engine's per-slot caches
   (`invalidateComposite`), which is all that has to happen immediately, and
   queues the GPU objects. `releasePending` frees them at the top of the next
   frame behind one drain, outside any recording.

The crash reports (`~/Library/Logs/DiagnosticReports/*.ips`) named the faulting
frame directly, which is what made these quick — worth remembering, because the
process just vanishes otherwise and the log says nothing.

Verified after the fix: navigate in → plasma renders and animates (two captures
four seconds apart differ), navigate back → shader gone, `About` restored,
process alive, no new crash report.

## 9. The demo's shader showcase

`NavigationStack` was already the demo's root from §8, but the shader sat two
levels down under "About". Restructured into a gallery reached from a top-level
"Shaders" link:

```
Nucleant Mixer ──▶ Shaders ──▶ Plasma / Motion blur / Tunnel
               └─▶ About
```

Every gallery row carries a **live** shader thumbnail, so that one screen runs
three compute nodes simultaneously — three GPU slots, each with its own image,
pipeline and composite rect. That is the part worth showing: it exercises the
per-view slot machinery at more than one slot, which the single-shader screen
never did.

### One API gap the ports exposed

The first wrapper inlined the body straight into `main()`, which means a body
could not declare a helper — GLSL has no nested function definitions, and
TouchBay's shaders lean on file-scope helpers (`CirclesMotionBlurShader`
declares `circle()` and `scene()` before its main). `ShaderFunction` now takes
`functions:` alongside the body and emits it at file scope, the same split
TouchBay's `FragShaderFunction(functions:main:)` uses. `PI` / `TAU` / `HALF_PI`
are declared by the wrapper so every body doesn't redeclare them.

Three shaders ship in the demo: `Plasma` (TouchBay's, near-verbatim),
`Motion blur` (TouchBay's `CirclesMotionBlurShader`, which is there because it
*needs* `functions:`), and `Tunnel` (written here, loop-heavy).

## 10. The clipped navigation title

Reported from a screenshot: the nav bar's "Nucleant Mixer" wrapped to two lines
and the second was cut off by the bar's own bottom edge.

**Not a fixed-size bar.** Measured across 320 / 900 / 1060pt and through a
stepped resize, the bar sizes itself from its content correctly — 46.06pt for a
one-line title, 72.13pt for a two-line one. The resize path relayouts properly
too (root width tracked 900 → 950 → 1000 → 1060). So the exact clip did not
reproduce here, and the cause of that particular frame is still unknown.

Two real defects the report exposed, both fixed:

1. **`.lineLimit(1)` overflowed instead of truncating.** The renderer mapped it
   to `TVG_TEXT_WRAP_NONE`, which lets text run straight past its box — which is
   what a clipped label looks like. Now `TVG_TEXT_WRAP_ELLIPSIS`, so a
   one-line limit ends in "…" inside its frame.

2. **The navigation title could wrap at all.** A title bar is a single line on
   every platform, and letting the title reflow makes the bar's *height* depend
   on the window's width — so narrowing the window pushes all the content down.
   The title is now `.lineLimit(1)` and the bar carries `minHeight: 44`, so its
   height no longer depends on what the title happens to be.

Verified at 900 → 700 → 500 → 360 → 280pt: the bar stays 46.06pt and the title
stays one line, truncating to "Nuclea…" rather than wrapping or overflowing.

## 11. A shader library, and two things it exposed

Seven shaders now ship in the framework as `ShaderLibrary` — the counterpart of
TouchBay's `Shaders` target — rather than living in the demo. Five are ports of
`research/TouchBay-UI-SDK/Sources/Shaders`, two written here:

| Shader | Origin |
| --- | --- |
| Plasma | TouchBay `PlasmaShader` |
| Motion blur | TouchBay `CirclesMotionBlurShader` |
| Fractal pyramid | TouchBay `FractalPyramid` — 64-step raymarch |
| Cyber Fuji | TouchBay `CyberFuji2020` — CC BY 3.0, Jan Mróz |
| Bokeh parallax | TouchBay `BokehParalax` |
| Frosted glass | TouchBay `SupahFrostedGlass` |
| Tunnel | written here |

Of the 15 sources in TouchBay's library, only two (`BloomingElectric`,
`BumpedSinusoidalWarp`) are unportable as-is — they sample `iChannel` textures or
use screen-space derivatives, neither of which a compute shader has.
`ProteanClouds` was skipped for a softer reason: it reads `gl_FragCoord` and
keeps mutable globals, so it needs real editing rather than a port.

### Globals, not locals

Porting `CyberFuji2020` forced a wrapper change. Its helpers read `time`
directly rather than taking it as a parameter — `sun()` and `grid()` both do —
so `time` / `resolution` / `mouse` had to move from locals in `main` to
file-scope globals assigned at the top of it. The ShaderToy spellings
(`iTime`, `iResolution`, `iMouse`) are declared alongside, so a port usually
needs only its `vec2 fragCoord = TexCoord * iResolution;` preamble deleted and
`FragColor` renamed. The body still runs inside its own `{ }` block, so a port
that redeclares `uv` or `fragCoord` shadows rather than collides.

### The ellipsis bug the gallery exposed

With more screens to navigate, the title bar started reading "Shade…" for
"Shaders" — in an 89.45pt box, with the word needing well under that.

`TVG_TEXT_WRAP_ELLIPSIS` reserves room for the "…" *whenever the mode is set*.
Layout produces a box measured to exactly fit its text, so switching every
`.lineLimit(1)` label to ellipsis mode (§10) guaranteed every one of them lost
characters it had room for.

Fixed by deciding truncation at layout time, where the natural width is already
known: `TextDraw.isTruncated` is set only when the string really is wider than
its box, and the renderer picks `ELLIPSIS` or `NONE` from that. Half a point of
slack absorbs the difference between summed glyph advances and ThorVG's own
layout.

## 12. ShaderToy sources can't be fetched from here

Sixteen ShaderToy shaders were requested by URL. All of shadertoy.com is behind
a Cloudflare interstitial from this machine — the shader page, `/embed/{id}`
and the REST API (`/api/v1/shaders/{id}?key=…`) each return either a 403 or the
"Just a moment…" challenge page, so even an API key would not help from here.

Reconstructing them from memory was not an option: they are other people's
work, and an approximation carrying its author's name is worse than nothing.

What was built instead is the machinery that makes adding one a single line.

### `ShaderFunction(shaderToy:)`

Paste an unmodified ShaderToy shader — helpers and its
`void mainImage(out vec4 fragColor, in vec2 fragCoord)` — and it is emitted at
file scope and called once per pixel.

For that to work on unmodified sources, the wrapper now declares ShaderToy's
uniforms **with ShaderToy's types**, which the earlier aliases did not:
`iResolution` is a `vec3` (shaders divide by `iResolution.xy` but also read
`.z`), `iMouse` is a `vec4` (`iMouse.z > 0.0` is the standard press test), and
`iTimeDelta` / `iFrame` exist at all. The uniform block became three `vec4`s so
its std140 layout needs no guessing.

Still incompatible, because the target is a *compute* shader rather than a
fragment one: `iChannel0`…`iChannel3` and `texture()` against them, the
screen-space derivatives (`fwidth`, `dFdx`, `dFdy`), and `gl_FragCoord`
(`mainImage`'s own `fragCoord` parameter carries the same value). A shader
using those needs reworking, not wrapping.

### Compile errors are now visible

`VKShaderCompiler` read shaderc's diagnostics into `_` and discarded them, so a
rejected shader produced nothing but "build failed". It now keeps them in
`lastErrorMessage` (additive — the return type is unchanged, so existing callers
are unaffected), and `ShaderPipeline` puts the real GLSL error in the thrown
message. Pasting a shader that does not compile now says which line and why.

An eighth library entry, `shaderToyExample`, is written in ShaderToy's own form
rather than ported, so the adapter itself is covered by the demo.

## 13. Scrolling moved a few pixels per drag

`Platform_MacOS.PlatformWindow.scrollWheel` forwarded `event.deltaX/deltaY` —
the **legacy line-based** deltas. Two problems with that:

* On a precise device (trackpad, Magic Mouse) `deltaY` reports a *fraction of a
  line*, so a whole two-finger drag adds up to a few points.
* On a classic wheel it reports **lines**, which the scroll view then consumed
  as though they were points: one notch moved 1–4 points instead of ~48.

`scrollingDeltaX/Y` is the value those devices actually report — points when
`hasPreciseScrollingDeltas` is set, lines otherwise. `scrollWheel` now uses it
and converts lines to points (16pt per line) for the non-precise case.

Measured with real input afterwards: per-event deltas of 16–272 points, all
multiples of 16 (so the reporting device is line-based, and each notch is now
1–4 *lines* rather than 1–4 points). Previously the same input produced 1–4.

This is the second bug in that file — see §3's `mouseUp` — and like that one it
affected every consumer, PyNucleantUI's Python `on_scroll` included.

## 14. Shader views ignored their container's clip

A `Shader` inside the gallery's `ScrollView` scrolled straight over the
navigation bar. §8 listed this as a limitation ("canvas-level clipping does not
reach a shader view") — but calling it a limitation was wrong. A scroll view
that doesn't clip its rows is a bug.

The cause is the same fact: a shader view is composited by the engine into its
own rect, so the display list's clip — which every canvas-drawn view respects —
never applies to it.

Cropping `compositeRect` would be wrong: the viewport is what maps the node's
image onto the swapchain, so a cropped viewport *squashes* the image into the
visible sliver instead of hiding the rest. The image must stay mapped to the
full frame while only part of it is allowed to rasterize — which is precisely
the difference between a viewport and a scissor, and
`recordCompositePass` already passed the two separately.

So: `RenderContainerNode` gained `compositeScissor` (default `nil`, so no
existing node type is affected), the composite pass uses it for the scissor
while keeping the viewport from `compositeRect`, and `ShaderContent.place`
hands its `DrawContext.clip` to the registry, which intersects it with the
view's own frame. Offsets are clamped to the swapchain — a scrolled-off view
naturally produces negative and past-the-end rects, both of which Vulkan
rejects.

Verified from the layout trace on the gallery (8 rows, 620pt viewport):

```
shader rect y=106 h=68   scissor h=68   <- fully visible
shader rect y=596 h=68   scissor h=24   <- cropped at the scroll view's edge
shader rect y=694 h=68   scissor w=0 h=0 <- past the edge, not drawn
```

Third bug in this area found by using the thing rather than reasoning about it,
after `mouseUp` (§3) and the scroll deltas (§13).

## 15. Shaders rendered upside down

ShaderToy's `fragCoord` has its origin at the **bottom-left** — y up. The
wrapper handed the body a top-down frame:

```glsl
vec2 fragCoord = vec2(pixel) + 0.5;   // pixel.y == 0 is the TOP row
```

so every ported shader came out vertically mirrored. Invisible in a symmetric
one (Plasma, Tunnel), obvious in anything with a horizon: `CyberFuji2020`
draws its neon floor grid under `if (p.y < -0.2)`, and it had been appearing
along the *top* of the frame in every screenshot.

Fixed by flipping the coordinates handed to the body — not the image. The store
location (`pixel`) is untouched, so nothing about the composite changes:

```glsl
vec2 fragCoord = vec2(float(pixel.x) + 0.5, float(size.y - pixel.y) - 0.5);
vec2 uv        = fragCoord / resolution;
```

`mouse` / `iMouse` are flipped with them, so shader space is y-up throughout
and matches what a pasted ShaderToy source expects.

Worth noting this was invisible in the *layout* traces — the clipping work in
§14 measured correct rects the whole time while the pixels inside them were
upside down. Geometry being right says nothing about orientation.

## 16. Node lifetime, `@View`, and reusing what is already standing

Asked as "how is a shader node's lifetime handled — does every view change
make a new RenderNode / ThorShader?", with a sketch of a `@View` macro that
stamps each view with a call-site `ViewID` and generates a compare function
over its properties, so the framework can keep a view's node alive and only
update it.

### What was already true

GPU nodes were never per-rebuild. There is one window-filling `ThorShaderNode`
per window (§0, "one canvas, not one per view"), and a `Shader` view's
`OGLShaderNode` slot is keyed by structural path in `ShaderSlotRegistry` and
survives rebuilds — it is only rebuilt on a resize or a source change, and
torn down when the view leaves the tree (§8). So nothing on the GPU side
churned.

What *did* churn was the `ViewNode` layout tree. A `@State` write rebuilt the
owner's whole subtree, and state on the root view rebuilt everything —
§6's "honest limit", with "child-level view-value diffing" on the Later list.
That is what the sketch was really after, and it is what this section adds.

### Two facts about `#line` that shaped the macro

The sketch had `ViewID.init(line: Int = #line, …)` used as a default argument
of the view's own init. Measured rather than assumed, with a probe binary:

* A nested magic literal names the line it is *written* on. `ViewID()` as a
  default argument is written in the declaration, so every `Test()` got the
  same id — the playground in `../structID.playground` reports line 15 for a
  call on line 20.
* SE-0422 fixes exactly this for macros: an expression macro used as a
  parameter default is expanded at the call site. `_viewID: ViewID = #viewID`
  works. A stored property's initializer does not get that treatment, even
  though the memberwise init copies it — so the macro has to synthesise the
  init itself to reach the caller.

Second probe: a `View` conformance added by an extension macro does not infer
`@MainActor` onto the struct the way `struct S: View` does, so `body` came out
nonisolated and could not call the framework. `@View` therefore also has a
`memberAttribute` role that stamps `@MainActor` on every computed property,
function and initializer — and the members it generates carry the attribute
explicitly, since the role does not reach them.

### `@View`

Three roles on one attribute (`Sources/NucleantSwiftUIMacros`):

* extension: `View` (if not declared) and `IdentifiedView`.
* memberAttribute: `@MainActor` as above.
* member: `_viewID` (declaration-site default), `_isEquivalent(to:)`, and —
  only when the struct declares no init — a memberwise-style init ending in
  `_viewID: ViewID = #viewID`. A hand-written init keeps the declaration-site
  id unless it takes a `_viewID` parameter itself. Properties whose type is
  only inferred from an initializer are left at that value, not guessed at:
  the macro sees syntax.

`_isEquivalent` is one `_areEquivalent(self.p, other.p)` per stored property,
skipping `@State` (owned, not an input) and `@Environment` (compared by the
builder separately). Four overloads of `_areEquivalent` let the compiler pick
the static path for `Equatable` or `ViewInput` types and a runtime one
otherwise: `ViewInput` first, then `Equatable`, then a `Mirror` walk over
plain structs/tuples/optionals/collections. Closures, classes and payload-less
enums answer *no* — stale UI is the failure mode of a wrong *yes*, so every
undecidable case is a no.

`Equatable` is the wrong tool for the two inputs that matter most, which is
why the protocol is called equivalence:

* A `Binding` is compared by **source** — the state slot it was projected from
  plus the key paths walked since (`$tracks[3].level` is
  `(slot, [\.[3], \.level])`). Not by value: two bindings onto the same slot
  read the same value whether it changed or not.
* Environment values are compared per key, with a version stamp as the fast
  path for an untouched copy.

### Readers, at key-path granularity

§6 recorded which state each view read, and never used it. Reuse is what
makes the record necessary: a child whose props are unchanged but whose
binding's target moved must not be kept. So a write now dirties the owner
*and every reader*.

First attempt tracked readers per slot, and a fader drag dirtied all seven
rows — each reads `tracks` through its binding. Reads and writes now carry
the binding's key-path chain down to the slot, and a write reaches a reader
only when the two chains are nested either way: `[3].level` reaches the
whole-array reader (`ContentView`) and row 3, not row 2. `Binding` got a
second, chain-carrying pair of accessors for this; the public surface is
unchanged.

### The rebuild itself

`buildNode` asks, before building, whether the subtree standing at this
position from the last pass will do. Every condition is necessary and each
has a name in the `NUCLEANT_SWIFTUI_TRACE_PERF=2` trace:

| reason | what changed |
| --- | --- |
| `identity` | type or `_viewID` differs |
| `stack axis` | a `Spacer`/`Divider` would size against the wrong axis |
| `dirty` | a state write landed at or beneath this path |
| `environment` | a value a builtin bakes in at build time differs |
| `inputs` | `_isEquivalent` said no |

Records moved from a flat `[path: Record]` to a path trie
(`RebuildRecords`): taking a subtree out for rebuild, putting a reused one
back, and collecting what is left over are each one pointer, not a scan of
every key. The flat version scanned ~230 entries per reused subtree and a
drag came out at 33ms — worse than the full rebuild it replaced. Leftovers
after a pass are views that vanished, and only then are their `@State`,
`onAppear` marks and reader registrations released. That replaced
`StateStore.endFullPass`'s untouched-key sweep, which was only safe after a
*full* pass and so let state of departed views live on until the next
resize.

`_ModifierView` carries a `key` — `["padding", insets]`, name first because
two modifiers over the same content are the same type — so
`Text("x").padding().background(…)` chains compare too. A modifier holding a
closure (`.onTapGesture`, `.gesture`) has no key and always rebuilds; its
*content* is still compared at its own level.

### NavigationStack keeps covered screens

Releasing departed views promptly exposed that `NavigationStack` built only
the top screen (§8), so the root left the tree on every push and its state
was gone on the way back — the counter reset, faders reset. That had been
hidden by the old sweep. Fixed the way SwiftUI does it: every screen stays in
the tree, and the covered ones are `._parked(true)` — zero size, never
placed, skipped by hit testing (the frames they carry are from when they were
last visible), their shader slots released. `@State` and scroll offsets are
still there on Back.

### Numbers

Debug build, same demo as §6:

```
                     before                     after
+ press              scoped(1)  1.3ms built=8   scoped(1)  1.1ms built=4  reused=1
fader drag           fallback   5.1ms built=209 scoped(3)  3.2ms built=29 reused=21
scroll wheel         (subtree rebuilt)          scoped(1)  1.1ms built=3  reused=7
window resize        full      ~10ms built=209  full       1.9ms built=1  reused=2
first build          full      10.2ms built=209 full      13.7ms built=234
```

The fader drag no longer rebuilds the tree from the root; the 29 nodes it
does build are the owner's body, the button row (closures), and the one row
whose binding chain the write reached. A resize re-lays-out everything and
rebuilds nothing. The first build pays ~30% more for the bookkeeping (an
entry with two closures per view); that is the trade.

### Honest limits

* Views holding closures — `Button`, `NavigationLink`, `ForEach`, `AnyView`
  — never compare equal, so a parent that re-runs always rebuilds *them*;
  their children still compare at their own level. `ForEach` rebuilding its
  own node while reusing every row is the common case and is cheap.
* `_viewID` is the call site only through the generated init. A view with
  its own init — every `@ViewBuilder`-taking one — gets the declaration site
  unless it takes and assigns `_viewID` itself.
* The generated init follows memberwise rules as far as syntax allows; a
  property without a type annotation is not a parameter.
* A covered navigation screen is built (cheaply, mostly reused) on every
  stack rebuild, and its shader pipelines are recompiled on the way back.

## 17. `@View` as the foundation, not an add-on

Pushback on §16: the sketch wanted the macro to be the general mechanism, and
the core was still written against plain `View` with reflection, with
`IdentifiedView` bolted on through `as?` casts. Reworked so the three
generated members are requirements of `View` itself:

```swift
protocol View: ViewInput {
    var body: Body { get }
    var _viewID: ViewID { get set }                    // @View: stored
    func _bindDynamicProperties(_: DynamicPropertyBinder) // @View: static list
    func _isEquivalent(to: Self) -> Bool               // @View: field-by-field
}
```

A plain `struct S: View` gets protocol-extension defaults that do the same
job through reflection; `@View` generates cheap witnesses. The builder calls
the requirements directly — no casts, no fast/slow branches, and the last
`Mirror` on the build path for a `@View` view is gone.

Two things the macro can do that nothing at runtime could:

* **The call site, for every view expression.** Not from the init — a
  hand-written init has no location parameter and a macro cannot add one to
  it — but from `ViewBuilder.buildExpression`, whose implicit call sits on
  the expression, so its `#line` default *is* the line the view was written
  on. Measured with a probe: it works, and a modifier chain forwards the
  stamp inward, so `Row().padding()` identifies `Row`. Both `buildExpression`
  overloads take the location so neither is preferred for using fewer
  defaults. `_viewID` is settable for this reason.
* **A warning at the declaration** for a stored closure: two values holding
  one are never equivalent, so the view is rebuilt whenever its parent is.
  That used to be discoverable only from the `=2` perf trace.

Deviation accepted knowingly: SwiftUI has no `_viewID` and identifies by
type and position only. Here a `flag ? Row("a") : Row("b")` at one position
is two views.

### Last reflection off the build path

`StateKey.viewType` was a `String(reflecting: V.self)` — a slow call, cached
per type, and only ever *compared*. It is now `ObjectIdentifier(V.self)`:
distinct generic instantiations are distinct metatypes, so it tells exactly
the same views apart, for every view rather than only `@View` ones, and the
macro turned out not to be needed for this one. The `onAppear` key, which
borrowed the field for a string tag, uses a private marker type instead.
With that, a build of a `@View` tree does no reflection at all: identity,
binding and comparison are all compile-time products.

### Hit testing ignored clipping — exposed by scroll offsets that survive

Reported as "Back loops between the shader and the gallery". Reproduced
only with the gallery *scrolled* before opening a shader: after Back, the
second Back hit a gallery row at `y = -53` — scrolled up under the
navigation bar — and pushed the shader again. Hit testing walked every
child by its placed frame and never asked whether a `ScrollView` or
`.clipped()` had cut it off; screens are tested before the bar (last drawn,
first hit), so the hidden row won.

The bug is old. It was masked because a push used to throw the gallery away
and a pop rebuilt it at offset 0; §17's parked screens keep the offset, and
so keep the row under the bar. `NodeContent.clipsChildren` (true for
`ScrollContent` and `ClipContent`) now stops the walk at a clipping node's
frame. Verified with the scrolled flow at both stack depths, and on the
main screen with the mixer scrolled beneath its buttons.

Lesson for the test script: one push and one pop is not a navigation test.
Scroll first, go two deep, come all the way back.

### Resizing a shader view freed its image mid-frame

Reported as a crash on maximizing the window with a shader on screen and
pressing Back. The crash report put it in MoltenVK's draw encoding during
`vkQueueSubmit`, and it happened on the resize itself, before Back:
`ShaderSlotRegistry.use` saw the view's pixel size change and called
`destroy(existing)` right there — the image and pipeline freed while the
frames in flight still referenced them, and the old container left in
`engine.nodes` for the composite pass to sample from freed memory. The
teardown path had been made safe in §8 (detach now, free at the top of the
next frame, behind a drain); the resize path was the same bug, never
touched.

Both now go through one `retire(_:)`. The new slot inherits the old one's
clock, so the animation carries on across a resize instead of restarting.
Verified: shader on screen → maximize → shrink → maximize → Back → Back; the
gallery (eight live slots) resized three times, a row opened, resized,
Back → Back. No crash report.

## 18. Building from GitHub, not just from the siblings

`Package.swift` now decides where the three Nucleant packages come from:
`NUCLEANT_LOCAL_DEV=1|0` in the environment if set, otherwise *local when the
sibling checkout exists next to this package* — true in this development
tree, false in a clone SwiftPM makes under `.build/checkouts`. The upstream
packages (NucleantVulkan, NucleantThorVG, NucleantApplication) make the same
decision the same way, which is what makes the chain resolvable from git at
all: a package fetched by revision may not have path dependencies, and each
of them had its switch hardcoded to local on master.

Found on the way: SulphurGeometry's default branch is `main`, not the
`master` NucleantVulkan asked for; and the `android` → `master` merge of
NucleantApplication had duplicated the `env` block in its manifest, so master
did not evaluate. Both fixed on master.

Verified with `.build` and `Package.resolved` deleted and
`NUCLEANT_LOCAL_DEV=0 swift build`: the chain resolves to `master` of all
three (plus SulphurGeometry `main`), the framework binaries come along in
the clones, and the demo runs through the full interaction set. The tree is
back on local mode afterwards — a plain `swift build` here uses the siblings.

## 19. A view as a shader's texture input — `.shader(_:)`

`view-as-shader-input.md`: PyNucleantUI let a `CanvasShader` post-process
any `CanvasBase`, because every canvas rendered into its own VkImage. The
same should hold here, on top of the generative `Shader` view.

### Shape

SwiftUI's `layerEffect`, on the engine's terms:

```swift
panel.shader(ShaderLibrary.crt)          // the panel, through a CRT
card.shader(fx, isEnabled: on)           // toggled without losing what is under it
```

Two engine nodes per effect, in the order the engine updates them:

1. **A ThorVG canvas of the view's size** (`makeThorWidgetNode`, the exact
   path PyNucleantUI's canvases took), which the view's subtree is drawn
   into. `ShaderEffectContent.place` gives its child a display list of its
   own instead of the window's — the child's frames are still written, so
   hit testing does not know the difference. The canvas node sits in
   `engine.nodes` so the engine draws it, but `compositesToWindow = false`
   keeps its image off the swapchain (`getImageView()` answers nil) and its
   size off the window's on a resize.
2. **The `OGLShaderNode` that was already there**, with the canvas registered
   as a texture input — `register(image:imageView:)` was written for exactly
   this and had no caller — and `ShaderPipeline` grown a binding 2 sampler.
   Its output composites where the view is.

Two images rather than PyNucleantUI's in-place pass (sampler and storage on
one image): a blur or a ripple reads neighbours that other invocations are
writing, which in place is a race, and it also drops the requirement that
the canvas image be storage-capable.

### The canvas is stored y-up

Shader space here is y-up, ShaderToy's convention. A texture sampled with
those coordinates would come out mirrored — unless the canvas *is* y-up. So
a layer's paints go into a root `tvg_scene` carrying one matrix: translate
the view's origin to the corner, `y' = height - y`. A scene rather than a
per-paint matrix because ThorVG applies a paint's own transform to that
paint alone, not to its clipper, while a parent scene's reaches both. With
that, `layer(uv)` is the pixel under the current one, `texelFetch` rows
match, and an unmodified ShaderToy post-process that reads
`texture(iChannel0, uv)` (`#define`d to the sampler) shows the view upright.
Text drawn flipped looks fine — glyphs are paths.

Verified with the `identity` effect (`fragColor = layer(uv)`) against the
same panel drawn directly: geometrically exact; the only differing pixels
are anti-aliased edges (≤ 64/255), from straight-alpha edge texels being
blended a second time at the composite, and from glyph edges rasterizing at
mirrored subpixel offsets.

### What it cost, and the canvas pool

First run: opening the effects gallery took **550ms** — eight rows, ~65ms
each, of which 60ms was `tvg_wgcanvas_set_target` on a fresh canvas (ThorVG's
wg renderer compiles its pipelines the first time it gets a target; the
wgpu texture and the VkImage import are 0.1ms). Retargeting an *existing*
canvas (`resizeThorNode`, the window's own resize path) is under 1ms.

So canvases are pooled: a retired effect's canvas is kept (up to eight),
and the next effect to appear takes one and retargets it — on a resize the
outgoing slot hands its canvas straight to its replacement. Second opening
of the gallery: **22ms**, ~1ms a slot. Memory over eighteen in/out cycles
creeps the same ~50KB a cycle the generative gallery does (driver caches),
nothing more.

Two more things the first screenshots showed:

* **Static effects are dispatched once.** `ShaderFunction.isAnimated` is a
  scan of the source for `time`/`iTime`/`iFrame`/`mouse`/`iMouse`; a slot
  whose source has none is not re-armed by `tick`, only by its layer being
  redrawn. Applies to generative `Shader` views too — a shader that draws
  the same thing every frame now draws it once.
* **Composite rects are snapped to whole pixels at the image's size.** A
  layer at `y = 153.93` was being bilinearly resampled — every edge in the
  identity comparison was soft. The canvas draws from the snapped origin,
  so nothing moves; it just lands on texels.

Also changed: the pointer uniform is now relative to the slot's own rect for
both kinds of slot — it was window-relative, flipped against the slot's
height, which was wrong for anything smaller than the window.

The thor node's post-draw barrier (NucleantThorVG) now names the compute
stage alongside the fragment stage as the image's reader; before, only the
composite's fragment shader was a formal consumer.

### Verified

Effects gallery (eight live layers over one card): correct on first and
pooled openings; scrolled under the navigation bar, cut at the scissor. The
mixer under Wave: fader dragged, `+` pressed — the counter and the level
change under the distortion and the wave keeps moving; Effect off shows the
plain panel with that state kept, Effect on brings the effect back. Under
CRT (static): a drag redraws. Window resized 1000×700 → 800×600 → 1100×750 →
900×648, then 1900×1000 → 700×500 → 1900×1000 with the effect on, then Back,
Back. No crash report. `NUCLEANT_SWIFTUI_TRACE_PERF=1` gained `layers=N`
(canvases redrawn this pass) and `=2` reports each slot build with its
canvas cost.

### Limits

An effect composites as a rectangle over the canvas, so clipping belongs
*inside* it (`.cornerRadius(10).shader(fx)`); a `Shader` view or another
`.shader` inside an effect is a slot of its own, composited over the
effect's output rather than through it; a moved layer is redrawn (the
comparison is in absolute coordinates); and the canvas is the view's full
size, so an effect over a 5000pt scroll content is a 5000px texture.

## 20. Six example apps, and what building them turned up

`Examples/` has six standalone packages — Calculator, Tasks, Sketch,
Dashboard, TwentyFortyEight, Pomodoro — each a different shape of app on
the same library. Writing apps that were *not* the demo was the point: the
demo was built alongside the framework and had learned to avoid its
corners. Each of the following was found by an example failing to build
or drawing wrong, and verified by driving the example with real input and
reading the screenshot.

### `@View` and a stored closure

The generated memberwise init spelled a closure property's parameter as
`action: () -> Void` — non-escaping, so `self.action = action` did not
compile. The macro now adds `@escaping` to a function-typed parameter
(an optional closure is already escaping and is left alone). The
"stored closure — this view always rebuilds" warning stays; it is about
comparison, not about compiling.

### `@View` and a `let` in `body`

`var body: some View { let x = …; Text("\(x)") }` failed with "no return
statements" in a `@View` struct and compiled in a plain `struct: View`.
The compiler infers `@ViewBuilder` on a witness from the protocol
requirement, but not when the conformance is added by the macro's own
extension and the body has statements. The member-attribute role now puts
`@ViewBuilder` on `body` explicitly.

### A fitted label wrapped when drawn

"Delete task" measured as one line, was laid out as one line, and ThorVG
drew it as two: its layout of the string came out a fraction wider than
the summed advances and the box was an exact fit. The same slack that
decides ellipsis (`isTruncated`) now decides wrapping — `TextDraw.wraps`
is false when layout found the string fits one line, and the renderer
draws it with `TVG_TEXT_WRAP_NONE`.

### Stack sizing, three times

The examples are full of rows the demo did not have — a row of eight
fixed swatches, a title next to two buttons, a status line beside score
boxes — and each of those exposed a way the stack's "least flexible first,
equal share of what is left" rule fell short of what it was meant to do.

*A wrapped node lost its flexibility.* `flexibility(along:)` was answered
by the node's content alone, so every modifier and every stack said
`.content` — a padded circle in a fixed frame, or an `HStack` of eight of
them, looked as squeezable as a `Text` and was offered an eighth of the
row. It now takes the node: a wrapper answers for what it wraps, a stack
with its most flexible child, and a `.frame` only overrides on the axis it
actually constrains. With that, a `Spacer` had to stop claiming to be
flexible across its stack's axis (it has no extent there), or a button row
became vertically flexible and the mixer's scroll view shrank to two rows.
And a run of fixed children now reports its true extent instead of the
clamped offer, the way a fixed `.frame` does — otherwise the swatch row was
still cut to its share and spilled over the brush picker.

*A share was split with the spacer.* The equal share divided what was left
by *all* unplaced children, so `HStack { Text; Spacer(); fixed; fixed }`
offered the text half of the remaining width and the spacer the other
half — the 2048 status line wrapped to four words a line. The divisor is
now the number of children still to size in the *current* group; more
flexible groups only ever get what is left, which is what a `Spacer` is
for.

*Everything fit, and something wrapped anyway.* `Hide mixer` in the demo's
own button row wrapped to two lines with 200pt to spare, because it came
first and was offered a seventh of the row before the others took their
smaller ideals. SwiftUI orders children by measured flexibility; this is
narrower but covers the case: the content group is measured at its ideal
(the axis proposed infinite) and, when the ideals add up to no more than
what is left, each child is offered exactly its ideal. When they don't
fit — or a child's ideal is unbounded, a colour, a shape — the equal share
decides who shrinks, as before.

Checked against the demo before and after: the mixer, the button row (now
one line), the shader and effects galleries, an effect screen two levels
deep, Back, Back — all as before or better, with the layout trace and
screenshots. The rule that survives unchanged is that `.relativeSize` is
a fraction of what the *stack offers*, not of the row: the examples say
so where it bit (a 62% card is 62% of half a row) and use a `ZStack` or a
fixed sibling instead.

## 21. `@Observable` models, shader arguments, and a starved main queue

The Sampler example (`Examples/Sampler`) is SamplerUI's shape on this
stack: an `@Observable` model per pad, a min/max envelope reduced with
vDSP off the main thread, a shader that rasterizes it from two float
arrays, faders bound straight into the model. Three things had to exist
first.

### Observation

`@State` is tracked by the framework's own reader registration;
`@Observable` properties are tracked by the standard library's
`withObservationTracking`. `buildNode` now evaluates a composed view's
`body` inside one, and `ForEach` evaluates each row closure inside one,
with the change handler dirtying that view's path through
`Invalidator.invalidateFromAnyThread` (immediate on the main thread, a
main-queue hop otherwise).

Scopes never nest. A scope wraps the *construction* of a view value —
`view.body`, `build(element)` — and never the building of the node it
returns, because Observation merges a nested scope's accesses into its
parent's: wrapping the whole build would attribute every descendant's
reads to the root and turn each change into a full rebuild. Custom
`ViewModifier`s need nothing extra — `ModifiedContent` is a composed view
whose body calls `modifier.body(content:)`.

A class reference is now an *equivalent* input when it is the same object
(`_dynamicallyEquivalent` compares by identity; `Bindable` likewise). It
used to be refused ("a class can mutate underneath"), which is exactly the
case observation now covers: what a view reads from the object is tracked,
so the reference itself need not look different for the view to rebuild.
`@Bindable` is SwiftUI's — `$model.gain` is a `Binding` through a
`ReferenceWritableKeyPath`, and a write through it is a write to the
object, seen by every reader.

### Shader arguments

`ShaderArgument` is SwiftUI's `Shader.Argument` with names: `.float`,
`.float2/3/4`, `.color`, `.floatArray`. They are packed into one storage
buffer (binding 3, `std430 float[]`) with a header of (offset, count) per
argument, and the wrapper generates a variable per scalar, and `name(i)`
plus `nameCount` per array — a GLSL buffer cannot be aliased as an array
variable, so an accessor it is, clamped to the array's ends. The
declarations depend only on names and kinds (the *signature*), never on
values or lengths, so a changing array never recompiles; the buffer is
sized with headroom and the slot rebuilds only when a list outgrows it.
The registry re-uploads when the packed values differ from the last
upload and re-arms the node, which is how a static shader — one that
reads no clock — redraws for a new envelope, a moved playhead or a
changed gain.

### The main dispatch queue was starved

The first version of the example redrew on a drag but not when a
background analysis finished. Not Observation's fault — the change
handler fired whenever the write happened, and the write never happened:
the `MainActor.run` (and, tried next, the `DispatchQueue.main.async`) that
was to carry the result back sometimes never ran, while a
`RunLoop.main.perform` always did. The `CADisplayLink` callback drew the
frame in place, and a frame blocks the main thread for most of a display
period waiting on vsync; a run loop whose display-link source is always
ready and always slow does not get round to the main dispatch queue's
port. Every `Task { @MainActor in … }` in any app on this stack was
affected; the Pomodoro example only worked because a `Timer` is a
run-loop source.

`HostingWindow.onFrame` now queues one frame on the main dispatch queue
(dropping ticks while one is pending) rather than drawing inside the
callback. The display-link handler is then cheap, the loop always drains
the queue, and the frame takes its FIFO turn with every other main-actor
block. Verified with the example's Resample button — a detached task
synthesising, `MainActor.run` storing, a GCD `concurrentPerform`
reduction, `DispatchQueue.main.async` storing — 0 of 18 launches missing
a redraw after the change, 8 of 12 before it. One more thing learned on
the way: a `concurrentPerform` inside a detached task, which blocks a
cooperative-pool thread, was seen to never start at all under the same
starvation; the reduction runs on a GCD global queue, as SamplerUI's does.

## 22. Light and dark

Everything was written dark because nothing knew otherwise: `Color.primary`
was a fixed near-white, and the window never asked the system. Now the
window seeds `EnvironmentValues.colorScheme` from
`NSApp.effectiveAppearance` and observes it (KVO) for the life of the
window; a change rewrites the environment, paints the engine's clear
color to the scheme's `Color.background`, and invalidates the tree.
`AppRuntimeSettings.colorScheme` forces one for every window; iOS is
seeded once from the trait collection and not yet tracked.

A color can carry a second, dark set of components (`Color.dynamic`), and
the semantic colors — `.primary`, `.secondary`, `.tertiary`,
`.background`, `.secondaryBackground`, `.tertiaryBackground`,
`.separator`, `.fill` — do. Resolution happens where a color is drawn:
`DrawContext` carries the scheme, `resolve` picks the variant before
applying opacity (gradient stops too), and `EnvironmentContent` — the
node behind every `.environment` modifier — sets it on the way down, so
`.colorScheme(_:)` on a subtree is honoured by leaves that never read the
environment themselves. The root context takes the host's value. A
`.color` shader argument is resolved when the argument list is packed,
under the environment the view was built with, so the Sampler's shader
paper follows too.

Why draw time and not build time: the alternative — every leaf reading
`\.colorScheme` at build and baking the variant in — would have touched
every leaf and every gradient, and a `.shader` layer's canvas is drawn
from the same display list, so the same `resolve` covers it for free.

The demo got a System / Light / Dark control in its header (the root
reads `@Environment(\.colorScheme)` for "System" and applies
`.colorScheme` below itself), and every example's `Theme` became
semantic or `dynamic`. Verified by flipping System Settings between the
two with the demo on "System" (both repaints), by the demo's own control
on the mixer and an effect screen, and by a light-mode pass over all
seven examples.

## 23. iOS, through an Xcode project

The package declared `.iOS(.v17)` from the start and `HostingWindow` had
an `#if os(iOS)` branch, but nothing had ever compiled it — the first
iOS Simulator build failed on `ActiveScene`, which lives in
`NucleantApplication` and was never imported. The launch path was a
placeholder too: `AppRuntime.run()` on iOS called `onStart()` and
returned, so `@main` would have presented onto no `UIApplication` and
then exited.

`run()` now hands the process to `UIApplicationMain`. Two things shaped
the delegate:

* `UIApplicationMain` instantiates the delegate *by class name*, and
  `AppRuntime<A>` is generic — a generic Swift class has no ObjC name to
  give it. So `_AppLaunchDelegate` is a plain class reached through a
  static closure the runtime sets before the hand-off, the same shape
  NucleantAppTest's launcher uses.
* A window has to come from the connected `UIWindowScene`
  (`UIWindow(windowScene:)`) or it never follows Stage Manager resizing,
  and no scene exists yet in `didFinishLaunching`. The delegate answers
  UIKit's `configurationForConnecting` with `_AppSceneDelegate`, which
  stores the scene in `ActiveScene.current` and only then presents. The
  configuration is built in code rather than named in Info.plist so the
  app's plist never has to spell `NucleantSwiftUI._AppSceneDelegate`. An
  app without a scene manifest still works — UIKit then never asks, and
  `didFinishLaunching` presents onto a screen-sized frame.

The project itself is xcodegen over the demo's existing source
([XcodeExamples/](XcodeExamples)), one target with iOS and macOS
destinations, depending on the checkout as a local package. Two things
were not obvious: the package's own `NucleantSwiftUIDemo` executable gets
an auto-created scheme with the same name as the app, so the app target
is `NucleantSwiftUIDemoApp` and auto-creation is turned off in the
workspace settings; and Xcode's "requires a development team" check for
the macOS build reads the *unconditioned* `CODE_SIGN_IDENTITY` on the
target, where xcodegen's application preset puts `"iPhone Developer"` —
so the target signs to run locally by default and names `Apple
Development` only for `[sdk=iphoneos*]`.

Verified first on an iPhone 17 simulator (MoltenVK picks the simulator
GPU, the full mixer renders) and as a macOS `.app` from the same project.

### What the real GPU said

The simulator proved nothing about the device: on an M1 iPad Pro the same
build came up black. The frame loop was fine — acquire and present
returned success every frame, one node was composited — and a debug
readback of the wgpu `MTLTexture` after ThorVG's sync showed real pixels,
so the drawing side was fine too. The only line differing between the
logs was MoltenVK's `Descriptor sets binding resources using Metal3
argument buffers` (the Intel Mac and the simulator say `Metal argument
buffers`). Relaunching with `MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0`
brought the picture up: through Metal 3 argument buffers the sampled
image *imported* from an external `MTLTexture` is never made resident
for the composite's fragment shader and reads as zero. The engine now
turns argument buffers off per instance through `VK_EXT_layer_settings`
— its descriptor sets are a handful of textures, so nothing is lost.

Then no text: `FontRegistry` searched macOS directories for
`Family Bold.ttf`. A probe of the device's `/System/Library/Fonts` showed
iOS keeps fonts in `Core/`, `CoreUI/`, `WebFonts/`, `AppFonts/` under names
without spaces, with Helvetica Neue and Menlo only as `.ttc` collections
ThorVG cannot parse. Rather than a second table of guesses, the default
and monospaced faces are now bundled (Roboto, Roboto Mono — Apache 2.0 /
OFL, in `Resources/Fonts`, reached through `Bundle.module` on every
platform), and anything else is asked of CoreText by family and traits,
which returns the file on both OSes.

Then no scrolling: `ScrollView` only had `onScroll`, fed by the wheel.
`ViewHost` gained `scrollsOnDrag` — the iOS host sets it — under which a
finger that moves more than 10 pt scrolls the innermost `ScrollView` it
landed in. Priority follows UIKit: a target with drag handlers (a fader)
keeps the finger; a press-only target (a button) gets `onRelease(inside:
false)` and no tap once the scroll begins.

Still open from the device run, in
[XcodeExamples/plan.md](XcodeExamples/plan.md): the desktop layout is
cramped on a phone, the navigation bar ignores the safe area, no scroll
momentum, appearance seeded once.

## 24. Drag and drop, through `Transferable`

The plan was three lines: the `Transferable` protocol with a real
`CodableRepresentation`, `.draggable`, `.dropDestination`. The surface
came out as SwiftUI's; what took the time was the compiler and the
routing.

### Declaring `Transferable` so `some TransferRepresentation` works

The obvious declaration —

```swift
associatedtype Representation: TransferRepresentation where Representation.Item == Self
```

— makes every conforming type fail with "does not conform" as soon as its
witness is written `static var transferRepresentation: some TransferRepresentation`.
Checking the same-type requirement needs the opaque type's underlying
type, which needs the body type-checked, which needs the conformance
being checked. Reduced to five lines it fails the same way; giving the
opaque type its primary associated type (`some TransferRepresentation<Self>`)
passes, but that is not how anyone writes it. CoreTransferable's own
interface has the answer: no same-type requirement on the associated
type at all. The builder pins `Item` to `Self` instead, and `_exporters`
casts once at runtime with a precondition for the witness that was
written with a foreign type by hand.

The second surprise was inference. `CodableRepresentation(contentType: .json)`
names no item type; SwiftUI gets it from context. A `buildBlock<R>(_:) -> R
where R.Item == Item` does *not* provide that context — the solver will
not bind a struct's generic parameter through an associated-type equality
on a block argument — but `buildExpression` with the same signature does,
and that is again what CoreTransferable's interface declares. With it,
`CodableRepresentation`, a `DataRepresentation` whose closures mention
`$0`, and `ProxyRepresentation(exporting: \.name)` all infer.

Two smaller ones: Foundation on Apple platforms re-exports
CoreTransferable, so `String`, `Data` and `URL` already have a
`Representation` (CoreTransferable's), and the conformances here name
theirs with an explicit typealias or the witness is matched to the wrong
one. And a same-element requirement on a parameter pack
(`repeat (each R).Item == Item`) is rejected by the 6.3 compiler outright,
so the builder has fixed arities, as CoreTransferable's does.

`UTType` is a struct of the framework's own rather than
UniformTypeIdentifiers' — the identifiers and the conformance tree are
Apple's public ones, but nothing here should need a system framework to
name `.json`. Likewise `TransferEncoder` / `TransferDecoder` stand in for
Combine's `TopLevelEncoder` / `TopLevelDecoder`, which do not exist off
Apple platforms.

### Routing

A `.draggable` is not a `HitTarget`. The pointer target under a press is
found as before; the innermost drag source is found by a second walk of
the same hit test (now generic over what it selects — `hitTest(_:select:)`
answers for pointer targets, drag sources and drop targets alike). The
press then proceeds as a press: a button under it highlights, a tap
still lands. Only once the pointer has moved four points does the drag
begin, and the button is released without its tap, exactly as the
scroll-slop path already did for a finger that turned out to be
scrolling. A gesture that takes drags itself (a fader) is never
pre-empted — a fader on a draggable card keeps its own drag.

On a touch host the same rule would make a list of draggable rows
unscrollable, so there a draggable inside a scroll view starts from a
press held still for half a second (`pressSerial` tells the timer whether
its press is still the one in flight); moving before that scrolls.

The destination under the pointer is re-found on every move. Comparing
`DropTarget` objects was a loop: `isTargeted(true)` writes state, the
destination rebuilds, the rebuilt node carries a new object, the next
move sees a "new" target and tells it `true` again. Targets are compared
by structural path — the identity that survives a rebuild — and the
object is refreshed from each hit so the closures called are the current
ones.

The preview is the dragged node placed a second time into a display list
nobody renders, under the context it was last placed with but unclipped,
so a card half under the edge of its scroll view is dragged whole. Each
frame those commands are translated by the pointer's travel and drawn
after the tree at 80% opacity. A transformed command is moved by
conjugating its transform with the translation rather than shifting its
path — a rotated card must not be re-rotated about the old anchor. A
custom preview is a tree of its own (own `StateStore`, own records, path
prefix `[-1]` so a shader in it cannot claim a slot the tree owns),
measured once and centred on the pointer. Neither preview is in the
node tree, so the destination is found *through* it.

Moving the pointer during a drag sets `needsRepaint` — placement and
paint, nothing rebuilt: ~1ms a move in the demo, with a `scoped(1)`
rebuild only when a destination is entered or left.

The transfer itself is in-process but goes through the bytes: the payload
is encoded once per content type a destination asks for, and decoded on
the drop, so a representation that would not survive a pasteboard does
not survive this either. A destination for `T` matches when some export
of the payload *conforms to* something `T` imports, so `.text` takes a
`.json` export and a track's `ProxyRepresentation(exporting: \.name)`
lets a plain-text notes box take a track.

Verified by driving the demo's "Drag & drop" screen: a track dragged
onto a bus highlights the bus on entry, clears it on the drop, and lands
as JSON; a track dragged onto the notes box lands as its name; the
label with a custom preview lands as text with its drop point reported
in the box's own coordinates; a click and a 3pt wobble on a chip start
no drag.

## 25. Context menus

`.contextMenu(menuItems:)` needed three things the framework did not have:
a right click, something drawn *over* the tree that also takes input, and
a `Button` that looks like a menu row.

The right click was a stub — `on_right_mouse_down` in `HostingWindow` was
empty, although the macOS platform layer had delivered it all along. It
now goes to `ViewHost.secondaryClick`, which walks the same hit test as
everything else (`hitTest(_:select:)`, selecting `contextMenuSource`) for
the innermost node with a menu. A touch host has no right button, so
there the hold timer added for drag and drop does double duty: a press
held still on a node with a menu opens it, and a menu wins over a
draggable when a node has both, as UIKit does.

The overlay is the interesting part. The drag preview is painted after
the tree and never hit tested, which is right for a preview and wrong for
a menu — its rows are buttons with `@State`, and a press outside must
close it. Rather than a second tree with its own store and records (and a
second set of the rebuild machinery to keep it live), the host's root is
now `_HostRoot`: the app's root in slot `[0]`, whatever the host is
presenting in slot `[1]`. Opening or closing a menu is then an ordinary
full rebuild in which the app's subtree is compared and kept, and the
menu is just views — a `ZStack` of a scrim and an anchored panel — under
the same store, the same scoped rebuilds and the same hit testing as the
rest. Its rows highlight through the same `isPressed` path as any button.
The app's root moving from `[]` to `[0]` also means it has a parent to
splice into, so a state write on the root view itself can now be a
scoped rebuild rather than the fallback it used to be.

The scrim is a `Color.clear` with a hit target whose `onPress` closes the
menu. That is all it takes for "a press outside closes it and goes no
further": the press lands on the scrim, the scrim goes away on the next
frame, and the release finds nothing in flight.

`Button` reads `\.contextMenu` from the environment, which the overlay
sets for its subtree, and draws as a row when it finds one: full width,
tinted while pressed, running its action and then `dismiss()`. That is
also the one extension point for other item views — a custom row reads
the same value.

Positioning is `_anchored(at:)`, a node that fills what it is offered
and places its child at the child's own size with the top-left corner
at the anchor, pulled back inside the rect when it would overflow. The
child is proposed the size it measured, so a row's `maxWidth: .infinity`
stretches to the panel and not to its own label.

Verified in the demo: a right click on a mixer row opens the presets at
the pointer (a `full` rebuild of 3.7ms, the mixer reused), "Half" sets
the row to 50% and closes the menu, a click outside closes it without
reaching the row under it, and a right click on the bottom-right row
opens the menu pulled inside the window.
