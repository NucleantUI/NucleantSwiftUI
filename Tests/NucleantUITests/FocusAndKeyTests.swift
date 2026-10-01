//
//  FocusAndKeyTests.swift
//  NucleantUITests
//
//  `@FocusState` with `.focused`, `.focusable`, `.onKeyPress`,
//  `.onSubmit` and `.submitScope`.
//

import Foundation
import Testing
@testable import NucleantUI

enum TestField: Hashable {
    case a, b
}

/// Reads and writes a view's focus state from outside it.
@MainActor
final class FocusProbe<Value> {
    var read: () -> Value
    var write: (Value) -> Void = { _ in }

    init(_ initial: Value) {
        read = { initial }
    }
}

@View
struct TwoFields {
    let probe: FocusProbe<TestField?>
    @State private var a = ""
    @State private var b = ""
    @FocusState private var focus: TestField?

    var body: some View {
        probe.read = { focus }
        probe.write = { focus = $0 }
        return VStack(spacing: 0) {
            TextField("A", text: $a).focused($focus, equals: .a).frame(width: 200, height: 100)
            TextField("B", text: $b).focused($focus, equals: .b).frame(width: 200, height: 100)
        }
        .onAppear { focus = .b }
    }
}

/// A focus state handed down to a child view as `@FocusState.Binding`.
@View
struct FieldWithChild {
    let probe: FocusProbe<Bool>
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        probe.read = { isFocused }
        probe.write = { isFocused = $0 }
        return ChildField(text: $text, isFocused: $isFocused)
    }
}

@View
struct ChildField {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        TextField("T", text: $text)
            .focused($isFocused)
            .frame(width: 200, height: 200)
    }
}

@View
struct KeyPad {
    let log: Log
    let probe: FocusProbe<Bool>
    @FocusState private var isFocused: Bool

    var body: some View {
        probe.read = { isFocused }
        return Color.orange
            .focusable()
            .focused($isFocused)
            .onKeyPress(.upArrow) {
                log("up")
                return .handled
            }
            .onKeyPress(phases: .up) { press in
                log("released \(press.key == .upArrow)")
                return .ignored
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "xyz")) { press in
                log("char \(press.characters)")
                return .handled
            }
    }
}

/// An `.onKeyPress` around a text field goes before the field.
@View
struct InterceptedField {
    let log: Log
    @State private var text = ""

    var body: some View {
        TextField("T", text: $text)
            .frame(width: 200, height: 200)
            .onKeyPress(.return) {
                log("return intercepted")
                return .handled
            }
            .onSubmit { log("submit") }
    }
}

@View
struct SubmitScoped {
    let log: Log
    let scoped: Bool
    @State private var text = ""

    var body: some View {
        VStack {
            if scoped {
                TextField("T", text: $text).frame(width: 200, height: 200).submitScope()
            } else {
                TextField("T", text: $text).frame(width: 200, height: 200)
            }
        }
        .onSubmit { log("outer submit") }
    }
}

extension HostedViews {
    @MainActor
    @Suite
    struct FocusAndKeyTests {

        @Test func focusStateFollowsAndMovesTheKeys() async {
            let probe = FocusProbe<TestField?>(nil)
            let harness = Harness(TwoFields(probe: probe))
            await harness.settle()
            await harness.settle()
            #expect(probe.read() == .b, "set in onAppear, the keys go to B")

            await harness.tap(Point(x: 100, y: 50))
            #expect(probe.read() == .a, "clicking A")

            await harness.key(KeyCode.tab, "\t")
            #expect(probe.read() == .b, "Tab")

            probe.write(.a)
            await harness.settle()
            await harness.key(KeyCode.x, "x")
            #expect(probe.read() == .a, "set from code, the keys move and stay")

            probe.write(nil)
            await harness.settle()
            await harness.settle()
            #expect(probe.read() == nil, "set to nil, nothing has the keys")

            await harness.tap(Point(x: 100, y: 150))
            #expect(probe.read() == .b)
        }

        @Test func focusStateBindingInAChildView() async {
            let probe = FocusProbe<Bool>(false)
            let harness = Harness(FieldWithChild(probe: probe))
            #expect(probe.read() == false)
            await harness.tap(center)
            #expect(probe.read() == true)
            probe.write(false)
            await harness.settle()
            await harness.settle()
            #expect(probe.read() == false)
            probe.write(true)
            await harness.settle()
            await harness.settle()
            #expect(probe.read() == true)
        }

        @Test func focusableViewTakesKeyPressesOnceFocused() async {
            let log = Log()
            let probe = FocusProbe<Bool>(false)
            let harness = Harness(KeyPad(log: log, probe: probe))
            await harness.key(KeyCode.upArrow)
            #expect(log.take() == [], "nothing has the keys yet")

            await harness.tap(center)
            #expect(probe.read() == true)

            harness.host.keyDown(keyCode: KeyCode.upArrow, characters: nil)
            harness.host.keyDown(keyCode: KeyCode.upArrow, characters: nil)
            harness.host.keyUp(keyCode: KeyCode.upArrow, characters: nil)
            #expect(log.take() == ["up", "up", "released true"], "down, repeat, up")

            await harness.key(KeyCode.x, "x")
            #expect(log.take() == ["char x", "released false"])
        }

        @Test func commandKeyPressIsNeverHeldAsARepeat() async {
            let log = Log()
            let probe = FocusProbe<Bool>(false)
            let harness = Harness(KeyPad(log: log, probe: probe))
            await harness.tap(center)
            // macOS sends no key up for a key pressed with ⌘.
            harness.host.keyDown(keyCode: KeyCode.upArrow, characters: nil, modifiers: .command)
            harness.host.keyDown(keyCode: KeyCode.upArrow, characters: nil)
            #expect(log.take() == ["up", "up"])
        }

        @Test func keyPressAroundATextFieldGoesFirst() async {
            let log = Log()
            let harness = Harness(InterceptedField(log: log))
            await harness.tap(center)
            await harness.key(KeyCode.return, "\r")
            #expect(log.take() == ["return intercepted"])
        }

        @Test func submitScopeKeepsTheSubmissionInside() async {
            let log = Log()
            let scoped = Harness(SubmitScoped(log: log, scoped: true))
            await scoped.tap(center)
            await scoped.key(KeyCode.return, "\r")
            #expect(log.take() == [])

            let open = Harness(SubmitScoped(log: log, scoped: false))
            await open.tap(center)
            await open.key(KeyCode.return, "\r")
            #expect(log.take() == ["outer submit"])
        }

        @Test(arguments: [
            (UInt16(0x24), "\r", KeyEquivalent.return),
            (UInt16(0x35), "\u{1b}", KeyEquivalent.escape),
            (UInt16(0x7B), "", KeyEquivalent.leftArrow),
            (UInt16(0x31), " ", KeyEquivalent.space),
            (UInt16(0x00), "A", KeyEquivalent.character("a")),
        ])
        func keyCodesMapToKeys(code: UInt16, characters: String, key: KeyEquivalent) {
            let press = KeyPress(phase: .down, keyCode: code, characters: characters, modifiers: [])
            #expect(press.key == key)
            #expect(press.characters == characters)
        }
    }
}
