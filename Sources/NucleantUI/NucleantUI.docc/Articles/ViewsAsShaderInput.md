# Using a view as a shader's input

Draw any view into a texture and let a shader decide what reaches the screen.

## Overview

A ``Shader`` view generates pixels. The `.shader(_:arguments:vertices:instances:backdrop:isEnabled:)`
modifier goes the other way: the view it is applied to is drawn into a
texture of its own, and the shader reads that texture and writes what
appears in its place — SwiftUI's `layerEffect`.

Only the pixels change. The view still lays out, still takes input and
keeps its state: a slider under a ripple is still a slider.

```swift
mixerPanel
    .cornerRadius(14)                 // clip inside the effect
    .shader(ShaderLibrary.crt)
```

## Reading the view

Inside the body, `layer(uv)` is the view's pixel at `uv`, so
`fragColor = layer(uv);` is the identity and a distortion is
`layer(uv + offset)`:

```swift
Text("Hello").shader(source: """
    fragColor = layer(uv + vec2(sin(uv.y * 30.0 + time * 3.0) * 0.01, 0.0));
""")
```

The texture itself is `uContent`, a `sampler2D` stored y-up like the rest of
shader space. It is also ShaderToy's `iChannel0`, so a ShaderToy
post-processing shader that reads `texture(iChannel0, uv)` works through
`ShaderFunction(shaderToy:)` unchanged.

``ShaderLibrary/effects`` has eight to start from: identity, CRT, wave,
pixelate, chromatic aberration, blur, ripple, and a ShaderToy-form one.

## Clip inside the effect

The effect composites as a rectangle. Round the corners, clip, or add a
background *before* `.shader`, so they are in the texture:

```swift
card
    .background(Color.secondaryBackground)
    .cornerRadius(12)
    .shader(ShaderLibrary.wave)
```

## Toggle without rebuilding

`isEnabled: false` draws the view as usual and keeps its identity and state,
so an effect can be switched on and off without rebuilding what is under it:

```swift
card.shader(ShaderLibrary.pixelate, isEnabled: isPixelated)
```

## The backdrop

`backdrop: true` puts what was already painted under the view's rect into
the texture first, so `layer(uv)` reads the view *and* its background — what
a pane of glass refracts. The shader's output is composited over the canvas,
so a label meant to sit on the glass goes inside the effect, not on top of
it. The window's clear colour and other shader views are not paint, so they
are not in the backdrop.

## Vertex stages

A function with a vertex stage is drawn instead of dispatched, over the same
texture under the same names. Its fragment stage shades only what its
triangles cover, so to keep the view on screen, draw one instance as a
full-view quad returning `layer(uv)` and put everything else after it — see
<doc:TouchSparks>.

## Cost

A function that reads neither the clock nor the pointer is dispatched once,
and again only when the view under it repaints or an argument changes; one
that does runs every frame. Effects do not nest: a ``Shader`` or a second
`.shader` inside an effect is composited over its output, not through it.

## Topics

### Showcases

- <doc:RetroMixer>
- <doc:Magnifier>
- <doc:GlassPanel>
- <doc:TouchSparks>
