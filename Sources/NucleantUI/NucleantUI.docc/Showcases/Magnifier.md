# A magnifier that follows the pointer

Read the view's pixels from somewhere else to enlarge what is under the pointer.

@Metadata {
    @PageImage(purpose: card, source: "showcase-magnifier", alt: "A text card with a round loupe enlarging the words under it.")
}

## Overview

@Image(source: "showcase-magnifier", alt: "A card of text and coloured dots with a round, blue-rimmed loupe enlarging two words in the middle.")

A shader applied with `.shader` may read *any* pixel of the view, not just the
one it is writing. Inside a circle round the pointer, each pixel reads the
view at a point closer to the centre, so the text under the pointer grows.

- `mouse` is in scope in every shader: the pointer in the view's own pixels,
  y-up. Its `x` is zero until the pointer has been over the view, which is
  when the loupe sits in the middle instead.
- Reading `mouse` makes the effect run every frame while it is on screen, so
  the loupe follows the pointer without any Swift code at all.
- The zoom comes from a ``Slider`` as a `.float` ``ShaderArgument``. Changing
  it dispatches the shader again; the view under it is not rebuilt.

## The code

```swift
import NucleantUI

/// A loupe that follows the pointer: inside a circle round `mouse`, each
/// pixel reads the view closer to the centre, so what is under it grows.
let magnifier = ShaderFunction("""
    vec2 focus = mouse.x > 0.0 && mouse.y > 0.0 ? mouse / resolution : vec2(0.5);
    vec2 away = uv - focus;
    away.x *= resolution.x / resolution.y;      // a circle, not an ellipse
    float distanceToFocus = length(away);

    float lens = smoothstep(radius, radius - 0.004, distanceToFocus);
    vec2 source = focus + (uv - focus) / zoom;
    vec4 color = mix(layer(uv), layer(source), lens);

    float rim = smoothstep(0.006, 0.0, abs(distanceToFocus - radius));
    fragColor = mix(color, vec4(0.3, 0.55, 1.0, 1.0), rim);
""")

@View
struct MagnifiedArticle {
    @State private var zoom = 2.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Zoom")
                Slider(value: $zoom, in: 1...4)
                Text("\((zoom * 10).rounded() / 10)×")
                    .frame(width: 44, alignment: .trailing)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("The view is the texture").font(.title2)
                Text("""
                    Everything in this column is ordinary NucleantUI: text, \
                    a divider, a row of shapes. The .shader modifier draws it \
                    into a texture of its own and hands that to the shader, \
                    which is free to read any pixel of it — here, pixels \
                    nearer the pointer, so the text under it grows.
                    """)
                    .foregroundColor(.secondary)
                Divider()
                HStack(spacing: 8) {
                    ForEach([Color.red, .orange, .yellow, .green, .blue, .purple], id: \.self) { color in
                        Circle().fill(color).frame(width: 18, height: 18)
                    }
                }
            }
            .padding(20)
            .background(Color.secondaryBackground)
            .cornerRadius(12)
            .shader(magnifier, arguments: [
                .float("radius", 0.16),
                .float("zoom", Float(zoom)),
            ])
        }
        .padding(24)
    }
}
```
