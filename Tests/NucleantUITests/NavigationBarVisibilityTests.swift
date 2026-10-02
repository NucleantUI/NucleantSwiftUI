//
//  NavigationBarVisibilityTests.swift
//  NucleantUITests
//
//  `.toolbarVisibility(_:for:)` on a `NavigationStack`'s screens: a hidden
//  bar gives its 44 points to the screen from the first frame that shows
//  it, each screen keeps its own setting as others are pushed and popped,
//  and a screen can flip it at runtime.
//
//  Every screen here starts with a 20-point strip, so where a tap lands
//  says where the screen begins: at y 44 under the bar, at 0 without it.
//  The bar itself takes no taps except on its back button.
//

import Testing
@testable import NucleantUI

/// How a screen asks for the bar to be hidden — the three spellings that
/// reach a stack's bar.
enum BarHidingSpelling: CaseIterable {
    case toolbarVisibility
    case toolbar
    case automaticPlacement
}

/// A strip across the top of a screen, the rest empty.
@View
struct BarTestStrip {
    let log: Log
    let name: String

    var body: some View {
        VStack(spacing: 0) {
            Color.red.frame(height: 20).onTapGesture { log(name) }
            Spacer()
        }
    }
}

@View
struct BarShownByDefault {
    let log: Log

    var body: some View {
        NavigationStack("Root") {
            BarTestStrip(log: log, name: "root")
        }
    }
}

@View
struct BarHiddenOnRoot {
    let log: Log
    let spelling: BarHidingSpelling

    var body: some View {
        NavigationStack("Root") {
            switch spelling {
            case .toolbarVisibility:
                BarTestStrip(log: log, name: "root")
                    .toolbarVisibility(.hidden, for: .navigationBar)
            case .toolbar:
                BarTestStrip(log: log, name: "root")
                    .toolbar(.hidden, for: .navigationBar)
            case .automaticPlacement:
                BarTestStrip(log: log, name: "root")
                    .toolbarVisibility(.hidden)
            }
        }
    }
}

/// Root (bar shown) → cover (bar hidden, its own close strip) → details,
/// pushed by value (bar shown, with Back).
@View
struct BarPerScreen {
    let log: Log

    var body: some View {
        NavigationStack("Library") {
            VStack(spacing: 0) {
                Color.red.frame(height: 20).onTapGesture { log("root") }
                NavigationLink(title: "Cover") {
                    BarHidingCover(log: log)
                } label: {
                    Color.green.frame(height: 20)
                }
                Spacer()
            }
            .navigationDestination(for: Int.self) { page in
                BarTestStrip(log: log, name: "details \(page)")
            }
        }
    }
}

@View
struct BarHidingCover {
    let log: Log
    @Environment(\.navigationRouter) private var router

    var body: some View {
        VStack(spacing: 0) {
            Color.blue.frame(height: 20).onTapGesture {
                log("close")
                router?.pop()
            }
            NavigationLink(value: 7) {
                Color.green.frame(height: 20)
            }
            Spacer()
        }
        .toolbarVisibility(.hidden, for: .navigationBar)
    }
}

/// A screen that hides the bar while it's immersive, flipped by a tap.
@View
struct BarImmersivePage {
    let log: Log
    @State private var isImmersive = false

    var body: some View {
        VStack(spacing: 0) {
            Color.red.frame(height: 20).onTapGesture {
                log(isImmersive ? "immersive" : "framed")
                isImmersive.toggle()
            }
            Spacer()
        }
        .toolbarVisibility(isImmersive ? .hidden : .visible, for: .navigationBar)
    }
}

@View
struct BarToggledAtRuntime {
    let log: Log

    var body: some View {
        NavigationStack("Page") {
            BarImmersivePage(log: log)
        }
    }
}

extension HostedViews {
    @MainActor
    @Suite
    struct NavigationBarVisibilityTests {

        /// Where a screen's strip is: under the bar or at the very top.
        static let underBar = Point(x: 100, y: 54)
        static let atTop = Point(x: 100, y: 10)
        /// Below each strip: the second 20-point row on a screen.
        static let secondRowUnderBar = Point(x: 100, y: 74)
        static let secondRowAtTop = Point(x: 100, y: 30)
        /// The back button, at the bar's leading edge.
        static let back = Point(x: 30, y: 22)

        @Test func theBarInsetsTheScreen() async {
            let log = Log()
            let harness = Harness(BarShownByDefault(log: log))
            await harness.tap(Self.atTop)
            #expect(log.take() == [])
            await harness.tap(Self.underBar)
            #expect(log.take() == ["root"])
        }

        @Test(arguments: BarHidingSpelling.allCases)
        func aHiddenBarGivesTheScreenItsSpaceFromTheFirstFrame(spelling: BarHidingSpelling) async {
            let log = Log()
            // One frame, no settling: the screen files its visibility while
            // it builds and the bar, built after it, already reads it.
            let harness = Harness(BarHiddenOnRoot(log: log, spelling: spelling))
            await harness.tap(Self.atTop)
            #expect(log.take() == ["root"])
            await harness.tap(Self.underBar)
            #expect(log.take() == [])
        }

        @Test func eachScreenKeepsItsOwnSetting() async {
            let log = Log()
            let harness = Harness(BarPerScreen(log: log))

            // Root: bar shown.
            await harness.tap(Self.underBar)
            #expect(log.take() == ["root"])

            // The cover hides it in the frame it is pushed in.
            await harness.tap(Self.secondRowUnderBar)
            await harness.tap(Self.atTop)
            #expect(log.take() == ["close"])

            // Popped: root's bar is back.
            await harness.tap(Self.atTop)
            #expect(log.take() == [])
            await harness.tap(Self.underBar)
            #expect(log.take() == ["root"])

            // Cover again, then details on top of it: shown there, with Back.
            await harness.tap(Self.secondRowUnderBar)
            await harness.tap(Self.secondRowAtTop)
            await harness.tap(Self.underBar)
            #expect(log.take() == ["details 7"])

            // Back to the cover: hidden again.
            await harness.tap(Self.back)
            await harness.tap(Self.atTop)
            #expect(log.take() == ["close"])
        }

        @Test func aScreenFlipsItAtRuntime() async {
            let log = Log()
            let harness = Harness(BarToggledAtRuntime(log: log))

            await harness.tap(Self.underBar)
            #expect(log.take() == ["framed"])
            // The bar follows on the next frame, as a changed title does.
            await harness.settle()
            await harness.tap(Self.atTop)
            #expect(log.take() == ["immersive"])

            await harness.settle()
            await harness.tap(Self.atTop)
            #expect(log.take() == [])
            await harness.tap(Self.underBar)
            #expect(log.take() == ["framed"])
        }
    }
}
