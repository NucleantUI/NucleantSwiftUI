//
//  TransformedGestureTests.swift
//  NucleantUITests
//
//  Gestures on a view that is scaled, turned and offset inside a zoomed
//  container — where a press must still find it.
//

import Testing
@testable import NucleantUI

@View
struct TransformedCard {
    let log: Log
    let step: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            card
        }
        .scaleEffect(1, anchor: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var card: some View {
        let base = Color.red.frame(width: 60, height: 60)
        switch step {
        case 0:
            base.onLongPressGesture { log("hold") } onPressingChanged: { log("pressing \($0)") }
        case 1:
            base.onLongPressGesture { log("hold") } onPressingChanged: { log("pressing \($0)") }
                .offset(x: 100, y: 100)
        case 2:
            base.onLongPressGesture { log("hold") } onPressingChanged: { log("pressing \($0)") }
                .rotationEffect(.degrees(10))
                .offset(x: 100, y: 100)
        default:
            base.contentShape(Circle())
                .gesture(TapGesture(count: 2).onEnded { log("double") }, isEnabled: true)
                .onLongPressGesture { log("hold") } onPressingChanged: { log("pressing \($0)") }
                .allowsHitTesting(true)
                .scaleEffect(1.2)
                .rotationEffect(.degrees(10))
                .offset(x: 100, y: 100)
        }
    }
}

extension HostedViews {
    @MainActor
    @Suite
    struct TransformedGestureTests {
        @Test(arguments: [0, 1, 2, 3])
        func pressReachesATransformedCard(step: Int) async {
            let log = Log()
            let harness = Harness(TransformedCard(log: log, step: step), size: Size(width: 300, height: 300))
            let point = step == 0 ? Point(x: 30, y: 30) : Point(x: 130, y: 130)
            harness.host.pointerDown(at: point)
            #expect(log.take() == ["pressing true"], "the press finds the card")
            harness.host.pointerUp(at: point)
            await harness.settle()
        }
    }
}
