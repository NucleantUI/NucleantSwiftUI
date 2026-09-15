//
//  ThorDisplayRenderer.swift
//  NucleantSwiftUI
//
//  The only file that turns `DisplayList` into ThorVG paints. Everything above
//  it is backend-agnostic — swapping in the Skia node kind PyNucleantUI also
//  supports would mean a sibling of this file and nothing else.
//
//  Paints are handed to the canvas with `tvg_canvas_add`, which takes
//  ownership. A rebuild therefore clears the canvas (`tvg_canvas_remove` with a
//  null paint) and re-adds; the alternative — diffing paints across passes —
//  buys nothing while rebuilds are already gated on invalidation.
//
//  A `.shader` effect's layer canvas is drawn the same way, with one
//  difference: every paint goes into a root scene carrying a transform that
//  puts the view's origin at the canvas corner and runs y upwards — so the
//  compute shader sampling the canvas sees the view in the shader's own
//  coordinate space. A scene rather than a per-paint matrix because ThorVG
//  applies a paint's own transform to the paint alone, not to its clipper,
//  while a parent scene's transform reaches both.
//

import NucleantThorVG

@MainActor
public final class ThorDisplayRenderer {

    /// The canvas the engine's ThorVG node draws into.
    private let canvas: Tvg_Canvas

    /// Layout runs in points; the canvas is sized in backing-store pixels.
    /// Everything is scaled on the way in rather than the layout being taught
    /// about pixels.
    public var scale: Double = 1

    public init(canvas: Tvg_Canvas) {
        ThorEngine.ensureInitialized()
        self.canvas = canvas
    }

    /// Where finished paints go: the canvas itself, or the root scene of a
    /// layer render while one is in progress.
    private var scene: Tvg_Paint?

    /// Replace the canvas contents with `list`.
    public func render(_ list: DisplayList) {
        render(list, origin: nil, flipHeight: 0)
    }

    /// Replace the canvas contents with `list` drawn as a layer: shifted so
    /// `origin` (points) lands at the canvas corner, and flipped so y runs
    /// upwards over a canvas `flipHeight` pixels tall. A `.shader` effect
    /// samples the result in shader space, where (0, 0) is the bottom-left.
    func render(_ list: DisplayList, origin: Point?, flipHeight: Int) {
        _ = tvg_canvas_remove(canvas, nil)
        scene = nil
        if let origin, let root = tvg_scene_new() {
            // Pixel space, applied after `scale`: translate by the origin,
            // then y' = height - y.
            var matrix = Tvg_Matrix(
                e11: 1, e12: 0,  e13: Float(-origin.x * scale),
                e21: 0, e22: -1, e23: Float(Double(flipHeight) + origin.y * scale),
                e31: 0, e32: 0,  e33: 1
            )
            _ = tvg_paint_set_transform(root, &matrix)
            scene = root
        }
        for command in list.commands {
            switch command {
            case .shape(let draw):
                emit(draw)
            case .text(let draw):
                emit(draw)
            }
        }
        if let scene {
            _ = tvg_canvas_add(canvas, scene)
            self.scene = nil
        }
    }

    // MARK: - Shapes

    private func emit(_ draw: ShapeDraw) {
        guard let shape = tvg_shape_new() else { return }

        appendPath(draw.path, to: shape)

        if let fill = draw.fill, !fill.isClear {
            apply(fill, to: shape, bounds: draw.bounds, stroke: false)
        }
        if let stroke = draw.stroke, !stroke.isClear, draw.strokeStyle.lineWidth > 0 {
            _ = tvg_shape_set_stroke_width(shape, Float(draw.strokeStyle.lineWidth * scale))
            _ = tvg_shape_set_stroke_cap(shape, thorCap(draw.strokeStyle.lineCap))
            _ = tvg_shape_set_stroke_join(shape, thorJoin(draw.strokeStyle.lineJoin))
            if !draw.strokeStyle.dash.isEmpty {
                let pattern = draw.strokeStyle.dash.map { Float($0 * scale) }
                pattern.withUnsafeBufferPointer { buffer in
                    _ = tvg_shape_set_stroke_dash(
                        shape,
                        buffer.baseAddress,
                        UInt32(pattern.count),
                        Float(draw.strokeStyle.dashPhase * scale)
                    )
                }
            }
            apply(stroke, to: shape, bounds: draw.bounds, stroke: true)
        }

        finish(paint: shape, transform: draw.transform, clip: draw.clip, cornerRadius: draw.clipCornerRadius)
    }

