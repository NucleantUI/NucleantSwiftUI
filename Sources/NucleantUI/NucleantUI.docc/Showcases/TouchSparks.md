# Sparks over a view with a vertex stage

Draw the view and any number of glows over it in one instanced draw call.

@Metadata {
    @PageImage(purpose: card, source: "showcase-sparks", alt: "A card with a trail of orange glows drawn across it.")
}

## Overview

@Image(source: "showcase-sparks", alt: "A dark card titled Drag across the card, with a wavy trail of forty orange glows drawn over its lower half.")

A ``ShaderFunction`` with a vertex stage can be applied with `.shader` too.
It gets the same texture under the same names, but its fragment stage shades
only the pixels its triangles cover, and the rest of the rect is cleared. So
the view itself is one more instance: instance 0 is a quad over the whole
view that returns `layer(uv)`, and every instance after it is a small quad at
one spark.

- There are no vertex buffers. The vertex stage picks a corner from
  `gl_VertexIndex` and a spark from `gl_InstanceIndex`, reading the sparks
  from a `.float4Array` argument: `sparks(i)` returns one `vec4`.
- `vertices: 6` is one quad as two triangles; `instances: sparks.count + 1`
  is the view plus a quad per spark. Both are per-frame values, so a new
  spark redraws without rebuilding anything.
- `varyings` is declared once and read as plain variables in both stages:
  `local` places the glow within its quad, `seed` makes each spark flicker
  on its own and marks instance 0 with a negative value.
- Shader space counts pixels and a drag reports points, so the drag
  location is scaled by `\.displayScale` before it goes to the shader.

## The code

```swift
import NucleantUI

/// One draw call for the view and every spark over it. Instance 0 is a
/// quad over the whole view that returns `layer(uv)` — the view, untouched;
/// each instance after it is a small quad at one spark, shaded as a glow.
let sparkShader = ShaderFunction(
    functions: """
    const vec2 QUAD[6] = vec2[](vec2(-1, -1), vec2(1, -1), vec2(-1, 1),
                                vec2(-1, 1), vec2(1, -1), vec2(1, 1));
    """,
    varyings: "vec2 local; float seed;",
    vertex: """
        vec2 corner = QUAD[gl_VertexIndex];
        local = corner * 0.5 + 0.5;
        if (gl_InstanceIndex == 0) {
            seed = -1.0;
            gl_Position = vec4(corner, 0.0, 1.0);
        } else {
            vec4 spark = sparks(gl_InstanceIndex - 1);   // x, y (y down), size, seed
            vec2 centre = vec2(spark.x / resolution.x, 1.0 - spark.y / resolution.y) * 2.0 - 1.0;
            gl_Position = vec4(centre + corner * spark.z / resolution, 0.0, 1.0);
            seed = spark.w;
        }
    """,
    fragment: """
        if (seed < 0.0) {
            fragColor = layer(uv);
        } else {
            float glow = smoothstep(0.5, 0.0, distance(local, vec2(0.5)));
            float flicker = 0.65 + 0.35 * sin(time * 14.0 + seed * 40.0);
            fragColor = vec4(vec3(1.0, 0.62, 0.25) * flicker, glow);
        }
    """
)

@View
struct TouchSparks {
    @Environment(\.displayScale) private var scale
    @State private var sparks: [Float4] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drag across the card").font(.headline)
            Text("Each point of the drag becomes one more instance of the same draw.")
                .foregroundColor(.secondary)
            HStack {
                Button("Clear") { sparks.removeAll() }
                Text("\(sparks.count) sparks").foregroundColor(.secondary)
            }
        }
        .padding(24)
        .frame(width: 420, height: 240, alignment: .topLeading)
        .background(Color.secondaryBackground)
        .cornerRadius(16)
        .shader(sparkShader, arguments: [.float4Array("sparks", sparks)],
                vertices: 6, instances: sparks.count + 1)
        .gesture(
            DragGesture().onChanged { value in
                // Shader space counts pixels; a drag reports points.
                let seed = Float.random(in: 0...1)
                sparks.append(Float4(Float(value.location.x * scale), Float(value.location.y * scale),
                                     Float(28 * scale), seed))
                if sparks.count > 64 { sparks.removeFirst() }
            }
        )
    }
}
```
