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

[Examples/](Examples) has seven standalone apps built on the library — a
calculator, a task list, a drawing pad, a dashboard, 2048, a pomodoro
timer and a drum sampler — each its own package to copy from.

The library also runs on iOS 17+ — verified on an M1 iPad Pro.
[XcodeExamples/](XcodeExamples) has the demo as an Xcode project with iOS
(device and simulator) and macOS destinations over the same sources;
`@main struct DemoApp: NucleantApp` is the entry point on both platforms,
and a finger scrolls `ScrollView`s and drives the same gestures a mouse
does.

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
  `\.displayScale`, `\.colorScheme`; set with `.environment(\.key, value)`
  or the sugar (`.font`, `.foregroundColor`, `.tint`, `.disabled`,
  `.lineLimit`, `.colorScheme`).

### Light and dark

The window seeds `\.colorScheme` from the system appearance and follows
it as it changes. Colors can carry both appearances:

```swift
Color.primary, .secondary, .tertiary            // text
Color.background, .secondaryBackground,          // window, panels,
      .tertiaryBackground, .separator, .fill     // rows, hairlines, tracks
Color.dynamic(light: Color(hex: 0xEEE4DA), dark: Color(hex: 0x4A5568))

card.colorScheme(.dark)                          // fix a subtree
AppRuntimeSettings.colorScheme = .dark           // fix every window, before main()
```

A dynamic color is resolved where it is drawn, against the scheme in
effect there — so `.colorScheme(_:)` on a subtree flips everything inside
it, navigation bar and `.shader` layers included, and a `.color` shader
argument arrives resolved. A plain `Color(hex:)` is the same in both.
The demo and every example have a System / Light / Dark switch
(`Examples/*/Appearance.swift` is the whole control).

### `@Observable` models

