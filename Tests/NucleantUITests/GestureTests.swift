//
//  GestureTests.swift
//  NucleantUITests
//
//  The gestures, and how they compete for a press: `TapGesture`,
//  `LongPressGesture`, `MagnifyGesture`, `RotateGesture`, `DragGesture`
//  through the arena, `.gesture` / `.highPriorityGesture` /
//  `.simultaneousGesture`, and `GestureMask`.
//

import Foundation
import Testing
@testable import NucleantUI

// MARK: - Views

@View
struct DoubleThenSingleTap {
    let log: Log

    var body: some View {
        Color.red
            .onTapGesture(count: 2) { log("double") }
            .onTapGesture { log("single") }
    }
}

@View
struct SingleThenDoubleTap {
    let log: Log

    var body: some View {
        Color.red
            .onTapGesture { log("single") }
            .onTapGesture(count: 2) { log("double") }
    }
}

/// A double tap inside a view with a tap of its own.
@View
struct DoubleTapInsideTap {
    let log: Log
    let innerSingle: Bool

    var body: some View {
        ZStack {
            Color.gray
            if innerSingle {
                Color.red.frame(width: 80, height: 80)
                    .onTapGesture(count: 2) { log("inner double") }
                    .gesture(TapGesture().onEnded { log("inner single") })
            } else {
                Color.red.frame(width: 80, height: 80)
                    .onTapGesture(count: 2) { log("inner double") }
            }
        }
        .gesture(TapGesture().onEnded { log("outer") })
    }
}

@View
struct ButtonInsideTap {
    let log: Log
    let priority: Int

    var body: some View {
        let outer = TapGesture().onEnded { log("outer") }
        let content = VStack { Button("B") { log("button") }.frame(width: 200, height: 200) }
        switch priority {
        case 0: content.gesture(outer)
        case 1: content.highPriorityGesture(outer)
        default: content.simultaneousGesture(outer)
        }
    }
}

@View
struct TapAndHold {
    let log: Log

    var body: some View {
        Color.blue
            .onTapGesture { log("tap") }
            .onLongPressGesture { log("hold") } onPressingChanged: { log("pressing \($0)") }
    }
}

@View
struct DragAroundButton {
    let log: Log
    let simultaneous: Bool

    var body: some View {
        let drag = DragGesture()
            .onChanged { value in log("drag \(Int(value.translation.width))") }
            .onEnded { value in log("end \(Int(value.translation.width))") }
        let content = VStack { Button("B") { log("button") }.frame(width: 200, height: 200) }
        if simultaneous {
            content.simultaneousGesture(drag)
        } else {
            content.gesture(drag, including: .all)
        }
    }
}

@View
struct PinchAndTwist {
    let log: Log

    var body: some View {
        Color.green
            .gesture(
                MagnifyGesture()
                    .onChanged { log(String(format: "mag %.2f", $0.magnification)) }
                    .onEnded { log(String(format: "magEnd %.2f", $0.magnification)) }
            )
            .simultaneousGesture(
                RotateGesture()
                    .onChanged { log(String(format: "rot %.0f", $0.rotation.degrees)) }
                    .onEnded { log(String(format: "rotEnd %.0f", $0.rotation.degrees)) }
            )
    }
}

@View
struct NestedPinch {
    let log: Log

    var body: some View {
        ZStack {
            Color.gray
            Color.green.frame(width: 100, height: 100)
                .gesture(MagnifyGesture().onChanged { _ in log("inner") })
        }
        .gesture(MagnifyGesture().onChanged { _ in log("outer") })
    }
}

@View
struct MaskedTap {
    let log: Log
    let mask: GestureMask

    var body: some View {
        VStack { Button("B") { log("button") }.frame(width: 200, height: 200) }
            .gesture(TapGesture().onEnded { log("outer") }, including: mask)
    }
}

@View
struct DisabledGesture {
    let log: Log