    private func appendPath(_ path: Path, to shape: Tvg_Paint) {
        for element in path.elements {
            switch element {
            case .move(let point):
                _ = tvg_shape_move_to(shape, f(point.x), f(point.y))
            case .line(let point):
                _ = tvg_shape_line_to(shape, f(point.x), f(point.y))
            case .cubic(let c1, let c2, let end):
                _ = tvg_shape_cubic_to(shape, f(c1.x), f(c1.y), f(c2.x), f(c2.y), f(end.x), f(end.y))
            case .close:
                _ = tvg_shape_close(shape)
            case .rect(let rect, let radiusX, let radiusY):
                _ = tvg_shape_append_rect(
                    shape,
                    f(rect.minX), f(rect.minY), f(rect.width), f(rect.height),
                    f(radiusX), f(radiusY),
                    true
                )
            case .ellipse(let center, let radiusX, let radiusY):
                _ = tvg_shape_append_circle(
                    shape,
                    f(center.x), f(center.y), f(radiusX), f(radiusY),
                    true
                )
            }
        }
    }

    private func apply(_ style: ShapeStyle, to shape: Tvg_Paint, bounds: Rect, stroke: Bool) {
        switch style {
        case .color(let color):
            let (r, g, b, a) = color.rgba8
            if stroke {
                _ = tvg_shape_set_stroke_color(shape, r, g, b, a)
            } else {
                _ = tvg_shape_set_fill_color(shape, r, g, b, a)
            }
        case .linearGradient(let gradient, let startPoint, let endPoint):
            guard let handle = tvg_linear_gradient_new() else { return }
            let start = startPoint.resolved(in: bounds)
            let end = endPoint.resolved(in: bounds)
            _ = tvg_linear_gradient_set(handle, f(start.x), f(start.y), f(end.x), f(end.y))
            setStops(gradient, on: handle)
            if stroke {
                _ = tvg_shape_set_stroke_gradient(shape, handle)
            } else {
                _ = tvg_shape_set_gradient(shape, handle)
            }
        case .radialGradient(let gradient, let center, let startRadius, let endRadius):
            guard let handle = tvg_radial_gradient_new() else { return }
            let origin = center.resolved(in: bounds)
            _ = tvg_radial_gradient_set(
                handle,
                f(origin.x), f(origin.y), f(endRadius),
                f(origin.x), f(origin.y), f(startRadius)
            )
            setStops(gradient, on: handle)
            if stroke {
                _ = tvg_shape_set_stroke_gradient(shape, handle)
            } else {
                _ = tvg_shape_set_gradient(shape, handle)
            }
        }
    }

    private func setStops(_ gradient: Gradient, on handle: Tvg_Gradient) {
        let stops = gradient.stops.map { stop -> Tvg_Color_Stop in
            let (r, g, b, a) = stop.color.rgba8
            return Tvg_Color_Stop(offset: Float(stop.location), r: r, g: g, b: b, a: a)
        }
        stops.withUnsafeBufferPointer { buffer in
            _ = tvg_gradient_set_color_stops(handle, buffer.baseAddress, UInt32(stops.count))
        }
    }

    // MARK: - Text

    private func emit(_ draw: TextDraw) {
        guard let text = tvg_text_new() else { return }

        if let family = FontRegistry.resolve(draw.font) {
            _ = family.withCString { tvg_text_set_font(text, $0) }
        } else {
            // No face resolved — ThorVG picks its own fallback rather than
            // drawing nothing.
            _ = tvg_text_set_font(text, nil)
        }
        _ = tvg_text_set_size(text, f(draw.font.size))
        _ = draw.string.withCString { tvg_text_set_text(text, $0) }

        let (r, g, b, a) = draw.color.rgba8
        _ = tvg_text_set_color(text, r, g, b)
        // `tvg_text_set_color` carries no alpha channel, so fading has to go
        // through the paint's opacity.
        _ = tvg_paint_set_opacity(text, a)

        if draw.font.isItalic {
            // Only used when no real italic face was found; a synthetic shear
            // still reads as italic.
            _ = tvg_text_set_italic(text, 0.2)
        }

        // The layout box the view system already measured. Wrapping is done in
        // `TextMeasurer` for sizing, and repeated here by ThorVG for drawing —
        // both use the same font metrics, so they agree.
        _ = tvg_text_layout(text, f(draw.frame.width), f(draw.frame.height))
        // Ellipsis *only* when layout found the string too wide. ThorVG
        // reserves room for the "…" whenever the mode is set, so a box
        // measured to exactly fit its text — which is what layout produces —
        // would lose two characters to a truncation that wasn't needed.
        let wrapMode: Tvg_Text_Wrap
        if draw.lineLimit == 1 {
            wrapMode = draw.isTruncated ? TVG_TEXT_WRAP_ELLIPSIS : TVG_TEXT_WRAP_NONE
        } else {
            wrapMode = draw.wraps ? TVG_TEXT_WRAP_WORD : TVG_TEXT_WRAP_NONE
        }
        _ = tvg_text_wrap_mode(text, wrapMode)
        _ = tvg_text_align(text, Float(alignFactor(draw.alignment)), 0)
        _ = tvg_paint_translate(text, f(draw.frame.minX), f(draw.frame.minY))

        finish(paint: text, transform: draw.transform, clip: draw.clip, cornerRadius: draw.clipCornerRadius)
    }

