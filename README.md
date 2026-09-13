# NucleantSwiftUI

SwiftUI-shaped declarative views, drawn by [ThorVG](https://github.com/NucleantUI/NucleantThorVG)
on [Vulkan](https://github.com/NucleantUI/NucleantVulkan) and hosted by
[NucleantApplication](https://github.com/NucleantUI/NucleantApplication).
Pure Swift, no AppKit/UIKit view hierarchy, runs the same code on macOS and
iOS. If you know SwiftUI, you already know most of the surface.

```swift
import NucleantSwiftUI

@View
struct Counter {
    @State private var count = 0

    var body: some View {
        HStack(spacing: 16) {
            Button("−") { count -= 1 }
            Text("\(count)").font(.title)
            Button("+") { count += 1 }
        }
    }
}

@main
struct DemoApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Counter", width: 400, height: 200) {
            Counter()
        }
    }
}
```

## Adding it

```swift
.package(url: "https://github.com/NucleantUI/NucleantSwiftUI.git", branch: "master")
```

and `import NucleantSwiftUI`. `swift build` at this package's root builds the
library and the demo (`.build/debug/NucleantSwiftUIDemo`), which is a
runnable tour of everything below. The Nucleant packages this depends on are
resolved from GitHub automatically; when they are checked out as siblings
of this directory they are used from there instead (`NUCLEANT_LOCAL_DEV=0|1`
overrides).

## Declaring a view: `@View`

Write a struct with a `body` and put `@View` on it. The macro adds the
`View` conformance and — this is the part that matters — generates what the
framework needs to *not* rebuild it: an identity for the place it was
written, a static list of its `@State`/`@Binding`/`@Environment`
properties, and a comparison over its inputs.

```swift
@View
struct TrackRow {
    let name: String
    let color: Color
    @Binding var level: Double

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(name).frame(width: 70, alignment: .leading)
            fader
            Text("\(Int(level * 100))%").foregroundColor(.secondary)
        }
        .padding(horizontal: 16, vertical: 10)
        .background(Color(hex: 0x272B34))
        .cornerRadius(10)
    }

    var fader: some View { … }
}
```

When you write no `init`, one is generated (`TrackRow(name:color:level:)`).
`struct TrackRow: View` without the macro works too — the framework then
falls back to reflection for the same information, which is slower.

If a `@View` struct stores a closure, the macro warns: two values holding a
closure can never be told apart, so that view is rebuilt whenever its parent
is. Prefer a `Binding` or a value.

## State

The wrappers are SwiftUI's:

```swift
@View
struct Mixer {
    @State private var tracks = defaultTracks
    @State private var showDetails = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button(showDetails ? "Hide" : "Show") { showDetails.toggle() }
            Button("Reset") { tracks = defaultTracks }

            if showDetails {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach(tracks.indices, id: \.self) { index in
                            TrackRow(
                                name: tracks[index].name,
                                color: tracks[index].color,
                                level: $tracks[index].level
                            )
                        }
                    }
                }
            } else {
                Text("Mixer hidden")
            }
        }
    }
}
```

* `@State` lives across rebuilds, keyed by the view's position in the tree.
* `$tracks[index].level` is a `Binding`; `Binding` supports key-path
  projection (`$model.name`) and `.constant(_:)`.
* A write invalidates the view that owns the state **and every view that
  read it**, at key-path granularity: dragging one row's fader rebuilds that
  row, not the other six.
* `@Environment(\.font)`, `@Environment(\.foregroundColor)`, `\.tint`,
  `\.isEnabled`, `\.lineLimit`, `\.multilineTextAlignment`,
  `\.displayScale`; set with `.environment(\.key, value)` or the sugar
  (`.font`, `.foregroundColor`, `.tint`, `.disabled`, `.lineLimit`).

## Layout and views

`VStack`, `HStack`, `ZStack` (with `alignment`/`spacing`), `Spacer`,
`Divider`, `Group`, `ForEach` (with `id:` or `Identifiable` data), `if` /
`if let` / `switch` in builders, `AnyView`, `EmptyView`.

`Text` with `.font`, `.bold`, `.italic`, `.fontWeight`,
`.foregroundColor`, `.lineLimit`, `.multilineTextAlignment` — set on the
`Text` or inherited from the environment. Fonts: `.system(size:weight:design:)`,
`.custom(_:size:)`, the standard styles (`.title`, `.body`, `.footnote`, …).

Shapes: `Rectangle`, `RoundedRectangle`, `Circle`, `Ellipse`, `Capsule`,
`PathShape { size in … }`, with `.fill(_:)` / `.stroke(_:lineWidth:)` taking a
`Color` or a `ShapeStyle` (`.color`, `.linearGradient(colors:startPoint:endPoint:)`).
`Color` is itself a view.

```swift
ZStack(alignment: .leading) {
    Capsule().fill(Color(white: 1, opacity: 0.08)).frame(height: 8)
    Capsule()
        .fill(.linearGradient(colors: [color.opacity(0.6), color],
                              startPoint: .leading, endPoint: .trailing))
        .relativeSize(width: level)      // a fraction of what the parent offers
        .frame(height: 8)
}
.frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
```

Modifiers: `.frame(width:height:alignment:)`,
`.frame(minWidth:maxWidth:minHeight:maxHeight:)`, `.padding(...)`,
`.relativeSize(width:height:)`, `.background(_:)`, `.overlay(_:)`,
`.border(_:width:)`, `.opacity`, `.offset`, `.rotationEffect`, `.scaleEffect`,
`.clipped`, `.cornerRadius`, `.clipShape`, `.hidden`, `.onAppear`. Custom
modifiers via `ViewModifier` + `.modifier(_:)`.

## Input

```swift
Button("Reset") { reset() }                     // fires on release inside
Button(action: reset) { Label() }

Text("tap me").onTapGesture { … }
Text("tap me").onTapGesture { point in … }      // point in the view's space

someView.gesture(
    DragGesture()
        .onChanged { value in
            // value.location, .startLocation, .translation,
            // and .bounds — the view's own rect, so a position
            // can become a fraction without a GeometryReader
            level = min(1, max(0, value.location.x / value.bounds.width))
        }
        .onEnded { value in … }
)
```

`ScrollView(.vertical) { … }` / `.horizontal` / `[.horizontal, .vertical]`
takes the wheel and trackpad, clips its content, and keeps its offset across
rebuilds and navigation.

## Navigation

```swift
NavigationStack("Library") {           // the root's title is an argument
    VStack {
        NavigationLink("Shaders") { ShaderGalleryScreen() }
        NavigationLink(title: "About") {
            AboutScreen()
        } label: {
            HStack { Circle().frame(width: 8, height: 8); Text("About") }
        }
    }
}
```

The stack draws a title bar with a Back button. A pushed screen's title
comes from its link. Screens beneath the top one stay alive — their state
and scroll positions are there when you come back. There is no preference
system, so a child cannot set `.navigationTitle` upward; that is why the
titles are arguments.

## Shaders

A `Shader` view runs a GLSL compute shader on its own GPU node, composited
into the view's frame. It takes whatever space it is given, so frame it.

```swift
let plasma = ShaderFunction("""
    float v = sin(uv.x * 10.0 + time) + sin((uv.y * 10.0 + time) * 0.5);
    fragColor = vec4(vec3(0.5 + 0.5 * sin(3.14159 * v)), 1.0);
""")

Shader(plasma).frame(maxWidth: .infinity, maxHeight: .infinity)
Shader(ShaderLibrary.tunnel).frame(width: 120, height: 68)   // thumbnails work too
```

In the body: `uv`, `fragCoord`, `time`, `resolution`, `mouse` are in scope
and you assign `fragColor`. Helper functions go in
`ShaderFunction(functions: "...", body)`. An unmodified ShaderToy shader
drops straight in:

```swift
ShaderFunction(shaderToy: """
    void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        vec2 uv = fragCoord / iResolution.xy;
        fragColor = vec4(uv, 0.5 + 0.5 * sin(iTime), 1.0);
    }
""")
```

with `iTime`, `iTimeDelta`, `iFrame`, `iResolution`, `iMouse` in ShaderToy's
types and y-up coordinates. `iChannel` textures and screen-space derivatives
(`fwidth`, `dFdx`) are not available — it is a compute shader, not a fragment
one. A shader that does not compile fails with shaderc's message.
`ShaderLibrary` ships eight ready-made ones.

Shader views are clipped by their containers (a shader in a `ScrollView`
is cut off at its edge) but always composite as a rectangle —
`.cornerRadius` does not round them.

### A view as the shader's input

`.shader(_:)` goes the other way: the view it is applied to is drawn into a
texture, and the shader reads that texture and writes what appears in its
place — SwiftUI's `layerEffect`. The view still lays out, still takes
input, still keeps its state; only its pixels change.

```swift
mixerPanel
    .cornerRadius(14)                       // clip inside the effect, so the
    .shader(ShaderLibrary.crt)              // rounding is in the texture

card.shader(ShaderLibrary.wave, isEnabled: effectsOn)   // toggled without rebuilding `card`

Text("Hello").shader(source: """
    fragColor = layer(uv + vec2(sin(uv.y * 30.0 + time * 3.0) * 0.01, 0.0));
""")
```

In the body, `layer(uv)` is the view's pixel under the current one — so
`fragColor = layer(uv);` is the identity — and `uContent` is the `sampler2D`
behind it, stored y-up like everything else in shader space. It is also
`iChannel0`, so a ShaderToy post-processing shader that reads
`texture(iChannel0, uv)` drops in through `ShaderFunction(shaderToy:)`
unchanged. `ShaderLibrary.effects` has eight to start from: identity, CRT,
wave, pixelate, chromatic aberration, blur, ripple, and a ShaderToy-form
one.

A shader whose source never reads the clock or the pointer is dispatched
once, and again only when the view under it repaints; one that does runs
every frame. Effects do not nest — a `Shader` view or a second `.shader`
inside one is composited over the effect's output, not through it.

## Seeing what the framework does

Set these in the environment when running:

| Variable | Prints |
| --- | --- |
| `NUCLEANT_SWIFTUI_TRACE_PERF=1` | per rebuild: kind, time, nodes built / reused, cache misses, `.shader` canvases redrawn |
| `NUCLEANT_SWIFTUI_TRACE_PERF=2` | …plus every view built or reused, with the reason it was not reused, and each shader slot built with its cost |
| `NUCLEANT_SWIFTUI_TRACE_INPUT=1` | hit testing — what each press landed on |
| `NUCLEANT_SWIFTUI_TRACE_LAYOUT=1` | the placed display list, rect by rect |

A rebuild happens only when state changed, and only from the views that
own or read that state downward; children whose inputs are unchanged keep
their subtree. `=2` is how to find out why one did not.

## Where to read more

* [plan.md](plan.md) — the surface, what is done, known limits, what is next.
* [PROCESS.md](PROCESS.md) — the decisions, the measurements behind them,
  and the bugs found along the way.
