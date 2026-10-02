//
//  SkiaDisplayRenderer.swift
//  NucleantUI
//
//  The Skia sibling of `ThorDisplayRenderer`: turns a `DisplayList` into
//  Skia draw calls on a node's `SkCanvas`. With `SKIA_MODE` (Package.swift's
//  `skiaMode`) it is the one that draws the views — the window canvas,
//  `.drawingGroup()`, the per-view painter and the `.shader` layers — in
//  place of the ThorVG one.
//
//  Skia is immediate: a draw call records into the surface, and nothing is
//  held between passes the way ThorVG's paints are. A render therefore
//  clears the canvas and draws the list again; the node's update flushes
//  the recording on the engine's queue.
//
//  The canvas is scaled once per render — layout runs in points, the canvas
//  is in backing-store pixels — and every command is drawn in points under
//  that. Stroke widths, dashes and glyphs scale with it. A command's clip is
//  set before its transform, as ThorVG applies a paint's transform to the
//  paint and not to its clipper.
//
//  Text is measured by `TextMeasurer` (ThorVG's metrics), and the lines,
//  baselines and ellipsis are placed here from those same metrics, so a
//  line is drawn where layout made room for it. The face is the file
//  `FontRegistry` resolved, loaded into Skia from the same path.
//

import NucleantSkia

@MainActor
public final class SkiaDisplayRenderer {

    /// The canvas to draw into, asked for on every render: a node's surface
    /// is replaced when the node is resized.
    private let target: () -> SkCanvas?

    /// Layout runs in points; the canvas is sized in backing-store pixels.
    public var scale: Double = 1

    public init(node: SkiaShaderNode<NucleantRenderNode>) {
        target = { node.canvas.surface?.canvas }
        setUpPaints()
    }

    /// Drawing into a CPU surface — what the tests read pixels back from.
    init(surface: SkRasterSurface) {
        target = { surface.getCanvas() }
        setUpPaints()
    }

    private func setUpPaints() {
        fillPaint.setStyle(.fill)
        strokePaint.setStyle(.stroke)
    }

    /// One of each, set per command rather than made per command — each is
    /// a Swift object over a C++ heap one.
    private let fillPaint = SkPaint()
    private let strokePaint = SkPaint()
    private let textPaint = SkPaint()
    private let imagePaint = SkPaint()
    private let path = SkPath()

    /// Fonts by face, size and synthetic slant — what text draws with.
    private struct FontKey: Hashable {
        let family: String?
        let size: Double
        let slanted: Bool
    }
    private var fonts: [FontKey: SkFont] = [:]

    /// Images drawn by the last render, by the `RasterImage` they were made
    /// from. The source is held with its image, so its identifier stays its
    /// own; whatever a render does not draw is dropped after it.
    private var images: [ObjectIdentifier: (source: RasterImage, image: SkImage)] = [:]
    private var imagesDrawn: Set<ObjectIdentifier> = []

    /// Replace the canvas contents with `list`.
    public func render(_ list: DisplayList) {
        guard let canvas = begin() else { return }
        canvas.save()
        canvas.scale(Float(scale))
        emit(list, on: canvas)
        canvas.restore()
        end()
    }

    /// Replace the canvas contents with `list` drawn as a layer: shifted so
    /// `origin` (points) lands at the canvas corner, and flipped so y runs
    /// upwards over a canvas `flipHeight` pixels tall — the space a
    /// `.shader` effect samples it in.
    func render(_ list: DisplayList, origin: Point?, flipHeight: Int) {
        guard let origin else {
            render(list)
            return
        }
        guard let canvas = begin() else { return }
        canvas.save()
        // Pixel space, before `scale`: translate by the origin, then
        // y' = height - y.
        canvas.concat(SkMatrix(
            scaleX: 1, skewX: 0, transX: Float(-origin.x * scale),
            skewY: 0, scaleY: -1, transY: Float(Double(flipHeight) + origin.y * scale)
        ))
        canvas.scale(Float(scale))
        emit(list, on: canvas)
        canvas.restore()
        end()
    }

    /// Replace the canvas contents with several lists side by side, each at
    /// its own pixel offset — the painter's batch, copied out region by
    /// region into the per-view images.
    func render(packed items: [(list: DisplayList, x: Int, y: Int)]) {
        guard let canvas = begin() else { return }
        for item in items {
            canvas.save()
            canvas.translate(dx: Float(item.x), dy: Float(item.y))
            canvas.scale(Float(scale))
            emit(item.list, on: canvas)
            canvas.restore()
        }
        end()
    }

