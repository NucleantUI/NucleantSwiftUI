//
//  PathContainment.swift
//  NucleantUI
//
//  Whether a point is inside a `Path` — what `.contentShape` hit tests
//  with. Curves are flattened into short lines; rects and ellipses are
//  tested exactly.
//

extension Path {

    /// Whether `point` lies inside the area this path fills: nonzero
    /// winding, or even-odd with `eoFill`. An open subpath counts as closed,
    /// as it does when filled.
    func contains(_ point: Point, eoFill: Bool = false) -> Bool {
        var winding = 0
        var start: Point?
        var current: Point?

        // The signed crossing of a ray from `point` towards +x — the
        // standard winding-number edge test.
        func edge(_ a: Point, _ b: Point) {
            let side = (b.x - a.x) * (point.y - a.y) - (point.x - a.x) * (b.y - a.y)
            if a.y <= point.y {
                if b.y > point.y, side > 0 { winding += 1 }
            } else if b.y <= point.y, side < 0 {
                winding -= 1
            }
        }

        func closeSubpath() {
            if let from = current, let to = start, from != to { edge(from, to) }
            current = start
        }

        for element in elements {
            switch element {
            case .move(let p):
                closeSubpath()
                start = p
                current = p
            case .line(let p):
                if let from = current {
                    edge(from, p)
                } else {
                    start = p
                }
                current = p
            case .cubic(let c1, let c2, let end):
                guard let from = current else {
                    start = end
                    current = end
                    continue
                }
                let steps = 16
                var previous = from
                for step in 1...steps {
                    let t = Double(step) / Double(steps)
                    let u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    let next = Point(
                        x: a * from.x + b * c1.x + c * c2.x + d * end.x,
                        y: a * from.y + b * c1.y + c * c2.y + d * end.y
                    )
                    edge(previous, next)
                    previous = next
                }
                current = end
            case .close:
                closeSubpath()
            case .rect(let rect, let rx, let ry):
                if Self.roundedRect(rect, radiusX: rx, radiusY: ry, contains: point) { winding += 1 }
            case .ellipse(let center, let rx, let ry):
                guard rx > 0, ry > 0 else { continue }
                let dx = (point.x - center.x) / rx
                let dy = (point.y - center.y) / ry
                if dx * dx + dy * dy <= 1 { winding += 1 }
            }
        }
        closeSubpath()
        return eoFill ? winding & 1 != 0 : winding != 0
    }

    private static func roundedRect(_ rect: Rect, radiusX: Double, radiusY: Double, contains point: Point) -> Bool {
        guard rect.contains(point) else { return false }
        let rx = min(max(radiusX, 0), rect.width / 2)
        let ry = min(max(radiusY, 0), rect.height / 2)
        guard rx > 0, ry > 0 else { return true }
        // Only the four corner squares can be outside; there, test against
        // the corner's ellipse.
        let cx = point.x < rect.minX + rx ? rect.minX + rx : (point.x > rect.maxX - rx ? rect.maxX - rx : point.x)
        let cy = point.y < rect.minY + ry ? rect.minY + ry : (point.y > rect.maxY - ry ? rect.maxY - ry : point.y)
        let dx = (point.x - cx) / rx
        let dy = (point.y - cy) / ry
        return dx * dx + dy * dy <= 1
    }
}
