//
//  SkiaDisplayRendererTests.swift
//  NucleantUITests
//
//  `SkiaDisplayRenderer` drawing display lists into a CPU surface, read
//  back pixel by pixel.
//

import Testing
import NucleantSkia
@testable import NucleantUI

@MainActor
@Suite
struct SkiaDisplayRendererTests {

    let surface = SkSurfaces.raster(width: 100, height: 100)!

    private func renderer(scale: Double = 1) -> SkiaDisplayRenderer {
        let renderer = SkiaDisplayRenderer(surface: surface)
        renderer.scale = scale
        return renderer
    }

    private func pixel(_ x: Int, _ y: Int) -> SIMD4<UInt8> {
        surface.readPixel(x: x, y: y) ?? SIMD4(0, 0, 0, 0)
    }

    private func rect(
        _ frame: Rect,
        fill: ShapeStyle? = .color(.init(red: 1, green: 0, blue: 0)),
        stroke: ShapeStyle? = nil,
        lineWidth: Double = 1,
        transform: Transform = .identity,
        clip: Rect? = nil,
        clipCornerRadius: Double = 0
    ) -> DrawCommand {
        var path = Path()
        path.addRect(frame)
        return .shape(ShapeDraw(
            path: path,
            bounds: frame,
            fill: fill,
            stroke: stroke,
            strokeStyle: StrokeStyle(lineWidth: lineWidth),
            transform: transform,
            clip: clip,
            clipCornerRadius: clipCornerRadius
        ))
    }

    private func list(_ commands: DrawCommand...) -> DisplayList {
        var list = DisplayList()
        for command in commands { list.append(command) }
        return list
    }

    /// Columns holding any ink in rows `rows`.
    private func inkColumns(rows: Range<Int>) -> [Int] {
        (0..<100).filter { x in rows.contains { pixel(x, $0).w > 0 } }
    }

    @Test func fillsARect() {
        renderer().render(list(rect(Rect(x: 10, y: 10, width: 20, height: 20))))
        #expect(pixel(20, 20) == SIMD4(255, 0, 0, 255))
        #expect(pixel(5, 5).w == 0)
        #expect(pixel(40, 40).w == 0)
    }

    @Test func scalesPointsToPixels() {
        renderer(scale: 2).render(list(rect(Rect(x: 10, y: 10, width: 20, height: 20))))
        #expect(pixel(50, 50) == SIMD4(255, 0, 0, 255))
        #expect(pixel(15, 15).w == 0)
        #expect(pixel(65, 65).w == 0)
    }

    @Test func renderReplacesWhatWasThere() {
        let renderer = renderer()
        renderer.render(list(rect(Rect(x: 0, y: 0, width: 50, height: 50))))
        #expect(pixel(25, 25).w == 255)
        renderer.render(DisplayList())
        #expect(pixel(25, 25).w == 0)
    }

    @Test func clipsToTheCommandsClip() {
        renderer().render(list(rect(Rect(x: 0, y: 0, width: 100, height: 100), clip: Rect(x: 0, y: 0, width: 50, height: 50))))
        #expect(pixel(25, 25).w == 255)
        #expect(pixel(75, 75).w == 0)
    }

    @Test func roundedClipCutsTheCorners() {
        renderer().render(list(rect(
            Rect(x: 0, y: 0, width: 100, height: 100),
            clip: Rect(x: 10, y: 10, width: 80, height: 80),
            clipCornerRadius: .infinity
        )))
        // As round as the box allows: a circle.
        #expect(pixel(50, 50).w == 255)
        #expect(pixel(13, 13).w == 0)
    }

    @Test func clipDoesNotMoveWithTheTransform() {
        // Drawn 50 to the right, clipped where it was: nothing left.
        renderer().render(list(rect(
            Rect(x: 0, y: 0, width: 40, height: 40),
            transform: .translation(x: 50, y: 0),
            clip: Rect(x: 0, y: 0, width: 40, height: 40)
        )))
        #expect(pixel(20, 20).w == 0)
        #expect(pixel(70, 20).w == 0)
    }

    @Test func appliesTheTransform() {
        renderer().render(list(rect(Rect(x: 0, y: 0, width: 10, height: 10), transform: .translation(x: 50, y: 50))))
        #expect(pixel(55, 55).w == 255)
        #expect(pixel(5, 5).w == 0)
    }

    @Test func strokesWithoutFilling() {
        renderer().render(list(rect(
            Rect(x: 20, y: 20, width: 60, height: 60),
            fill: nil,
            stroke: .color(.init(red: 0, green: 0, blue: 1)),
            lineWidth: 4
        )))
        #expect(pixel(20, 50) == SIMD4(0, 0, 255, 255))
        #expect(pixel(50, 50).w == 0)
    }

