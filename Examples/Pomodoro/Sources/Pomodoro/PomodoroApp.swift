//
//  PomodoroApp.swift
//  Pomodoro
//
//  A focus timer with an analog clock. The one thing this app needs that
//  no pointer event provides is a tick: a Foundation `Timer` on the main
//  run loop writes `@State` once a second, and the framework rebuilds
//  what read it on the next frame, the same as it would after a click.
//
//  The clock face and the progress ring are `PathShape`s; the hands are
//  lines from the centre, so no rotation anchor arithmetic is needed.
//

import Foundation
import NucleantSwiftUI

// MARK: - Ticking

/// One process-wide one-second timer. Started once from `onAppear`; the
/// callback is replaced rather than added to, so a rebuilt view that calls
/// `start` again simply updates what a tick does.
@MainActor
final class Ticker {
    static let shared = Ticker()
    private var timer: Timer?
    private var onTick: @MainActor () -> Void = {}

    func start(_ tick: @escaping @MainActor () -> Void) {
        onTick = tick
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            // The main run loop fires this on the main thread.
            MainActor.assumeIsolated { Ticker.shared.onTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

// MARK: - Model

enum Phase {
    case focus, shortBreak, longBreak

    var length: Int {
        switch self {
        case .focus:      return 25 * 60
        case .shortBreak: return 5 * 60
        case .longBreak:  return 15 * 60
        }
    }

    var name: String {
        switch self {
        case .focus:      return "Focus"
        case .shortBreak: return "Short break"
        case .longBreak:  return "Long break"
        }
    }

    var color: Color {
        switch self {
        case .focus:      return Color(hex: 0xFF5C5C)
        case .shortBreak: return Color(hex: 0x3DD68C)
        case .longBreak:  return Color(hex: 0x4C8DFF)
        }
    }
}

struct Session: Equatable {
    var phase = Phase.focus
    var remaining = Phase.focus.length
    var isRunning = false
    var completed = 0

    var progress: Double { 1 - Double(remaining) / Double(phase.length) }

    mutating func tick() {
        guard isRunning else { return }
        remaining -= 1
        if remaining <= 0 {
            isRunning = false
            if phase == .focus {
                completed += 1
                phase = completed % 4 == 0 ? .longBreak : .shortBreak
            } else {
                phase = .focus
            }
            remaining = phase.length
        }
    }

    mutating func skip() {
        remaining = 1
        let wasRunning = isRunning
        isRunning = true
        tick()
        isRunning = wasRunning
    }

    mutating func reset() {
        remaining = phase.length
        isRunning = false
    }
}

struct Theme {
    static let background = Color.background
    static let panel = Color.secondaryBackground
    static let face = Color.dynamic(light: Color(hex: 0xE6E8EE), dark: Color(hex: 0x22262F))
    static let ticks = Color.dynamic(light: Color(white: 0, opacity: 0.35), dark: Color(white: 1, opacity: 0.35))
    static let muted = Color.dynamic(light: Color(white: 0.55), dark: Color(white: 0.3))
}

// MARK: - Drawing

/// A circular arc as cubic Béziers — `Path` has no arc primitive.
func arc(center: Point, radius: Double, from start: Double, to end: Double) -> Path {
    var path = Path()
    let sweep = end - start
    guard sweep > 0.0001 else { return path }
    let segments = Int(ceil(sweep / (.pi / 2)))
    let step = sweep / Double(segments)
    let k = 4.0 / 3.0 * tan(step / 4)
    func point(_ a: Double) -> Point {
        Point(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
    }
    path.move(to: point(start))
    for i in 0..<segments {
        let a0 = start + Double(i) * step
        let a1 = a0 + step
        let p0 = point(a0), p3 = point(a1)
        path.addCurve(
            to: p3,
            control1: Point(x: p0.x - k * radius * sin(a0), y: p0.y + k * radius * cos(a0)),
            control2: Point(x: p3.x + k * radius * sin(a1), y: p3.y - k * radius * cos(a1))
        )
    }
    return path
}

/// A line from the centre of the view, `length` as a fraction of the
/// radius, at `angle` in turns (0 = twelve o'clock).
@View
struct Hand {
    let turns: Double
    let length: Double
    let width: Double
    let color: Color

    var body: some View {
        PathShape { size in
            let c = Point(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) / 2 * length
            let a = turns * 2 * .pi - .pi / 2
            var path = Path()
            path.move(to: Point(x: c.x - cos(a) * r * 0.15, y: c.y - sin(a) * r * 0.15))
            path.addLine(to: Point(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
            return path
        }
        .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}

@View
struct ClockFace {
    let now: Date

    var body: some View {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        let seconds = Double(parts.second ?? 0)
        let minutes = Double(parts.minute ?? 0) + seconds / 60
        let hours = Double((parts.hour ?? 0) % 12) + minutes / 60

        ZStack {
            Circle().fill(Theme.face)
            // Sixty ticks, the hours longer.
            PathShape { size in
                let c = Point(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) / 2
                var path = Path()
                for i in 0..<60 {
                    let a = Double(i) / 60 * 2 * .pi
                    let inner = i % 5 == 0 ? r * 0.86 : r * 0.93
                    path.move(to: Point(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
                    path.addLine(to: Point(x: c.x + cos(a) * r * 0.97, y: c.y + sin(a) * r * 0.97))
                }
                return path
            }
            .stroke(Theme.ticks, lineWidth: 1.5)

            Hand(turns: hours / 12, length: 0.55, width: 5, color: .primary)
            Hand(turns: minutes / 60, length: 0.8, width: 4, color: .primary)
            Hand(turns: seconds / 60, length: 0.9, width: 1.5, color: Color(hex: 0xFF5C5C))
            Circle().fill(Color(hex: 0xFF5C5C)).frame(width: 8, height: 8)
        }
    }
}

@View
struct ProgressRing {
    let progress: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.fill, lineWidth: 10)
            PathShape { size in
                let c = Point(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) / 2 - 5
                return arc(center: c, radius: r, from: -.pi / 2, to: -.pi / 2 + progress * 2 * .pi)
            }
            .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
        }
    }
}

// MARK: - Screen

@View
struct PomodoroView {
    @State private var session = Session()
    @State private var now = Date()
    @Environment(\.colorScheme) private var system

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 28) {
                timerPanel
                clockPanel
            }
        }
        .padding(horizontal: 28, vertical: 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .colorScheme(AppearanceModel.shared.appearance.scheme ?? system)
        .onAppear {
            Ticker.shared.start {
                now = Date()
                session.tick()
            }
        }
    }

    var timerPanel: some View {
        VStack(spacing: 20) {
            Text(session.phase.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(session.phase.color)
                .padding(horizontal: 12, vertical: 5)
                .background(session.phase.color.opacity(0.15))
                .cornerRadius(12)

            ZStack {
                ProgressRing(progress: session.progress, color: session.phase.color)
                VStack(spacing: 4) {
                    Text(clockText(session.remaining))
                        .font(.system(size: 52, weight: .light, design: .monospaced))
                    Text(session.isRunning ? "running" : "paused")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 260, height: 260)

            HStack(spacing: 10) {
                Button(session.isRunning ? "Pause" : "Start") { session.isRunning.toggle() }
                    .tint(session.phase.color)
                Button("Reset") { session.reset() }
                    .tint(Theme.muted)
                Button("Skip") { session.skip() }
                    .tint(Theme.muted)
            }

            HStack(spacing: 6) {
                ForEach(0..<4) { i in
                    Circle()
                        .fill(i < session.completed % 4 ? Phase.focus.color : Color.fill)
                        .frame(width: 10, height: 10)
                }
                Text("\(session.completed) done")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.leading, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        .cornerRadius(16)
    }

    var clockPanel: some View {
        VStack(spacing: 16) {
            ClockFace(now: now)
                .frame(width: 240, height: 240)
            Text(timeOfDay)
                .font(.system(size: 22, weight: .medium, design: .monospaced))
            Text(dayText)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        .cornerRadius(16)
    }

    func clockText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    var timeOfDay: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: now)
    }

    var dayText: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: now)
    }
}

@main
struct PomodoroApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Pomodoro", width: 760, height: 520) {
            PomodoroView()
        }
        .commands { AppearanceCommands() }
    }
}
