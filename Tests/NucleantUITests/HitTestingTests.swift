//
//  HitTestingTests.swift
//  NucleantUITests
//
//  `.allowsHitTesting(_:)`, `.contentShape(_:)` and the path containment
//  under it.
//

import Testing
@testable import NucleantUI

@View
struct OverlayWithoutHitTesting {
    let log: Log

    var body: some View {
        Color.gray
            .onTapGesture { log("under") }
            .overlay(Color.red.onTapGesture { log("over") }.allowsHitTesting(false))
    }
}

@View
struct ContentWithoutHitTesting {
    let log: Log

    var body: some View {
        Color.gray.allowsHitTesting(false).onTapGesture { log("tap") }
    }
}

@View
struct RoundTarget {
    let log: Log

    var body: some View {
        Color.red
            .contentShape(Circle())
            .onTapGesture { log("round") }
    }
}

/// Two overlapping circles: the corner of the front one is the back one's.
@View
struct OverlappingRoundTargets {
    let log: Log

    var body: some View {
        HStack(spacing: -40) {
            Color.red.frame(width: 100, height: 100)
                .contentShape(Circle())
                .onTapGesture { log("left") }
            Color.blue.frame(width: 100, height: 100)
                .contentShape(Circle())
                .onTapGesture { log("right") }
        }
        .frame(width: 160, height: 100)
    }
}

extension HostedViews {
    @MainActor
    @Suite
    struct HitTestingTests {

        @Test func overlayWithoutHitTestingLetsTheTapThrough() async {
            let log = Log()
            let harness = Harness(OverlayWithoutHitTesting(log: log))
            await harness.tap(center)
            #expect(log.take() == ["under"])
        }

        @Test func contentWithoutHitTestingIsNotTapped() async {
            let log = Log()
            let harness = Harness(ContentWithoutHitTesting(log: log))
            await harness.tap(center)
            #expect(log.take() == [])
        }

        @Test func contentShapeLimitsTheTargetToTheShape() async {
            let log = Log()
            let harness = Harness(RoundTarget(log: log))
            await harness.tap(Point(x: 3, y: 3))
            #expect(log.take() == [], "a corner is outside the circle")
            await harness.tap(center)
            #expect(log.take() == ["round"])
        }

        @Test func pressOutsideAShapeReachesTheViewBehind() async {
            let log = Log()
            // 200×200 window, the 160-wide pair centred: left circle spans
            // x 20…120, right circle 80…180.
            let harness = Harness(OverlappingRoundTargets(log: log))
            // Inside the right one's square (x 80…180, y 50…150) but outside
            // its circle (centre 130,100), inside the left circle (centre 70,100).
            await harness.tap(Point(x: 82, y: 55))
            #expect(log.take() == ["left"])
            await harness.tap(Point(x: 150, y: 100))
            #expect(log.take() == ["right"])
        }

        @Test func pathContainment() {
            let rect = Rect(x: 0, y: 0, width: 100, height: 100)

            var ellipse = Path()
            ellipse.addEllipse(in: rect)
            #expect(ellipse.contains(Point(x: 50, y: 50)))
            #expect(!ellipse.contains(Point(x: 5, y: 5)))

            var rounded = Path()
            rounded.addRoundedRect(rect, radiusX: 20, radiusY: 20)
            #expect(rounded.contains(Point(x: 10, y: 50)))
            #expect(!rounded.contains(Point(x: 1, y: 1)))

            var triangle = Path()
            triangle.move(to: Point(x: 0, y: 0))
            triangle.addLine(to: Point(x: 100, y: 0))
            triangle.addLine(to: Point(x: 0, y: 100))
            #expect(triangle.contains(Point(x: 20, y: 20)), "an open subpath fills as if closed")
            #expect(!triangle.contains(Point(x: 80, y: 80)))

            var curve = Path()
            curve.move(to: Point(x: 0, y: 100))
            curve.addCurve(to: Point(x: 100, y: 100), control1: Point(x: 0, y: 0), control2: Point(x: 100, y: 0))
            curve.closeSubpath()
            #expect(curve.contains(Point(x: 50, y: 60)))
            #expect(!curve.contains(Point(x: 50, y: 10)))
        }

        @Test func evenOddLeavesTheHoleOut() {
            var ring = Path()
            ring.addEllipse(in: Rect(x: 0, y: 0, width: 100, height: 100))
            ring.addEllipse(in: Rect(x: 25, y: 25, width: 50, height: 50))
            #expect(ring.contains(Point(x: 50, y: 50)))
            #expect(!ring.contains(Point(x: 50, y: 50), eoFill: true))
            #expect(ring.contains(Point(x: 10, y: 50), eoFill: true))
        }
    }
}