    /// The canvas, emptied, with no transform or clip left over.
    private func begin() -> SkCanvas? {
        guard let canvas = target() else { return nil }
        canvas.restoreToCount(1)
        canvas.resetMatrix()
        canvas.clear(SIMD4<Float>(0, 0, 0, 0))
        imagesDrawn.removeAll(keepingCapacity: true)
        return canvas
    }

    /// Drop the images this render did not draw — usually none.
    private func end() {
        guard images.count > imagesDrawn.count else { return }
        for key in Array(images.keys) where !imagesDrawn.contains(key) {
            images[key] = nil
        }
    }

    private func emit(_ list: DisplayList, on canvas: SkCanvas) {
        for command in list.commands {
            switch command {
            case .shape(let draw):
                emit(draw, on: canvas)
            case .text(let draw):
                emit(draw, on: canvas)
            case .image(let draw):
                emit(draw, on: canvas)
            }
        }
    }

    // MARK: - Shapes

    private func emit(_ draw: ShapeDraw, on canvas: SkCanvas) {
        let fill = draw.fill.flatMap { $0.isClear ? nil : $0 }
        let stroke = draw.stroke.flatMap { $0.isClear || draw.strokeStyle.lineWidth <= 0 ? nil : $0 }
        guard fill != nil || stroke != nil else { return }

        path.reset()
        append(draw.path, to: path)

        canvas.save()
        begin(on: canvas, transform: draw.transform, clip: draw.clip, cornerRadius: draw.clipCornerRadius)

        if let fill {
            apply(fill, to: fillPaint, bounds: draw.bounds)
            canvas.drawPath(path, paint: fillPaint)
        }
        if let stroke {
            let style = draw.strokeStyle
            let paint = strokePaint
            paint.setStrokeWidth(style.lineWidth)
            paint.setStrokeCap(skiaCap(style.lineCap))
            paint.setStrokeJoin(skiaJoin(style.lineJoin))
            if style.dash.isEmpty {
                paint.clearPathEffect()
            } else {
                // Skia wants on/off pairs; an odd pattern repeats to make them.
                var intervals = style.dash.map { Float($0) }
                if intervals.count % 2 == 1 { intervals += intervals }
                if let dash = SkDashPathEffect.make(intervals: intervals, phase: Float(style.dashPhase)) {
                    paint.setPathEffect(dash)
                } else {
                    paint.clearPathEffect()
                }
            }
            apply(stroke, to: paint, bounds: draw.bounds)
            canvas.drawPath(path, paint: paint)
        }

        canvas.restore()
    }

    private func append(_ path: Path, to skPath: SkPath) {
        for element in path.elements {
            switch element {
            case .move(let point):
                skPath.moveTo(SIMD2(point.x, point.y))
            case .line(let point):
                skPath.lineTo(SIMD2(point.x, point.y))
            case .cubic(let c1, let c2, let end):
                skPath.cubicTo(SIMD2(c1.x, c1.y), SIMD2(c2.x, c2.y), SIMD2(end.x, end.y))
            case .close:
                skPath.close()
            case .rect(let rect, let radiusX, let radiusY):
                let pos = SIMD2(rect.minX, rect.minY)
                let size = SIMD2(rect.width, rect.height)
                if radiusX > 0 || radiusY > 0 {
                    skPath.addRRect(pos: pos, size: size, radius: SIMD2(radiusX, radiusY))
                } else {
                    skPath.addRect(pos: pos, size: size)
                }
            case .ellipse(let center, let radiusX, let radiusY):
                skPath.addOval(
                    pos: SIMD2(center.x - radiusX, center.y - radiusY),
                    size: SIMD2(radiusX * 2, radiusY * 2)
                )
            }
        }
    }

