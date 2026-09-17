//
//  CalculatorApp.swift
//  Calculator
//
//  A pocket calculator: a grid of keys and an immediate-execution engine.
//  Every key is a custom control (`Key`) built from a shape, a `Text` and a
//  `DragGesture` — pressed state included — rather than the framework's
//  `Button`, to show what a control looks like from the outside.
//

import Foundation
import NucleantSwiftUI

// MARK: - Engine

/// The four operations plus percent, as the keypad exposes them.
enum Operation: String {
    case add = "+", subtract = "−", multiply = "×", divide = "÷"

    func apply(_ lhs: Double, _ rhs: Double) -> Double {
        switch self {
        case .add:      return lhs + rhs
        case .subtract: return lhs - rhs
        case .multiply: return lhs * rhs
        case .divide:   return rhs == 0 ? .nan : lhs / rhs
        }
    }
}

/// A calculator that evaluates as you go, the way a desk calculator does:
/// `2 + 3 × 4 =` is 20, not 14.
struct Calculator {
    /// The digits being typed, as typed — "0.50" stays "0.50" until an
    /// operation consumes it.
    private(set) var entry = "0"
    private var accumulator: Double? = nil
    private(set) var pending: Operation? = nil
    /// After `=` or an operator the next digit starts a fresh entry.
    private var startsFresh = true

    var display: String {
        if startsFresh, let accumulator, pending == nil || entry == "0" {
            return Calculator.format(accumulator)
        }
        return entry
    }

    var history: String {
        guard let accumulator, let pending else { return "" }
        return "\(Calculator.format(accumulator)) \(pending.rawValue)"
    }

    mutating func digit(_ d: Character) {
        if startsFresh {
            entry = "0"
            startsFresh = false
        }
        if d == "." {
            if !entry.contains(".") { entry += "." }
        } else if entry == "0" {
            entry = String(d)
        } else if entry.count < 12 {
            entry.append(d)
        }
    }

    mutating func operation(_ op: Operation) {
        commitPending()
        pending = op
        startsFresh = true
    }

    mutating func equals() {
        commitPending()
        pending = nil
        startsFresh = true
    }

    mutating func clear() { self = Calculator() }

    mutating func negate() {
        let value = -(Double(entry) ?? 0)
        entry = Calculator.format(value)
        startsFresh = false
    }

    mutating func percent() {
        let value = (Double(entry) ?? 0) / 100
        entry = Calculator.format(value)
        startsFresh = false
    }

    private mutating func commitPending() {
        let value = Double(entry) ?? 0
        if let pending, let accumulator {
            let result = pending.apply(accumulator, value)
            self.accumulator = result
            entry = Calculator.format(result)
        } else if !startsFresh || accumulator == nil {
            accumulator = value
        }
    }

    static func format(_ value: Double) -> String {
        if value.isNaN { return "Error" }
        if value == value.rounded(), abs(value) < 1e12 {
            return String(Int(value))
        }
        var text = String(format: "%.8f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

// MARK: - Keys

/// Dynamic where the surface is, fixed where the accent is: the keys have a
/// light and a dark face each, the orange operator keys are the same in
/// both. `Color.dynamic` is the framework's light/dark pair; `.background`
/// and `.primary` are its semantic colors, which already are.
struct Theme {
    static let background = Color.background
    static let digit = Color.dynamic(light: Color(hex: 0xE2E4EA), dark: Color(hex: 0x2B2F38))
    static let function = Color.dynamic(light: Color(hex: 0xC9CCD4), dark: Color(hex: 0x3D424D))
    static let operation = Color(hex: 0xFF9F0A)
    static let operationActive = Color(hex: 0xFFD08A)
}

enum KeyStyle { case digit, function, operation }

/// One key of the pad. A press darkens it; the action fires on release
/// inside the key, so a drag off cancels — the same contract as `Button`,
/// but with the calculator's own look.
@View
struct Key {
    let label: String
    let style: KeyStyle
    var isActive: Bool = false
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Text(label)
            .font(.system(size: 26, weight: style == .operation ? .medium : .regular))
            .foregroundColor(style == .operation ? (isActive ? Theme.operation : .white) : .primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                Capsule().fill(fill.opacity(isPressed ? 0.6 : 1))
            )
            .gesture(
                DragGesture()
                    .onChanged { _ in isPressed = true }
                    .onEnded { value in
                        isPressed = false
                        if value.bounds.contains(Point(
                            x: value.bounds.minX + value.location.x,
                            y: value.bounds.minY + value.location.y
                        )) {
                            action()
                        }
                    }
            )
    }

    private var fill: Color {
        switch style {
        case .digit:     return Theme.digit
        case .function:  return Theme.function
        case .operation: return isActive ? Theme.operationActive : Theme.operation
        }
    }
}

// MARK: - Screen

@View
struct CalculatorView {
    @State private var calc = Calculator()
    @Environment(\.colorScheme) private var system

    var body: some View {
        VStack(spacing: 10) {
            display
            row {
                Key(label: "AC", style: .function) { calc.clear() }
                Key(label: "±", style: .function) { calc.negate() }
                Key(label: "%", style: .function) { calc.percent() }
                operationKey(.divide)
            }
            row {
                digitKey("7"); digitKey("8"); digitKey("9")
                operationKey(.multiply)
            }
            row {
                digitKey("4"); digitKey("5"); digitKey("6")
                operationKey(.subtract)
            }
            row {
                digitKey("1"); digitKey("2"); digitKey("3")
                operationKey(.add)
            }
            row {
                // Two flexible halves: the zero key is one, the other two
                // keys share the other — so it spans two columns.
                digitKey("0")
                HStack(spacing: 10) {
                    digitKey(".")
                    Key(label: "=", style: .operation) { calc.equals() }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .colorScheme(AppearanceModel.shared.appearance.scheme ?? system)
    }

    var display: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(calc.history)
                .font(.system(size: 18, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(minHeight: 22)
            Text(calc.display)
                .font(.system(size: 52, weight: .light, design: .monospaced))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .bottomTrailing)
        .padding(horizontal: 12, vertical: 8)
    }

    func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func digitKey(_ digit: Character) -> Key {
        Key(label: String(digit), style: .digit) { calc.digit(digit) }
    }

    func operationKey(_ op: Operation) -> Key {
        Key(label: op.rawValue, style: .operation, isActive: calc.pending == op) {
            calc.operation(op)
        }
    }
}

@main
struct CalculatorApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Calculator", width: 360, height: 600) {
            CalculatorView()
        }
        .commands { AppearanceCommands() }
    }
}
