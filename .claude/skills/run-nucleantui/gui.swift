// gui.swift — the CoreGraphics half of driver.sh: find an app's window,
// bring it to the front, and post mouse / scroll / key events at points
// relative to the window's top-left corner (title bar included, so they
// match `screencapture -l` screenshots divided by their scale).
//
//   gui window <owner>                      -> "id pid x y w h" (global points)
//   gui click  <owner> <x> <y> [count]      -> left click(s) at a window point
//   gui drag   <owner> <x0> <y0> <x1> <y1>  -> press, move in steps, release
//   gui scroll <owner> <x> <y> <dy>         -> wheel at a window point (dy < 0 = content up)
//   gui key    <owner> <keycode> [cmd,shift,alt,ctrl]
//   gui type   <owner> <text>
//   gui release                             -> key-up for every modifier (unsticks a held cmd/shift/…)
//
// Compiled by driver.sh into .build/run/gui; nothing else uses it.

import AppKit
import CoreGraphics
import Foundation

struct Window {
    let id: Int, pid: pid_t
    let frame: CGRect
}

func window(of owner: String) -> Window? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let mine = list.filter {
        ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0
    }
    let frames = mine.map { info -> Window in
        let b = info[kCGWindowBounds as String] as! [String: Double]
        return Window(
            id: info[kCGWindowNumber as String] as! Int,
            pid: info[kCGWindowOwnerPID as String] as! pid_t,
            frame: CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
        )
    }
    return frames.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

/// Events go to whatever window is under the point, so the app has to be in
/// front first. A CLI tool can't take activation on its own (macOS 14
/// cooperative activation), so ask System Events to raise the process.
func raise(_ w: Window) {
    if NSRunningApplication(processIdentifier: w.pid)?.isActive == true { return }
    let script = "tell application \"System Events\" to set frontmost of (first process whose unix id is \(w.pid)) to true"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]
    try? task.run()
    task.waitUntilExit()
    usleep(250_000)
}

func point(_ w: Window, _ x: String, _ y: String) -> CGPoint {
    guard let x = Double(x), let y = Double(y) else { fail("bad point \(x) \(y)") }
    return CGPoint(x: w.frame.minX + x, y: w.frame.minY + y)
}

let source = CGEventSource(stateID: .hidSystemState)

func post(_ type: CGEventType, at p: CGPoint, clicks: Int64 = 1) {
    let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    event?.flags = []
    event?.setIntegerValueField(.mouseEventClickState, value: clicks)
    event?.post(tap: .cghidEventTap)
}

/// Each modifier as the key that holds it and the flag it sets.
func modifiers(_ names: String?) -> [(key: CGKeyCode, flag: CGEventFlags)] {
    (names ?? "").split(separator: ",").map { name in
        switch name {
        case "cmd": (55, .maskCommand)
        case "shift": (56, .maskShift)
        case "alt": (58, .maskAlternate)
        case "ctrl": (59, .maskControl)
        default: fail("unknown modifier \(name)")
        }
    }
}

func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
    // Always set: a key event left to inherit from the HID state picks up
    // whatever modifier the system thinks is held.
    event?.flags = flags
    event?.post(tap: .cghidEventTap)
    usleep(30_000)
}

let args = CommandLine.arguments

// Lets go of every modifier, for when one is stuck down system-wide.
if args.count == 2, args[1] == "release" {
    for code: CGKeyCode in [55, 54, 56, 60, 58, 61, 59, 62] {
        postKey(code, down: false, flags: [])
    }
    print("modifiers held now: 0x" + String(CGEventSource.flagsState(.hidSystemState).rawValue & 0x00FF_0000, radix: 16))
    exit(0)
}

guard args.count >= 3 else { fail("usage: gui <window|click|drag|scroll|key|type> <owner> … | gui release") }
let command = args[1], owner = args[2]
guard let w = window(of: owner) else { fail("no on-screen window owned by \(owner)") }

switch command {
case "window":
    print(w.id, w.pid, Int(w.frame.minX), Int(w.frame.minY), Int(w.frame.width), Int(w.frame.height))

case "click":
    guard args.count >= 5 else { fail("usage: gui click <owner> <x> <y> [count]") }
    raise(w)
    let p = point(w, args[3], args[4])
    let count = args.count > 5 ? Int64(args[5]) ?? 1 : 1
    post(.mouseMoved, at: p)
    usleep(60_000)
    for n in 1...count {
        post(.leftMouseDown, at: p, clicks: n)
        usleep(50_000)
        post(.leftMouseUp, at: p, clicks: n)
        usleep(50_000)
    }

case "drag":
    guard args.count >= 7 else { fail("usage: gui drag <owner> <x0> <y0> <x1> <y1>") }
    raise(w)
    let from = point(w, args[3], args[4]), to = point(w, args[5], args[6])
    post(.mouseMoved, at: from)
    usleep(60_000)
    post(.leftMouseDown, at: from)
    let steps = 20
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        post(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        usleep(16_000)
    }
    post(.leftMouseUp, at: to)

case "scroll":
    guard args.count >= 6, let dy = Int32(args[5]) else { fail("usage: gui scroll <owner> <x> <y> <dy>") }
    raise(w)
    post(.mouseMoved, at: point(w, args[3], args[4]))
    usleep(60_000)
    // In steps, as a wheel or trackpad delivers it.
    let step: Int32 = dy < 0 ? -40 : 40
    var left = dy
    while left != 0 {
        let delta = abs(left) < abs(step) ? left : step
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
        left -= delta
        usleep(16_000)
    }

case "key":
    guard args.count >= 4, let code = UInt16(args[3]) else { fail("usage: gui key <owner> <keycode> [mods]") }
    raise(w)
    // Pressed and released as real keys: a key event that only carries a
    // modifier flag leaves the HID state believing the modifier is still
    // held — for every app, the user's own typing included.
    let held = modifiers(args.count > 4 ? args[4] : nil)
    var flags: CGEventFlags = []
    for modifier in held {
        flags.insert(modifier.flag)
        postKey(modifier.key, down: true, flags: flags)
    }
    postKey(code, down: true, flags: flags)
    postKey(code, down: false, flags: flags)
    for modifier in held.reversed() {
        flags.remove(modifier.flag)
        postKey(modifier.key, down: false, flags: flags)
    }

case "type":
    guard args.count >= 4 else { fail("usage: gui type <owner> <text>") }
    raise(w)
    for scalar in args[3].utf16 {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            event?.flags = []
            var unit = scalar
            event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
            event?.post(tap: .cghidEventTap)
            usleep(25_000)
        }
    }

default:
    fail("unknown command \(command)")
}
