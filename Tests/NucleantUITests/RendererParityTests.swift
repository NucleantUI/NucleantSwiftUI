//
//  RendererParityTests.swift
//  NucleantUITests
//
//  The same display list through `ThorDisplayRenderer` (into a ThorVG
//  software canvas) and `SkiaDisplayRenderer` (into a Skia CPU surface):
//  what each draws should land in the same place, so switching the main
//  renderer moves nothing on screen.
//

import Testing
import NucleantThorVG
import NucleantSkia
@testable import NucleantUI

@MainActor
@Suite
struct RendererParityTests {

    static let width = 200, height = 80

    /// The box holding every pixel with any coverage: (minX, minY, maxX, maxY).
    typealias Ink = (minX: Int, minY: Int, maxX: Int, maxY: Int)

    private func ink(width: Int, height: Int, alpha: (Int, Int) -> Int) -> Ink? {
        var box: Ink?
        for y in 0..<height {
            for x in 0..<width where alpha(x, y) > 40 {
                if let b = box {
                    box = (min(b.minX, x), min(b.minY, y), max(b.maxX, x), max(b.maxY, y))
                } else {
                    box = (x, y, x, y)
                }
            }
        }
        return box
    }

    private func thorInk(_ list: DisplayList, scale: Double) -> Ink? {
        ThorEngine.ensureInitialized()
        let (w, h) = (Self.width, Self.height)
        var buffer = [UInt32](repeating: 0, count: w * h)
        guard let canvas = tvg_swcanvas_create(TVG_ENGINE_OPTION_DEFAULT) else { return nil }
        defer { _ = tvg_canvas_destroy(canvas) }
        let drawn = buffer.withUnsafeMutableBufferPointer { pixels -> Bool in
            guard tvg_swcanvas_set_target(canvas, pixels.baseAddress, UInt32(w), UInt32(w), UInt32(h), TVG_COLORSPACE_ARGB8888) == TVG_RESULT_SUCCESS
            else { return false }
            let renderer = ThorDisplayRenderer(canvas: canvas)
            renderer.scale = scale
            renderer.render(list)
            _ = tvg_canvas_update(canvas)
            _ = tvg_canvas_draw(canvas, true)
            _ = tvg_canvas_sync(canvas)
            return true
        }
        guard drawn else { return nil }
        return ink(width: w, height: h) { x, y in Int(buffer[y * w + x] >> 24) }
    }

    private func skiaInk(_ list: DisplayList, scale: Double) -> Ink? {
        let surface = SkSurfaces.raster(width: Int32(Self.width), height: Int32(Self.height))!
        let renderer = SkiaDisplayRenderer(surface: surface)
        renderer.scale = scale
        renderer.render(list)
        let pixels = surface.readPixels()
        return ink(width: Self.width, height: Self.height) { x, y in Int(pixels[(y * Self.width + x) * 4 + 3]) }
    }

    private func text(
        _ string: String,
        frame: Rect,
        size: Double = 17,
        alignment: TextAlignment = .leading
    ) -> DisplayList {
        var list = DisplayList()
        list.append(.text(TextDraw(
            string: string,
            frame: frame,
            font: .system(size: size),
            color: .init(red: 0, green: 0, blue: 0),
            alignment: alignment,
            wraps: false
        )))
        return list
    }

    /// A label laid out the way `TextContent` does: its frame is the size
    /// the measurer gave it.
    private func label(_ string: String, at origin: Point, size: Double = 17, alignment: TextAlignment = .leading, width: Double? = nil) -> DisplayList {
        let font = Font.system(size: size)
        let measured = TextMeasurer.size(of: string, font: font, proposal: ProposedSize(width: nil, height: nil), lineLimit: nil)
        return text(string, frame: Rect(x: origin.x, y: origin.y, width: width ?? measured.width, height: measured.height), size: size, alignment: alignment)
    }

    private func expectSamePlace(_ list: DisplayList, scale: Double = 1, tolerance: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) {
        let thor = thorInk(list, scale: scale)
        let skia = skiaInk(list, scale: scale)
        guard let thor, let skia else {
            Issue.record("nothing drawn — thor \(String(describing: thor)), skia \(String(describing: skia))", sourceLocation: sourceLocation)
            return
        }
        #expect(abs(thor.minX - skia.minX) <= tolerance, "minX thor \(thor.minX) skia \(skia.minX)", sourceLocation: sourceLocation)
        #expect(abs(thor.maxX - skia.maxX) <= tolerance, "maxX thor \(thor.maxX) skia \(skia.maxX)", sourceLocation: sourceLocation)
        #expect(abs(thor.minY - skia.minY) <= tolerance, "minY thor \(thor.minY) skia \(skia.minY)", sourceLocation: sourceLocation)
        #expect(abs(thor.maxY - skia.maxY) <= tolerance, "maxY thor \(thor.maxY) skia \(skia.maxY)", sourceLocation: sourceLocation)
    }

    @Test func leadingLabel() {
        expectSamePlace(label("Hide mixer", at: Point(x: 10, y: 10)))
    }

    @Test func labelWithDescenders() {
        expectSamePlace(label("Tracks gjpqy", at: Point(x: 10, y: 10)))
    }

    @Test func centeredLabel() {
        expectSamePlace(label("Reset", at: Point(x: 0, y: 10), alignment: .center, width: 200))
    }

    @Test func trailingLabel() {
        expectSamePlace(label("Reset", at: Point(x: 0, y: 10), alignment: .trailing, width: 190))
    }

    @Test func labelAtRetinaScale() {
        expectSamePlace(label("Shaders", at: Point(x: 5, y: 5), size: 13), scale: 2)
    }

    @Test func smallLabel() {
        expectSamePlace(label("82%", at: Point(x: 10, y: 10), size: 12))
    }
}
