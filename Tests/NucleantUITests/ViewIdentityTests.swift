//
//  ViewIdentityTests.swift
//  NucleantUITests
//
//  `#viewID` names the place a view is constructed — not its declaration —
//  and `@View`'s equivalence decides without reflection: by `Equatable`,
//  by `ViewInput`, by identity for a class, and "not equivalent" for
//  anything that says none of those.
//

import Testing
@testable import NucleantUI

@View
private struct Label {
    let title: String
    var body: some View { Text(title) }
}

/// A view whose initializer does not take the call site.
@View
private struct Untracked {
    let title: String

    init(title: String) {
        self.title = title
    }

    var body: some View { Text(title) }
}

/// A plain value with no `Equatable` — nothing says how to compare it.
private struct Opaque {
    var count: Int
}

@View
private struct HoldsOpaque {
    let value: Opaque
    var body: some View { EmptyView() }
}

private final class Model {}

@View
private struct HoldsModel {
    let model: Model
    var body: some View { EmptyView() }
}

@MainActor
@Suite
struct ViewIdentityTests {

    @Test func viewIDIsTheCallSiteNotTheDeclaration() {
        let first = Label(title: "a")
        let second = Label(title: "a")
        #expect(first._viewID != .unknown)
        #expect(first._viewID != second._viewID)
    }

    @Test func oneCallSiteIsOneViewIDEveryTime() {
        func make() -> Label { Label(title: "a") }
        #expect(make()._viewID == make()._viewID)
    }

    @Test func eachViewInABuilderHasItsOwnSite() {
        @ViewBuilder func pair() -> TupleView<Label, Label> {
            Label(title: "a")
            Label(title: "a")
        }
        let (first, second) = pair().value
        #expect(first._viewID != .unknown)
        #expect(first._viewID != second._viewID)
        #expect(pair().value.0._viewID == first._viewID)
    }

    @Test func anInitWithoutTheSiteGetsTheBuilderExpressions() {
        @ViewBuilder func pair() -> TupleView<Untracked, Untracked> {
            Untracked(title: "a")
            Untracked(title: "a")
        }
        #expect(Untracked(title: "a")._viewID == .unknown)
        let (first, second) = pair().value
        #expect(first._viewID != .unknown)
        #expect(first._viewID != second._viewID)
    }

    @Test func equatableInputsCompareByValue() {
        #expect(Label(title: "a")._isEquivalent(to: Label(title: "a")))
        #expect(!Label(title: "a")._isEquivalent(to: Label(title: "b")))
    }

    @Test func anInputThatCannotBeComparedIsNotEquivalent() {
        let view = HoldsOpaque(value: Opaque(count: 1))
        #expect(!view._isEquivalent(to: HoldsOpaque(value: Opaque(count: 1))))
    }

    @Test func aClassInputComparesByIdentity() {
        let model = Model()
        #expect(HoldsModel(model: model)._isEquivalent(to: HoldsModel(model: model)))
        #expect(!HoldsModel(model: model)._isEquivalent(to: HoldsModel(model: Model())))
    }

    @Test func aPathShapeIsNeverEquivalent() {
        let shape = PathShape { _ in Path() }
        #expect(!shape._isEquivalent(to: shape))
    }

    @Test func modifiedContentComparesItsContent() {
        let a = Label(title: "a").modifier(Padded())
        #expect(a._isEquivalent(to: Label(title: "a").modifier(Padded())))
        #expect(!a._isEquivalent(to: Label(title: "b").modifier(Padded())))
    }
}

private struct Padded: ViewModifier, Equatable {
    func body(content: Content) -> some View { content.padding(4) }
}

// MARK: - Identity in a running tree

/// A tap counter that logs `name count` each time its body runs. Its
/// `@State` survives exactly as long as the framework treats it as the
/// same view.
@View
private struct Counter {
    let name: String
    let log: Log
    @State private var count = 0

    var body: some View {
        let _ = log("\(name) \(count)")
        Color.blue
            .frame(width: 200, height: 100)
            .onTapGesture { count += 1 }
    }
}

/// `Counter` through an initializer that does not take the call site — the
/// case the `@View` warning is about.
@View
private struct SitelessCounter {
    let name: String
    let log: Log
    @State private var count = 0

    init(name: String, log: Log) {
        self.name = name
        self.log = log
    }

    var body: some View {
        let _ = log("\(name) \(count)")
        Color.blue
            .frame(width: 200, height: 100)
            .onTapGesture { count += 1 }
    }
}

/// The top half flips `flag`; the bottom half is whichever counter `flag`
/// picks, built the way `Case` says.
@View
private struct Swapper {
    enum Case { case builderTernary, argumentTernary, argumentTernarySiteless, ifElse }
    let how: Case
    let log: Log
    @State private var flag = false

    var body: some View {
        VStack(spacing: 0) {
            Color.gray
                .frame(width: 200, height: 100)
                .onTapGesture { flag.toggle() }
            switch how {
            case .builderTernary:
                flag ? Counter(name: "b", log: log) : Counter(name: "a", log: log)
            case .argumentTernary:
                Color.clear
                    .frame(width: 200, height: 100)
                    .overlay(flag ? Counter(name: "b", log: log) : Counter(name: "a", log: log))
            case .argumentTernarySiteless:
                Color.clear
                    .frame(width: 200, height: 100)
                    .overlay(flag ? SitelessCounter(name: "b", log: log) : SitelessCounter(name: "a", log: log))
            case .ifElse:
                if flag {
                    Counter(name: "b", log: log)
                } else {
                    Counter(name: "a", log: log)
                }
            }
        }
    }
}

/// Rows from one call site, told apart by their ids.
@View
private struct Rows {
    let log: Log

    var body: some View {
        VStack(spacing: 0) {
            ForEach(["a", "b"], id: \.self) { name in
                Counter(name: name, log: log)
            }
        }
    }
}

extension HostedViews {

    @MainActor
    @Suite
    struct CallSiteIdentity {
        let toggle = Point(x: 100, y: 50)
        let counter = Point(x: 100, y: 150)

        /// Tap the counter once, flip to the other call site, and return
        /// what the counter now standing there shows.
        private func countAfterSwap(_ how: Swapper.Case) async -> String? {
            let log = Log()
            let harness = Harness(Swapper(how: how, log: log))
            await harness.tap(counter)
            #expect(log.take().last == "a 1")
            await harness.tap(toggle)
            return log.take().last
        }

        @Test func ifElseBranchesAreDifferentViews() async {
            #expect(await countAfterSwap(.ifElse) == "b 0")
        }

        @Test func aTernaryInABuilderTellsItsTwoCallSitesApart() async {
            #expect(await countAfterSwap(.builderTernary) == "b 0")
        }

        @Test func aTernaryAsAnArgumentTellsItsTwoCallSitesApart() async {
            #expect(await countAfterSwap(.argumentTernary) == "b 0")
        }

        @Test func withoutTheCallSiteATernaryCannotTellItsViewsApart() async {
            #expect(await countAfterSwap(.argumentTernarySiteless) == "b 1")
        }

        @Test func rowsFromOneCallSiteKeepTheirOwnState() async {
            let log = Log()
            let harness = Harness(Rows(log: log))
            log.take()
            await harness.tap(Point(x: 100, y: 150))   // row "b"
            #expect(log.take() == ["b 1"])
            await harness.tap(Point(x: 100, y: 50))    // row "a"
            #expect(log.take() == ["a 1"])
        }
    }
}
