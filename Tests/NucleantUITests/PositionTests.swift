//
//  PositionTests.swift
//  NucleantUITests
//
//  `.position(x:y:)`: where the view inside lands, and how much room the
//  positioned view takes from its parent.
//

import Testing
@testable import NucleantUI

/// A 20 × 20 target with its center at `point`.
@View
struct PositionedTarget {
    let log: Log
    let point: Point

    var body: some View {
        Color.red
            .frame(width: 20, height: 20)
            .onTapGesture { log("target") }
            .position(point)
    }
}

/// Padding outside the modifier moves the space the point is measured in.
@View
struct PaddedPosition {
    let log: Log

    var body: some View {
        Color.red
            .frame(width: 20, height: 20)
            .onTapGesture { log("target") }
            .position(x: 20, y: 20)
            .padding(50)
    }
}

/// A positioned view in a stack takes the room the fixed rows leave.
@View
struct PositionInStack {
    let log: Log

    var body: some View {
        VStack(spacing: 0) {
            Color.red
                .frame(width: 20, height: 20)
                .onTapGesture { log("target") }
                .position(x: 100, y: 10)
            Color.gray
                .frame(height: 50)
                .onTapGesture { log("footer") }
        }
    }
}

/// Each tap moves the target to the opposite corner.
@View
struct MovingTarget {
    let log: Log
    @State private var isAtStart = true

    var body: some View {
        Color.red
            .frame(width: 20, height: 20)
            .onTapGesture {
                log(isAtStart ? "start" : "end")
                isAtStart.toggle()
            }
            .position(isAtStart ? Point(x: 30, y: 30) : Point(x: 170, y: 170))
    }
}

extension HostedViews {
    @MainActor
    @Suite
    struct PositionTests {

        @Test func centerLandsOnThePoint() async {
            let log = Log()
            let harness = Harness(PositionedTarget(log: log, point: Point(x: 150, y: 50)))
            await harness.tap(Point(x: 150, y: 50))
            await harness.tap(Point(x: 141, y: 41))
            await harness.tap(Point(x: 159, y: 59))
            #expect(log.take() == ["target", "target", "target"])
        }

        @Test func nothingOutsideTheViewIsHit() async {
            let log = Log()
            let harness = Harness(PositionedTarget(log: log, point: Point(x: 150, y: 50)))
            await harness.tap(center)
            await harness.tap(Point(x: 139, y: 50))
            await harness.tap(Point(x: 150, y: 61))
            #expect(log.take() == [])
        }

        @Test func xAndYDefaultToTheOrigin() async {
            let log = Log()
            let harness = Harness(PositionedTarget(log: log, point: Point()))
            await harness.tap(Point(x: 5, y: 5))
            await harness.tap(Point(x: 15, y: 15))
            #expect(log.take() == ["target"])
        }

        @Test func pointIsInTheParentsSpace() async {
            let log = Log()
            let harness = Harness(PaddedPosition(log: log))
            await harness.tap(Point(x: 20, y: 20))
            #expect(log.take() == [])
            await harness.tap(Point(x: 70, y: 70))
            #expect(log.take() == ["target"])
        }

        @Test func takesTheRoomTheStackLeaves() async {
            let log = Log()
            let harness = Harness(PositionInStack(log: log))
            // The footer keeps its 50 at the bottom; the positioned view has
            // the 150 above it, and its target sits at the top of that.
            await harness.tap(Point(x: 100, y: 10))
            await harness.tap(Point(x: 100, y: 175))
            await harness.tap(Point(x: 100, y: 140))
            #expect(log.take() == ["target", "footer"])
        }

        @Test func movesWhenThePointChanges() async {
            let log = Log()
            let harness = Harness(MovingTarget(log: log))
            await harness.tap(Point(x: 30, y: 30))
            await harness.tap(Point(x: 30, y: 30))
            await harness.tap(Point(x: 170, y: 170))
            #expect(log.take() == ["start", "end"])
        }
    }
}