    var body: some View {
        Color.red
            .gesture(TapGesture().onEnded { log("tap") })
            .disabled(true)
    }
}

/// A drag-only target inside a double tap: a click that never moved is
/// no tap of its own, and must leave the double tap free.
@View
struct DragTargetInsideDoubleTap {
    let log: Log

    var body: some View {
        Color.red
            .gesture(DragGesture(minimumDistance: 5).onChanged { _ in log("drag") })
            .onTapGesture(count: 2) { log("double") }
    }
}

@View
struct PinchableInScroll {
    let log: Log

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.green.frame(width: 200, height: 300)
                    .gesture(MagnifyGesture().onChanged { log(String(format: "mag %.1f", $0.magnification)) })
                Color.blue.frame(width: 200, height: 300)
            }
        }
    }
}

@View
struct SliderUnderHighPriorityHold {
    let log: Log
    @State private var level = 0.5

    var body: some View {
        Slider(value: Binding(get: { level }, set: { level = $0; log("level") }))
            .frame(width: 200)
            .highPriorityGesture(LongPressGesture().onEnded { _ in log("hold") })
    }
}

@View
struct PlainButton {
    let log: Log

    var body: some View {
        Button("B") { log("button") }
    }
}

// MARK: - Tests

extension HostedViews {
    @MainActor
    @Suite
    struct GestureTests {

        @Test func singleTapWaitsForADoubleTapAttachedBeforeIt() async {
            let log = Log()
            let harness = Harness(DoubleThenSingleTap(log: log))
            await harness.tap(center)
            #expect(log.take() == [], "the single tap waits while a second tap may come")
            await harness.settle(0.5)
            #expect(log.take() == ["single"])

            await harness.tap(center)
            await harness.tap(center)
            await harness.settle(0.5)
            #expect(log.take() == ["double"])
        }

        @Test func outerTapGetsAClickTheInnerDoubleTapGaveUpOn() async {
            let log = Log()
            let harness = Harness(DoubleTapInsideTap(log: log, innerSingle: false))
            await harness.tap(center)
            await harness.settle(0.5)
            #expect(log.take() == ["outer"])
            await harness.tap(center)
            await harness.tap(center)
            await harness.settle(0.5)
            #expect(log.take() == ["inner double"])
        }

        @Test func innerSingleTapKeepsTheClickFromTheOuterTap() async {
            let log = Log()
            let harness = Harness(DoubleTapInsideTap(log: log, innerSingle: true))
            await harness.tap(center)
            await harness.settle(0.5)
            #expect(log.take() == ["inner single"])
            await harness.tap(Point(x: 10, y: 10))
            await harness.settle(0.05)
            #expect(log.take() == ["outer"])
        }

        @Test func singleTapAttachedFirstWinsEveryTap() async {
            let log = Log()
            let harness = Harness(SingleThenDoubleTap(log: log))
            await harness.tap(center)
            await harness.tap(center)
            await harness.settle(0.5)
            #expect(log.take() == ["single", "single"])
        }

        @Test func gestureGoesAfterTheButtonInsideIt() async {
            let log = Log()
            let harness = Harness(ButtonInsideTap(log: log, priority: 0))
            await harness.tap(center)
            await harness.settle(0.05)
            #expect(log.take() == ["button"])
        }

        @Test func highPriorityGestureGoesBeforeTheButtonInsideIt() async {
            let log = Log()
            let harness = Harness(ButtonInsideTap(log: log, priority: 1))
            await harness.tap(center)
            await harness.settle(0.05)
            #expect(log.take() == ["outer"])
        }

        @Test func simultaneousGestureRunsWithTheButtonInsideIt() async {
            let log = Log()
            let harness = Harness(ButtonInsideTap(log: log, priority: 2))
            await harness.tap(center)
            await harness.settle(0.05)
            #expect(Set(log.take()) == ["outer", "button"])
        }

