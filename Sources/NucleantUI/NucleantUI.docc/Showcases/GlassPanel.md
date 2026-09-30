# A pane of glass over a backdrop

Refract what is painted behind a view with `backdrop: true`.

@Metadata {
    @PageImage(purpose: card, source: "showcase-glass", alt: "A rounded glass pane over coloured shapes, bending them at its rim.")
}

## Overview

@Image(source: "showcase-glass", alt: "A rounded glass pane labelled Glass over orange, pink and teal shapes and large white letters; the shapes are bent and milky near its rim.")

With `backdrop: true`, what was painted under the view's rect is drawn into
the texture before the view itself, so `layer(uv)` reads the view *and* what
is behind it. The shader keeps the middle of the pane clear — the label on it
stays sharp — and pulls the pixels near the rim inwards, the way thick glass
bends light at its edge.

- The label is *inside* the effect. The shader's output is composited over
  the canvas, so a view stacked on top of the glass would be covered by it.
- The backdrop is paint — shapes, a gradient, text. Other ``Shader`` views
  and the window's clear colour are not paint and are not in the texture.
- The pane is dragged with `.offset` and a ``DragGesture``. Each move
  repaints what is under it, and the glass refracts the new backdrop.
- The shape of the pane is a rounded-rectangle distance function in the
  shader; outside it the output is transparent.

## The code

```swift
import NucleantUI

/// A rounded pane of glass. The middle passes the backdrop and the view
/// straight through, so a label on the glass stays sharp; towards the rim the
/// pixels are pulled inwards — refraction — and turned milky, and the edge
/// catches a highlight. Outside the rounded rect nothing is drawn.
let glass = ShaderFunction("""
    vec2 halfSize = resolution * 0.5;
    vec2 p = uv * resolution - halfSize;                 // pixels from the centre
    vec2 q = abs(p) - (halfSize - cornerRadius);
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - cornerRadius;

    float edge = clamp(1.0 + d / bezel, 0.0, 1.0);       // 0 inside, 1 at the rim
    vec2 inward = p / max(length(p), 1.0);
    vec4 color = layer(uv - inward * edge * edge * bezel * 0.7 / resolution);

    color.rgb = mix(color.rgb, vec3(1.0), 0.06 + 0.3 * edge * edge);
    float highlight = smoothstep(1.5, 0.0, abs(d + 1.0)) * 0.6;
    fragColor = vec4(color.rgb + highlight, smoothstep(0.5, -0.5, d));
""")

@View
struct GlassPanel {
    @State private var offset = Size(width: 0, height: 0)
    @State private var dragStart = Size(width: 0, height: 0)

    var body: some View {
        ZStack {
            backdrop

            VStack(spacing: 6) {
                Text("Glass").font(.title)
                Text("drag me over the shapes").font(.footnote)
            }
            .foregroundColor(.white)
            .frame(width: 260, height: 140)
            .shader(glass, arguments: [
                .float("cornerRadius", 28),
                .float("bezel", 22),
            ], backdrop: true)
            .offset(x: offset.width, y: offset.height)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        offset = Size(
                            width: dragStart.width + value.translation.width,
                            height: dragStart.height + value.translation.height
                        )
                    }
                    .onEnded { _ in dragStart = offset }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Painted content — shapes and a gradient — since `backdrop: true`
    /// reads what was painted under the view, not other shader nodes.
    private var backdrop: some View {
        ZStack {
            Rectangle().fill(.linearGradient(colors: [Color(hex: 0x1B2A4A), Color(hex: 0x4A1B3F)]))
            Circle().fill(Color.orange).frame(width: 180, height: 180).offset(x: -140, y: -60)
            Circle().fill(Color.teal).frame(width: 140, height: 140).offset(x: 150, y: 70)
            RoundedRectangle(cornerRadius: 16).fill(Color.pink)
                .frame(width: 120, height: 120).rotationEffect(.degrees(20)).offset(x: 40, y: -110)
            Text("NUCLEANT").font(.system(size: 64, weight: .bold)).foregroundColor(.white.opacity(0.85))
        }
    }
}
```
