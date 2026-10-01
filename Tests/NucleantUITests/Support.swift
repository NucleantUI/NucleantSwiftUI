//
//  Support.swift
//  NucleantUITests
//
//  A view tree hosted without a window: a `ViewHost` with a size and no
//  renderer lays out exactly as on screen, and takes the same pointer,
//  trackpad and key events a window would hand it.
//

import Foundation
import Testing
@testable import NucleantUI

/// Every suite that drives a host, one after another. A host shares the
/// process-wide invalidation queue (`Invalidator.shared`) with any other
/// host in the process, so two hosts running at once would take each
/// other's state changes; the suites are nested in this one, serialized.
@MainActor
@Suite(.serialized)
enum HostedViews {}

/// What the views under test did, in order.
@MainActor
final class Log {
    private(set) var entries: [String] = []

    func callAsFunction(_ entry: String) {
        entries.append(entry)
    }

    /// The entries so far, emptying the log.
    func take() -> [String] {
        defer { entries = [] }
        return entries
    }
}

/// One view tree in a window-less host.
@MainActor
final class Harness {
    let host: ViewHost

    init<V: View>(_ view: V, size: Size = Size(width: 200, height: 200)) {
        host = ViewHost(root: view)
        host.setSize(size)
        host.update()
    }

    /// Let timers due within `seconds` fire, then run a frame.
    func settle(_ seconds: Double = 0.02) async {
        try? await Task.sleep(for: .seconds(seconds))
        host.update()
    }

    func tap(_ point: Point, pointer: Int = 0) async {
        host.pointerDown(id: pointer, at: point)
        host.pointerUp(id: pointer, at: point)
        await settle()
    }

    /// A press at `from`, moved through `path`, released at its end.
    func drag(from: Point, through path: [Point], pointer: Int = 0) async {
        host.pointerDown(id: pointer, at: from)
        for point in path {
            host.pointerMoved(id: pointer, to: point)
        }
        host.pointerUp(id: pointer, at: path.last ?? from)
        await settle()
    }

    func key(_ code: UInt16, _ characters: String? = nil, modifiers: EventModifiers = []) async {
        host.keyDown(keyCode: code, characters: characters, modifiers: modifiers)
        host.keyUp(keyCode: code, characters: characters, modifiers: modifiers)
        await settle()
    }
}

let center = Point(x: 100, y: 100)

/// Virtual key codes, as the platforms report them.
enum KeyCode {
    static let `return`: UInt16 = 0x24
    static let tab: UInt16 = 0x30
    static let escape: UInt16 = 0x35
    static let x: UInt16 = 0x07
    static let upArrow: UInt16 = 0x7E
}