        @Test func holdingIsALongPressAndAShortPressIsATap() async {
            let log = Log()
            let harness = Harness(TapAndHold(log: log))
            harness.host.pointerDown(at: center)
            await harness.settle(0.7)
            harness.host.pointerUp(at: center)
            await harness.settle(0.05)
            #expect(log.take() == ["pressing true", "hold", "pressing false"])

            await harness.tap(center)
            await harness.settle(0.05)
            #expect(log.take() == ["pressing true", "pressing false", "tap"])
        }

        @Test func longPressFailsWhenThePressWanders() async {
            let log = Log()
            let harness = Harness(TapAndHold(log: log))
            harness.host.pointerDown(at: center)
            harness.host.pointerMoved(to: Point(x: 130, y: 100))
            await harness.settle(0.7)
            harness.host.pointerUp(at: Point(x: 130, y: 100))
            await harness.settle(0.05)
            let entries = log.take()
            #expect(!entries.contains("hold"), "moved past its maximum distance, the hold never comes")
            #expect(entries.prefix(2) == ["pressing true", "pressing false"])
        }

        @Test func dragFromAButtonIsADragAndAClickIsTheButton() async {
            let log = Log()
            let harness = Harness(DragAroundButton(log: log, simultaneous: false))
            await harness.drag(from: center, through: [Point(x: 105, y: 100), Point(x: 130, y: 100)])
            #expect(log.take() == ["drag 30", "end 30"], "the drag waits a few points before taking the press")

            await harness.tap(center)
            #expect(log.take() == ["button"])
        }

        @Test func simultaneousDragReportsAlongsideTheButton() async {
            let log = Log()
            let harness = Harness(DragAroundButton(log: log, simultaneous: true))
            await harness.drag(from: center, through: [Point(x: 112, y: 100)])
            #expect(log.take() == ["drag 0", "drag 12", "end 12", "button"])
        }

        @Test func twoFingersPinch() async {
            let log = Log()
            let harness = Harness(PinchAndTwist(log: log))
            harness.host.pointerDown(id: 1, at: Point(x: 80, y: 100))
            harness.host.pointerDown(id: 2, at: Point(x: 120, y: 100))
            harness.host.pointerMoved(id: 2, to: Point(x: 160, y: 100))
            harness.host.pointerUp(id: 2, at: Point(x: 160, y: 100))
            harness.host.pointerUp(id: 1, at: Point(x: 80, y: 100))
            await harness.settle()
            #expect(log.take() == ["mag 2.00", "magEnd 2.00"])
        }

        @Test func twoFingersTwistClockwise() async {
            let log = Log()
            let harness = Harness(PinchAndTwist(log: log))
            harness.host.pointerDown(id: 1, at: Point(x: 100, y: 100))
            harness.host.pointerDown(id: 2, at: Point(x: 140, y: 100))
            harness.host.pointerMoved(id: 2, to: Point(x: 100, y: 140))
            harness.host.pointerUp(id: 2, at: Point(x: 100, y: 140))
            harness.host.pointerUp(id: 1, at: Point(x: 100, y: 100))
            await harness.settle()
            #expect(log.take() == ["rot 90", "rotEnd 90"])
        }

        @Test func trackpadPinchAndRotation() async {
            let log = Log()
            let harness = Harness(PinchAndTwist(log: log))
            harness.host.magnify(phase: .began, delta: 0, at: center)
            harness.host.magnify(phase: .changed, delta: 0.25, at: center)
            harness.host.magnify(phase: .changed, delta: 0.25, at: center)
            harness.host.magnify(phase: .ended, delta: 0, at: center)
            #expect(log.take() == ["mag 1.25", "mag 1.50", "magEnd 1.50"])

            // AppKit's rotation is counterclockwise for positive.
            harness.host.rotate(phase: .began, delta: 0, at: center)
            harness.host.rotate(phase: .changed, delta: -30, at: center)
            harness.host.rotate(phase: .ended, delta: 0, at: center)
            #expect(log.take() == ["rot 30", "rotEnd 30"])
        }

