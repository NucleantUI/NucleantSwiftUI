# Drawing with shaders

Put a GPU shader in a layout like any other view.

## A shader is a view

A ``Shader`` runs a GLSL compute shader on a GPU node of its own and
composites the result into its frame. It takes whatever space it is given, so
frame it:

```swift
let plasma = ShaderFunction("""
    float v = sin(uv.x * 10.0 + time) + sin((uv.y * 10.0 + time) * 0.5);
    fragColor = vec4(vec3(0.5 + 0.5 * sin(3.14159 * v)), 1.0);
""")

@View
struct Backdrop {
    var body: some View {
        VStack(spacing: 12) {
            Shader(plasma).frame(maxWidth: .infinity, maxHeight: .infinity)
            Shader(ShaderLibrary.tunnel).frame(width: 120, height: 68)
        }
    }
}
```

The body of a ``ShaderFunction`` is the inside of a per-pixel function.
`uv`, `fragCoord`, `time`, `resolution` and `mouse` are in scope, and you
assign `fragColor`. Shader space is y-up, as in OpenGL. Helper functions go
in `ShaderFunction(functions:_:)`.

## ShaderToy and PyShader

An unmodified ShaderToy image shader drops in with
`ShaderFunction(shaderToy:)`, with `iTime`, `iTimeDelta`, `iFrame`,
`iResolution` and `iMouse` in ShaderToy's own types:

```swift
let gradient = ShaderFunction(shaderToy: """
    void mainImage(out vec4 fragColor, in vec2 fragCoord) {
        vec2 uv = fragCoord / iResolution.xy;
        fragColor = vec4(uv, 0.5 + 0.5 * sin(iTime), 1.0);
    }
""")
```

`ShaderFunction(pyshader:)` takes a shader written in Python syntax and
compiled by [PyShader](https://github.com/NucleantUI/PyShader) — the
AnimatableShader example keeps its four shaders as bundled `.py` files.

## Arguments

Values from Swift reach the shader as named inputs, SwiftUI's
`Shader.Argument`:

```swift
Shader(meter, arguments: [
    .float("level", Float(level)),          // float level;
    .float2("size", Float2(width, height)), // vec2  size;
    .color("tint", .orange),                // vec4  tint;
    .floatArray("peaks", peaks),            // float peaks(int i); int peaksCount;
])
```

Scalars and vectors are plain variables in the body; an array is read
through `name(i)` with `nameCount` beside it. A change to a value dispatches
the shader again. The *set* of names and kinds is part of the compiled
pipeline, so keep it stable and vary the values.

A shader that reads neither the clock nor the pointer is dispatched once,
and again only when an argument changes. One that does runs every frame.

## Vertex shaders

`ShaderFunction(functions:varyings:vertex:fragment:)` is a vertex + fragment
pair drawn without vertex buffers: the vertex stage places geometry from
`gl_VertexIndex`, `gl_InstanceIndex` and the arguments, so an array of N
points becomes N quads in one draw call. Draw it with ``VertexShader``:

```swift
VertexShader(glow, vertices: 6, instances: touches.count, arguments: [
    .float2Array("touches", touches),
])
```

## Limits

Shaders here are compute shaders, not fragment shaders: `iChannel` textures
other than a view's own layer and screen-space derivatives (`fwidth`,
`dFdx`) are not available. A shader view composites as a rectangle —
`.cornerRadius` does not round it — and is clipped by its containers.

## Topics

### Going further

- <doc:ViewsAsShaderInput>