    @Test func linearGradientRunsAcrossTheBounds() {
        let gradient = Gradient(colors: [.init(red: 1, green: 0, blue: 0), .init(red: 0, green: 0, blue: 1)])
        renderer().render(list(rect(
            Rect(x: 0, y: 0, width: 100, height: 100),
            fill: .linearGradient(gradient, startPoint: .leading, endPoint: .trailing)
        )))
        let left = pixel(2, 50), right = pixel(97, 50)
        #expect(left.x > 240 && left.z < 15)
        #expect(right.z > 240 && right.x < 15)
    }

    @Test func drawsARasterImage() {
        // Premultiplied ARGB words: opaque green.
        let image = RasterImage(width: 2, height: 2, pixels: Array(repeating: 0xFF00_FF00, count: 4))
        renderer().render(list(.image(ImageDraw(image: image, frame: Rect(x: 10, y: 10, width: 20, height: 20)))))
        #expect(pixel(20, 20) == SIMD4(0, 255, 0, 255))
        #expect(pixel(40, 40).w == 0)
    }

    @Test func imageOpacityFades() {
        let image = RasterImage(width: 1, height: 1, pixels: [0xFF00_FF00])
        renderer().render(list(.image(ImageDraw(image: image, frame: Rect(x: 0, y: 0, width: 50, height: 50), opacity: 0.5))))
        let alpha = Int(pixel(25, 25).w)
        #expect(abs(alpha - 128) <= 2)
    }

    @Test func drawsTextInsideItsFrame() {
        let font = Font.system(size: 20)
        renderer().render(list(.text(TextDraw(
            string: "Hello",
            frame: Rect(x: 10, y: 10, width: 80, height: 30),
            font: font,
            color: .init(red: 0, green: 0, blue: 0)
        ))))
        let columns = inkColumns(rows: 10..<40)
        #expect(!columns.isEmpty)
        #expect(columns.allSatisfy { (10..<90).contains($0) })
        // Nothing drawn above the frame.
        #expect((0..<100).allSatisfy { pixel($0, 5).w == 0 })
    }

    @Test func alignsTextWithinItsFrame() {
        func firstInk(_ alignment: TextAlignment) -> Int? {
            renderer().render(list(.text(TextDraw(
                string: "Hi",
                frame: Rect(x: 0, y: 0, width: 100, height: 30),
                font: .system(size: 20),
                color: .init(red: 0, green: 0, blue: 0),
                alignment: alignment
            ))))
            return inkColumns(rows: 0..<30).first
        }
        let leading = firstInk(.leading), center = firstInk(.center), trailing = firstInk(.trailing)
        #expect(leading != nil && center != nil && trailing != nil)
        if let leading, let center, let trailing {
            #expect(leading < center && center < trailing)
        }
    }

    @Test func truncatedTextStaysInsideItsFrame() {
        renderer().render(list(.text(TextDraw(
            string: "A label far too long for this box",
            frame: Rect(x: 0, y: 0, width: 60, height: 30),
            font: .system(size: 20),
            color: .init(red: 0, green: 0, blue: 0),
            lineLimit: 1,
            isTruncated: true
        ))))
        let columns = inkColumns(rows: 0..<30)
        #expect(!columns.isEmpty)
        #expect(columns.allSatisfy { $0 < 61 })
    }

    @Test func linesAreALineHeightApart() {
        let font = Font.system(size: 16)
        let lineHeight = TextMeasurer.lineMetrics(for: font).lineHeight
        renderer().render(list(.text(TextDraw(
            string: "one\ntwo",
            frame: Rect(x: 0, y: 0, width: 100, height: lineHeight * 2),
            font: font,
            color: .init(red: 0, green: 0, blue: 0)
        ))))
        let first = Int(lineHeight)
        #expect(inkColumns(rows: 0..<first).count > 0)
        #expect(inkColumns(rows: first..<min(100, Int(lineHeight * 2) + 1)).count > 0)
    }

    @Test func packsListsAtTheirOffsets() {
        let square = list(rect(Rect(x: 0, y: 0, width: 10, height: 10)))
        renderer().render(packed: [(square, 0, 0), (square, 50, 60)])
        #expect(pixel(5, 5).w == 255)
        #expect(pixel(55, 65).w == 255)
        #expect(pixel(30, 30).w == 0)
    }

    @Test func layerPutsTheOriginAtTheCornerAndFlips() {
        // A 10 × 10 rect at (10, 10) drawn from origin (10, 10): the corner
        // of the canvas, and y running up — the bottom-left.
        renderer().render(list(rect(Rect(x: 10, y: 10, width: 10, height: 10))), origin: Point(x: 10, y: 10), flipHeight: 100)
        #expect(pixel(5, 95).w == 255)
        #expect(pixel(5, 5).w == 0)
    }
}