    private func apply(_ style: ShapeStyle, to paint: SkPaint, bounds: Rect) {
        switch style {
        case .color(let color):
            let (r, g, b, a) = color.rgba8
            paint.clearShader()
            paint.setColor(SIMD4(r, g, b, a))
        case .linearGradient(let gradient, let startPoint, let endPoint):
            let start = startPoint.resolved(in: bounds)
            let end = endPoint.resolved(in: bounds)
            let (colors, positions) = stops(gradient)
            paint.setColor(SIMD4<UInt8>(0, 0, 0, 255))
            if let shader = SkGradientShader.makeLinear(
                from: SIMD2(Float(start.x), Float(start.y)),
                to: SIMD2(Float(end.x), Float(end.y)),
                colors: colors, positions: positions
            ) {
                paint.setShader(shader)
            } else {
                paint.clearShader()
            }
        case .radialGradient(let gradient, let center, let startRadius, let endRadius):
            let origin = center.resolved(in: bounds)
            let point = SIMD2(Float(origin.x), Float(origin.y))
            let (colors, positions) = stops(gradient)
            paint.setColor(SIMD4<UInt8>(0, 0, 0, 255))
            if let shader = SkGradientShader.makeTwoPointConical(
                start: point, startRadius: Float(startRadius),
                end: point, endRadius: Float(endRadius),
                colors: colors, positions: positions
            ) {
                paint.setShader(shader)
            } else {
                paint.clearShader()
            }
        }
    }

    /// The stops as Skia takes them — through `rgba8`, so a gradient comes
    /// out in the same 8-bit steps the ThorVG renderer hands over.
    private func stops(_ gradient: Gradient) -> (colors: [SIMD4<Float>], positions: [Float]) {
        var colors: [SIMD4<Float>] = []
        var positions: [Float] = []
        for stop in gradient.stops {
            let (r, g, b, a) = stop.color.rgba8
            colors.append(SIMD4<Float>(Float(r), Float(g), Float(b), Float(a)) / 255)
            positions.append(Float(stop.location))
        }
        return (colors, positions)
    }

    // MARK: - Text

    /// ThorVG takes a text size in points at 96 DPI and draws it at
    /// `size × 96/72` user units; `TextMeasurer` measures with ThorVG, so
    /// every text box is sized for that. Skia's size is the em height
    /// itself, so it is given the same factor — the glyphs then fill the
    /// box layout made for them.
    static let thorPointScale = 96.0 / 72.0

    /// Faces loaded into Skia, by the family name `FontRegistry` resolved.
    private static var typefaces: [String: SkTypeface] = [:]
    /// The platform's default face, for a font nothing resolved for.
    private static var defaultTypeface: SkTypeface?

    private func emit(_ draw: TextDraw, on canvas: SkCanvas) {
        guard !draw.string.isEmpty else { return }
        let family = FontRegistry.resolve(draw.font)
        // No italic face found: a synthetic shear still reads as italic.
        let slanted = draw.font.isItalic && !(family?.contains("Italic") ?? false)
        let font = self.font(family: family, size: draw.font.size, slanted: slanted)

        var lines = draw.string.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if draw.wraps, draw.lineLimit != 1 {
            lines = TextMeasurer.wrap(draw.string, font: draw.font, maxWidth: draw.frame.width, lineLimit: draw.lineLimit)
        }
        if let limit = draw.lineLimit, limit > 0, lines.count > limit {
            lines = Array(lines.prefix(limit))
        }
        // Ellipsis only when layout found the string too wide — a box
        // measured to exactly fit its text loses nothing.
        if draw.isTruncated, let first = lines.first {
            lines = [ellipsized(first, toFit: draw.frame.width, font: font)]
        }

        let paint = textPaint
        let (r, g, b, a) = draw.color.rgba8
        paint.setColor(SIMD4(r, g, b, a))

        canvas.save()
        begin(on: canvas, transform: draw.transform, clip: draw.clip, cornerRadius: draw.clipCornerRadius)
        // The first baseline an ascent below the box's top, the rest a line
        // height apart — the metrics layout sized the box with.
        let metrics = TextMeasurer.lineMetrics(for: draw.font)
        let factor = alignFactor(draw.alignment)
        for (index, line) in lines.enumerated() where !line.isEmpty {
            let width = Double(font.measureText(line))
            let x = draw.frame.minX + (draw.frame.width - width) * factor
            let y = draw.frame.minY + metrics.ascent + Double(index) * metrics.lineHeight
            canvas.drawString(line, x: Float(x), y: Float(y), font: font, paint: paint)
        }
        canvas.restore()
    }

