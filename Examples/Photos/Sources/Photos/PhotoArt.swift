//
//  PhotoArt.swift
//  Photos
//
//  A photo's picture — its `Scenery` as sky, sun and two ranges of hills —
//  and the tile the grids show it in.
//

import NucleantUI

/// A scenery drawn to fill whatever frame it is given.
@View
struct PhotoArt {
    let scenery: Scenery

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.linearGradient(colors: [scenery.skyTop, scenery.skyBottom]))
            Sun(position: scenery.sunPosition)
                .fill(scenery.sun)
            Ridge(heights: scenery.farRidge)
                .fill(scenery.farHills)
            Ridge(heights: scenery.nearRidge)
                .fill(scenery.nearHills)
        }
        .clipped()
    }
}

/// A disc a tenth of the picture's shorter side across, at `position`.
@View
struct Sun: Shape {
    let position: UnitPoint

    func path(in rect: Rect) -> Path {
        let radius = min(rect.width, rect.height) * 0.1
        let center = position.resolved(in: rect)
        var path = Path()
        path.addEllipse(in: Rect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        return path
    }
}

/// Hills through `heights` (fractions of the height, from the top), left
/// to right, smoothed, filled down to the bottom edge.
@View
struct Ridge: Shape {
    let heights: [Double]

    func path(in rect: Rect) -> Path {
        var path = Path()
        guard heights.count > 1 else { return path }
        let step = rect.width / Double(heights.count - 1)
        func point(_ index: Int) -> Point {
            Point(x: rect.minX + step * Double(index), y: rect.minY + rect.height * heights[index])
        }
        path.move(to: Point(x: rect.minX, y: rect.maxY))
        path.addLine(to: point(0))
        for index in 1..<heights.count {
            let from = point(index - 1)
            let to = point(index)
            path.addCurve(
                to: to,
                control1: Point(x: from.x + step / 2, y: from.y),
                control2: Point(x: to.x - step / 2, y: to.y)
            )
        }
        path.addLine(to: Point(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A heart, drawn to fill its frame — the bundled face has no "♥".
@View
struct Heart: Shape {
    func path(in rect: Rect) -> Path {
        let w = rect.width
        let h = rect.height
        let x = rect.minX
        let y = rect.minY
        var path = Path()
        path.move(to: Point(x: x + w * 0.5, y: y + h * 0.95))
        path.addCurve(
            to: Point(x: x, y: y + h * 0.32),
            control1: Point(x: x + w * 0.2, y: y + h * 0.72),
            control2: Point(x: x, y: y + h * 0.55)
        )
        path.addCurve(
            to: Point(x: x + w * 0.5, y: y + h * 0.18),
            control1: Point(x: x, y: y + h * 0.02),
            control2: Point(x: x + w * 0.4, y: y)
        )
        path.addCurve(
            to: Point(x: x + w, y: y + h * 0.32),
            control1: Point(x: x + w * 0.6, y: y),
            control2: Point(x: x + w, y: y + h * 0.02)
        )
        path.addCurve(
            to: Point(x: x + w * 0.5, y: y + h * 0.95),
            control1: Point(x: x + w, y: y + h * 0.55),
            control2: Point(x: x + w * 0.8, y: y + h * 0.72)
        )
        path.closeSubpath()
        return path
    }
}

/// A square thumbnail in a grid: the picture, a heart when it is a
/// favourite, a ring when it is selected. A click selects it.
@View
struct PhotoTile {
    let library: Library
    let photo: Photo
    var cornerRadius: Double = 0

    var body: some View {
        let library = self.library
        let id = photo.id
        let isSelected = library.selectedID == id
        ZStack(alignment: .bottomLeading) {
            PhotoArt(scenery: photo.scenery)
            if library.isFavorite(id) {
                Heart()
                    .fill(Color.white)
                    .frame(width: 11, height: 10)
                    .padding(6)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .cornerRadius(cornerRadius)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Theme.accent, lineWidth: 3)
            }
        }
        .onTapGesture { library.select(isSelected ? nil : id) }
    }
}