A class marked `@Observable` (the standard library's) is read directly:

```swift
@MainActor @Observable
final class Sample {
    var gain: Double = 1
    private(set) var envelope: [Float] = []
    func analyse() {
        Task.detached {
            let result = reduce(…)
            await MainActor.run { self.envelope = result }   // redraws the readers
        }
    }
}

@View
struct GainControl {
    @Bindable var sample: Sample          // or `let sample: Sample` when read-only

    var body: some View {
        Fader(level: $sample.gain)        // Binding<Double> straight into the object
        Text("\(sample.envelope.count) points")
    }
}
```

Every property a view's `body` reads is tracked; a write to it — from a
binding, a button, a timer, or a task coming back to the main actor —
rebuilds that view on the next frame, and only that view. A view holding a
reference to the same object is an unchanged input, so the object can be
passed down freely; what changes inside it is caught by the tracking.
`@Bindable` gives `$model.property` bindings by key path.

## Layout and views

`VStack`, `HStack`, `ZStack` (with `alignment`/`spacing`), `Spacer`,
`Divider`, `Group`, `ForEach` (with `id:` or `Identifiable` data), `if` /
`if let` / `switch` in builders, `AnyView`, `EmptyView`.

`Text` with `.font`, `.bold`, `.italic`, `.fontWeight`,
`.foregroundColor`, `.lineLimit`, `.multilineTextAlignment` — set on the
`Text` or inherited from the environment. Fonts: `.system(size:weight:design:)`,
`.custom(_:size:)`, the standard styles (`.title`, `.body`, `.footnote`, …).
The default and monospaced designs are Roboto and Roboto Mono, bundled with
the library so text is the same on every platform; `.serif` and
`.custom` families are looked up on the system (through CoreText on Apple
platforms), or registered from a file with `FontRegistry.register(path:as:)`.

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

`Image(_:)` draws a `RasterImage` — a decoded bitmap, made from a file with
`RasterImage(contentsOf:)` (ImageIO, on Apple platforms), from a `CGImage`,
or from ARGB pixels; `cropped(to:)` cuts one cell out of a sprite sheet.
An image is drawn at its pixel size unless it is `.resizable()`, which
stretches it to what it is offered:

```swift
let sheet = RasterImage(contentsOf: url)!
let frame = sheet.cropped(to: Rect(x: 2, y: 2, width: 128, height: 128))
Image(frame).resizable().scaledToFit()
```

Modifiers: `.frame(width:height:alignment:)`,
`.frame(minWidth:maxWidth:minHeight:maxHeight:)`, `.padding(...)`,
`.relativeSize(width:height:)`, `.aspectRatio(_:contentMode:)` /
`.scaledToFit()` / `.scaledToFill()`, `.background(_:)`, `.overlay(_:)`,
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

### Context menus

```swift
TrackRow(track)
    .contextMenu {
        Button("Duplicate") { duplicate(track) }
        Button("Rename…") { rename(track) }
        Divider()
        Button("Delete") { delete(track) }
    }
```

Opens on a right click, or on a press held still on a touch host, at the
pointer and kept inside the window. `Button`s are the rows — lit in the
tint while pressed, run their action and close the menu — `Divider` is a
rule, and `if` works as in any builder. A press anywhere outside closes
it and goes no further. There is no hover highlight, no submenu, and no
keyboard.

### Drag and drop

A value moves between views the way it does in SwiftUI: it is
`Transferable`, a `.draggable` view carries it, a `.dropDestination` takes
it.

```swift
struct Track: Codable, Transferable {
    let name: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)     // its native form
        ProxyRepresentation(exporting: \.name)        // …and as plain text
    }
}

TrackChip(track).draggable(track)                     // the chip is the preview
label.draggable("a note") { Text("note").padding(6) } // or bring your own

bus.dropDestination(for: Track.self) { tracks, location in
    added.append(contentsOf: tracks)                  // location in `bus`'s space
    return true
} isTargeted: { over in isHighlighted = over }

notes.dropDestination(for: String.self) { … }         // takes the track too, via the proxy
```

`CodableRepresentation` (JSON by default, or any `TransferEncoder` /
`TransferDecoder` pair — Foundation's property-list coders are one),
`DataRepresentation(contentType:exporting:importing:)` and
`ProxyRepresentation(exporting:importing:)` are the representations;
`String`, `Data` and `URL` conform already. Content types are `UTType`s
(`.json`, `.utf8PlainText`, `.data`, `.url`, `.png`, …, or
`UTType(exportedAs: "com.example.track")`), and a destination for `T` takes
a drag whose payload exports something `T` imports — by conformance, so
`.text` takes `.json`. The transfer stays inside the process but still goes
through the bytes, so a representation that would not survive a pasteboard
does not survive this either.

A drag starts after the pointer has moved a few points with the button
held; a click still reaches whatever is inside, and a fader inside a
draggable card keeps its own drag. On a touch host a draggable inside a
scroll view starts from a press held still, so a finger can still scroll.
The preview is a snapshot of the view as it was drawn (a `Shader` inside
it is not in the snapshot), at 80% opacity, following the pointer.

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
types and y-up coordinates.

### Arguments

Values from Swift reach the body as named inputs — SwiftUI's
`Shader.Argument`:

```swift
Shader(envelope, arguments: [
    .floatArray("mins", negatives),       // float mins(int i); int minsCount;
    .floatArray("maxs", positives),
    .float("gain", sample.gain),          // float gain;
    .color("tint", sample.color),         // vec4  tint;
])
```

Scalars and vectors (`.float`, `.float2/3/4`, `.color`) are plain variables
in the body; an array is read through `name(i)` with `nameCount` beside it
(reads are clamped to the array, an empty one reads as zero). They live in
a storage buffer, so an array can be long. A change to a value
re-dispatches the shader — a shader that reads no clock is otherwise drawn
once — while the *set* of names and kinds is part of the compiled
pipeline, so keep that stable and vary the values. `.shader(_:arguments:)`
takes the same list. The Sampler example draws a waveform this way. `iChannel` textures and screen-space derivatives
(`fwidth`, `dFdx`) are not available — it is a compute shader, not a fragment
one. A shader that does not compile fails with shaderc's message.
`ShaderLibrary` ships eight ready-made ones.

### Vertex shaders

A `VertexShader` view draws `vertices × instances` through a vertex +
fragment pipeline into the same kind of slot, with no vertex buffers: the
vertex body places geometry from `gl_VertexIndex`, `gl_InstanceIndex` and the
arguments, so an array of N touches becomes N quads in one draw call, and
only the pixels each quad covers are shaded.

```swift
let glow = VertexShaderFunction(
    functions: "const vec2 QUAD[6] = vec2[](vec2(-1,-1), vec2(1,-1), vec2(-1,1), vec2(-1,1), vec2(1,-1), vec2(1,1));",
    varyings: "vec2 local; float seed;",
    vertex: """
        int t = gl_InstanceIndex * 3;
        vec2 corner = QUAD[gl_VertexIndex];
        gl_Position = vec4(vec2(touches(t), touches(t + 1)) + corner * 0.25, 0.0, 1.0);
        local = corner * 0.5 + 0.5;
        seed = touches(t + 2);
    """,
    fragment: """
        fragColor = vec4(vec3(fract(seed + time)), smoothstep(0.5, 0.0, distance(local, vec2(0.5))));
    """)

VertexShader(glow, vertices: 6, instances: touches.count, arguments: [
    .floatArray("touches", packed),
])
```

`varyings` is declared once and usable as plain variables in both bodies.
Both stages see `time`, `resolution`, `mouse` and the arguments; the fragment
stage has `uv` and `fragCoord` as well. `gl_Position` is written y-up, as
in OpenGL, and flipped for Vulkan by the wrapper. `vertices` and `instances`
are per-frame values — changing them redraws without a rebuild. The same
shader in PyShader is one module with `vertex` and `fragment` functions
(`VertexShaderFunction(pyshader:)`); see PyShader's README. The Baby Lights
app draws every glow this way.

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

`backdrop: true` puts what was already painted under the view's rect into
the texture first — everything earlier in paint order — so `layer(uv)` is
the view *and* its background: what a glass or a frosted panel refracts.
The shader's output is composited over the canvas, so a label meant to sit
on such a pad goes inside the effect, not on top of it:

```swift
Text("Play").padding()
    .shader(ShaderFunction(pyshader: liquidGlass), arguments: [.float("radius", 24)], backdrop: true)
```

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