        @Test func innerPinchGoesBeforeOuterPinch() async {
            let log = Log()
            let harness = Harness(NestedPinch(log: log))
            harness.host.magnify(phase: .began, delta: 0, at: center)
            harness.host.magnify(phase: .changed, delta: 0.2, at: center)
            harness.host.magnify(phase: .ended, delta: 0, at: center)
            #expect(log.take() == ["inner"])

            harness.host.magnify(phase: .began, delta: 0, at: Point(x: 10, y: 10))
            harness.host.magnify(phase: .changed, delta: 0.2, at: Point(x: 10, y: 10))
            harness.host.magnify(phase: .ended, delta: 0, at: Point(x: 10, y: 10))
            #expect(log.take() == ["outer"])
        }

        @Test(arguments: [
            (GestureMask.all, ["button"]),
            (GestureMask.subviews, ["button"]),
            (GestureMask.gesture, ["outer"]),
            (GestureMask.none, []),
        ])
        func gestureMask(mask: GestureMask, expected: [String]) async {
            let log = Log()
            let harness = Harness(MaskedTap(log: log, mask: mask))
            await harness.tap(center)
            await harness.settle(0.05)
            #expect(log.take() == expected)
        }

        @Test func disabledGestureDoesNothing() async {
            let log = Log()
            let harness = Harness(DisabledGesture(log: log))
            await harness.tap(center)
            await harness.settle(0.05)
            #expect(log.take() == [])
        }

        @Test func dragOnlyTargetLeavesClicksToTheDoubleTapAroundIt() async {
            let log = Log()
            let harness = Harness(DragTargetInsideDoubleTap(log: log))
            await harness.tap(center)
            await harness.tap(center)
            await harness.settle(0.05)
            #expect(log.take() == ["double"])
        }

        @Test func oneFingerOnAPinchableViewStillScrolls() async {
            let log = Log()
            let harness = Harness(PinchableInScroll(log: log))
            harness.host.scrollsOnDrag = true
            await harness.drag(from: Point(x: 100, y: 150), through: [Point(x: 100, y: 120), Point(x: 100, y: 90)], pointer: 1)
            #expect(log.take() == [])

            harness.host.pointerDown(id: 1, at: Point(x: 80, y: 100))
            harness.host.pointerDown(id: 2, at: Point(x: 120, y: 100))
            harness.host.pointerMoved(id: 2, to: Point(x: 160, y: 100))
            harness.host.pointerUp(id: 2, at: Point(x: 160, y: 100))
            harness.host.pointerUp(id: 1, at: Point(x: 80, y: 100))
            await harness.settle()
            #expect(log.take() == ["mag 2.0"])
        }

        @Test func sliderDragsUnderAHighPriorityLongPress() async {
            let log = Log()
            let harness = Harness(SliderUnderHighPriorityHold(log: log))
            harness.host.pointerDown(at: Point(x: 150, y: 100))
            await harness.settle(0.05)
            harness.host.pointerMoved(to: Point(x: 160, y: 100))
            await harness.settle(0.05)
            harness.host.pointerUp(at: Point(x: 160, y: 100))
            await harness.settle(0.05)
            let quick = log.take()
            #expect(quick.first == "level")
            #expect(!quick.contains("hold"))

            harness.host.pointerDown(at: Point(x: 50, y: 100))
            await harness.settle(0.7)
            harness.host.pointerUp(at: Point(x: 50, y: 100))
            await harness.settle(0.05)
            #expect(log.take().last == "hold")
        }

        @Test func plainButtonIsUnchanged() async {
            let log = Log()
            let harness = Harness(PlainButton(log: log))
            await harness.tap(center)
            #expect(log.take() == ["button"])
            // Released outside — the root fills the window, so off its edge: no tap.
            await harness.drag(from: center, through: [Point(x: 260, y: 260)])
            #expect(log.take() == [])
        }
    }
}