    private func font(family: String?, size: Double, slanted: Bool) -> SkFont {
        let key = FontKey(family: family, size: size, slanted: slanted)
        if let font = fonts[key] { return font }
        let font = SkFont(typeface(for: family), size: Float(size * Self.thorPointScale))
        font.setSubpixel(true)
        font.setEdging(.antiAlias)
        if slanted { font.setSkewX(-0.2) }
        fonts[key] = font
        return font
    }

    private func typeface(for family: String?) -> SkTypeface? {
        if let family {
            if let loaded = Self.typefaces[family] { return loaded }
            if let path = FontRegistry.path(ofResolved: family), let made = SkFontMgr.makeFromFile(path) {
                Self.typefaces[family] = made
                return made
            }
        }
        if Self.defaultTypeface == nil {
            Self.defaultTypeface = SkFontMgr.matchFamilyStyle(nil)
        }
        return Self.defaultTypeface
    }

    /// `line` cut short with a trailing "…" until it fits `width`.
    private func ellipsized(_ line: String, toFit width: Double, font: SkFont) -> String {
        guard Double(font.measureText(line)) > width else { return line }
        var characters = Array(line)
        while !characters.isEmpty {
            characters.removeLast()
            while characters.last == " " { characters.removeLast() }
            let candidate = String(characters) + "…"
            if Double(font.measureText(candidate)) <= width { return candidate }
        }
        return "…"
    }

    private func alignFactor(_ alignment: TextAlignment) -> Double {
        switch alignment {
        case .leading:  return 0
        case .center:   return 0.5
        case .trailing: return 1
        }
    }

    // MARK: - Images

    private func emit(_ draw: ImageDraw, on canvas: SkCanvas) {
        guard draw.frame.width > 0, draw.frame.height > 0, let image = skImage(for: draw.image) else { return }
        let paint = imagePaint
        paint.setAlphaf(max(0, min(1, draw.opacity)))
        canvas.save()
        begin(on: canvas, transform: draw.transform, clip: draw.clip, cornerRadius: draw.clipCornerRadius)
        canvas.drawImageRect(
            image,
            pos: SIMD2(Float(draw.frame.minX), Float(draw.frame.minY)),
            size: SIMD2(Float(draw.frame.width), Float(draw.frame.height)),
            paint: paint
        )
        canvas.restore()
    }

    /// `RasterImage`'s pixels are premultiplied ARGB words — BGRA bytes on a
    /// little-endian machine, which is Skia's `bgra8888`.
    private func skImage(for raster: RasterImage) -> SkImage? {
        let key = ObjectIdentifier(raster)
        imagesDrawn.insert(key)
        if let cached = images[key] { return cached.image }
        guard let made = SkImages.rasterFromPixmapCopy(
            raster.pixels,
            size: SIMD2(Int32(raster.width), Int32(raster.height))
        ) else { return nil }
        images[key] = (raster, made)
        return made
    }

    // MARK: - Shared head

    /// Clip first, in the canvas's space, then the command's own transform —
    /// the clip does not move with what it clips. The caller saves and
    /// restores around it.
    private func begin(on canvas: SkCanvas, transform: Transform, clip: Rect?, cornerRadius: Double) {
        if let clip {
            // `.clipShape(Capsule())` asks for an unbounded radius, meaning
            // "as round as this box allows" — resolvable only here.
            let radius = min(cornerRadius, min(clip.width, clip.height) / 2)
            let pos = SIMD2(clip.minX, clip.minY)
            let size = SIMD2(clip.width, clip.height)
            if radius > 0 {
                canvas.clipRRect(pos: pos, size: size, radius: SIMD2(radius, radius), doAntiAlias: true)
            } else {
                canvas.clipRect(pos: pos, size: size, doAntiAlias: true)
            }
        }
        if !transform.isIdentity {
            canvas.concat(SkMatrix(
                scaleX: Float(transform.e11), skewX: Float(transform.e12), transX: Float(transform.e13),
                skewY: Float(transform.e21), scaleY: Float(transform.e22), transY: Float(transform.e23)
            ))
        }
    }

    private func skiaCap(_ cap: LineCap) -> SkStrokeCap {
        switch cap {
        case .butt:   return .butt
        case .round:  return .round
        case .square: return .square
        }
    }

    private func skiaJoin(_ join: LineJoin) -> SkStrokeJoin {
        switch join {
        case .miter: return .miter
        case .round: return .round
        case .bevel: return .bevel
        }
    }
}