    private func alignFactor(_ alignment: TextAlignment) -> Double {
        switch alignment {
        case .leading:  return 0
        case .center:   return 0.5
        case .trailing: return 1
        }
    }

    // MARK: - Shared tail

    /// Apply the ambient transform and clip, then hand the paint to the canvas.
    private func finish(paint: Tvg_Paint, transform: Transform, clip: Rect?, cornerRadius: Double) {
        if !transform.isIdentity {
            // The paint's own translation (text) is already in its matrix, so
            // the ambient transform is composed on top of what is there rather
            // than replacing it.
            var current = Tvg_Matrix()
            _ = tvg_paint_get_transform(paint, &current)
            var combined = matrix(scaled(transform).concatenating(from(current)))
            _ = tvg_paint_set_transform(paint, &combined)
        }

        if let clip, let clipper = tvg_shape_new() {
            // `.clipShape(Capsule())` asks for an unbounded radius, meaning
            // "as round as this box allows" — resolvable only here, where the
            // box is known. Clamping is also what keeps ThorVG from drawing
            // overlapping arcs for a radius past half the shorter side.
            let radius = min(cornerRadius, min(clip.width, clip.height) / 2)
            _ = tvg_shape_append_rect(
                clipper,
                f(clip.minX), f(clip.minY), f(clip.width), f(clip.height),
                f(radius), f(radius),
                true
            )
            // The clipper is owned by the paint it clips — never added to the
            // canvas itself.
            _ = tvg_paint_set_clip(paint, clipper)
        }

        if let scene {
            _ = tvg_scene_add(scene, paint)
        } else {
            _ = tvg_canvas_add(canvas, paint)
        }
    }

    /// The same transform expressed in pixels: translation scales, the linear
    /// part doesn't (a rotation is scale-invariant).
    private func scaled(_ transform: Transform) -> Transform {
        var copy = transform
        copy.e13 *= scale
        copy.e23 *= scale
        return copy
    }

    private func matrix(_ transform: Transform) -> Tvg_Matrix {
        Tvg_Matrix(
            e11: Float(transform.e11), e12: Float(transform.e12), e13: Float(transform.e13),
            e21: Float(transform.e21), e22: Float(transform.e22), e23: Float(transform.e23),
            e31: 0, e32: 0, e33: 1
        )
    }

    private func from(_ matrix: Tvg_Matrix) -> Transform {
        Transform(
            e11: Double(matrix.e11), e12: Double(matrix.e12), e13: Double(matrix.e13),
            e21: Double(matrix.e21), e22: Double(matrix.e22), e23: Double(matrix.e23)
        )
    }

    /// Points → device pixels, as a `Float` for the C API.
    private func f(_ value: Double) -> Float { Float(value * scale) }

    private func thorCap(_ cap: LineCap) -> Tvg_Stroke_Cap {
        switch cap {
        case .butt:   return TVG_STROKE_CAP_BUTT
        case .round:  return TVG_STROKE_CAP_ROUND
        case .square: return TVG_STROKE_CAP_SQUARE
        }
    }

    private func thorJoin(_ join: LineJoin) -> Tvg_Stroke_Join {
        switch join {
        case .miter: return TVG_STROKE_JOIN_MITER
        case .round: return TVG_STROKE_JOIN_ROUND
        case .bevel: return TVG_STROKE_JOIN_BEVEL
        }
    }
}
