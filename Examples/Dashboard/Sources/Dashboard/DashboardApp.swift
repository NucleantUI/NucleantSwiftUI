//
//  DashboardApp.swift
//  Dashboard
//
//  An analytics screen: stat tiles, a line chart, a bar chart and a ring,
//  all drawn with the framework's shapes — `PathShape` for the lines and
//  arcs, `.relativeSize` for the bars — over a period selector that swaps
//  the data underneath. Nothing here is a chart library; it is the kind of
//  drawing an app does itself.
//

import Foundation
import NucleantSwiftUI

// MARK: - Data

enum Period: CaseIterable {
    case week, month, year

    var name: String {
        switch self {
        case .week:  return "7 days"
        case .month: return "30 days"
        case .year:  return "12 months"
        }
    }

    /// Deterministic pseudo-data, so the screen looks the same every run.
    var series: [Double] {
        let count: Int
        let base: Double
        switch self {
        case .week:  count = 7;  base = 320
        case .month: count = 30; base = 280
        case .year:  count = 12; base = 260
        }
        return (0..<count).map { i in
            let t = Double(i) / Double(max(count - 1, 1))
            let trend = base + 140 * t
            let wobble = 60 * sin(Double(i) * 1.7) + 30 * cos(Double(i) * 0.6)
            return max(40, trend + wobble)
        }
    }

    var labels: [String] {
        switch self {
        case .week:  return ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        case .month: return (1...30).map { $0 % 5 == 0 ? "\($0)" : "" }
        case .year:  return ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"]
        }
    }
}

struct Source: Identifiable {
    let id: Int
    let name: String
    let share: Double
    let color: Color
}

let sources = [
    Source(id: 0, name: "Direct", share: 0.42, color: Color(hex: 0x4C8DFF)),
    Source(id: 1, name: "Search", share: 0.31, color: Color(hex: 0x3DD68C)),
    Source(id: 2, name: "Social", share: 0.17, color: Color(hex: 0xFFB020)),
    Source(id: 3, name: "Other",  share: 0.10, color: Color(hex: 0xB57BFF)),
]

struct Event: Identifiable {
    let id: Int
    let when: String
    let what: String
    let color: Color
}

let events = [
    Event(id: 0, when: "09:12", what: "Deploy v2.4.1 finished", color: Color(hex: 0x3DD68C)),
    Event(id: 1, when: "08:40", what: "Error rate above 1% for 3 min", color: Color(hex: 0xFF5C5C)),
    Event(id: 2, when: "07:55", what: "New sign-up wave from campaign", color: Color(hex: 0x4C8DFF)),
    Event(id: 3, when: "06:30", what: "Nightly backup completed", color: Color(hex: 0x6C7A89)),
    Event(id: 4, when: "02:10", what: "Cache warmed after restart", color: Color(hex: 0xFFB020)),
    Event(id: 5, when: "00:00", what: "Daily rollup generated", color: Color(hex: 0x6C7A89)),
]

struct Theme {
    static let background = Color.background
    static let card = Color.secondaryBackground
    static let grid = Color.separator
    static let accent = Color(hex: 0x4C8DFF)
}

// MARK: - Charts

/// The series as a line with a soft fill under it. Axis-free by design; the
/// tick labels sit in the parent so the chart is just the drawing.
@View
struct LineChart {
    let values: [Double]
    let color: Color

    var body: some View {
        ZStack {
            // Three horizontal grid lines.
            PathShape { size in
                var path = Path()
                for i in 1...3 {
                    let y = size.height * Double(i) / 4
                    path.move(to: Point(x: 0, y: y))
                    path.addLine(to: Point(x: size.width, y: y))
                }
                return path
            }
            .stroke(Theme.grid, lineWidth: 1)

            PathShape { size in
                var path = linePath(in: size)
                guard !values.isEmpty else { return path }
                path.addLine(to: Point(x: size.width, y: size.height))
                path.addLine(to: Point(x: 0, y: size.height))
                path.closeSubpath()
                return path
            }
            .fill(.linearGradient(
                colors: [color.opacity(0.35), color.opacity(0)],
                startPoint: .top, endPoint: .bottom
            ))

            PathShape { size in linePath(in: size) }
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
    }

    private func linePath(in size: Size) -> Path {
        var path = Path()
        let points = plotted(in: size)
        guard let first = points.first else { return path }
        path.move(to: first)
        // Smooth with a midpoint curve between neighbours.
        for i in 1..<points.count {
            let previous = points[i - 1]
            let point = points[i]
            let mid = Point(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
            path.addCurve(to: point,
                          control1: Point(x: mid.x, y: previous.y),
                          control2: Point(x: mid.x, y: point.y))
        }
        return path
    }

    private func plotted(in size: Size) -> [Point] {
        guard values.count > 1 else { return [] }
        let top = (values.max() ?? 1) * 1.1
        return values.enumerated().map { i, value in
            Point(x: size.width * Double(i) / Double(values.count - 1),
                  y: size.height * (1 - value / top))
        }
    }
}

/// Vertical bars, one per value, each a fraction of the available height.
@View
struct BarChart {
    let values: [Double]
    let color: Color

    var body: some View {
        let top = (values.max() ?? 1)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(values.indices, id: \.self) { i in
                // A ZStack offers each child the whole cell, so the bar's
                // fraction is of the full height — in a VStack with a Spacer
                // it would be a fraction of the half the stack offers it.
                ZStack(alignment: .bottom) {
                    Color.clear
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i == values.count - 1 ? color : color.opacity(0.45))
                        .relativeSize(height: max(0.03, values[i] / top))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// A donut of arcs, one per source, drawn with Bézier arcs since `Path`
/// has no arc primitive of its own.
@View
struct Ring {
    let slices: [Source]
    let lineWidth: Double

    var body: some View {
        ZStack {
            ForEach(slices) { slice in
                PathShape { size in
                    let start = startAngle(of: slice)
                    return Ring.arc(in: size, from: start, to: start + slice.share * 2 * .pi,
                                    inset: lineWidth / 2)
                }
                .stroke(slice.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
        }
    }

    private func startAngle(of slice: Source) -> Double {
        var angle = -Double.pi / 2
        for other in slices {
            if other.id == slice.id { break }
            angle += other.share * 2 * .pi
        }
        // A hair of gap between slices.
        return angle + 0.02
    }

    /// A circular arc as cubic Béziers, at most a quarter turn each.
    static func arc(in size: Size, from start: Double, to end: Double, inset: Double) -> Path {
        var path = Path()
        let center = Point(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) / 2 - inset
        let sweep = end - start - 0.04
        guard sweep > 0 else { return path }
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
            let c1 = Point(x: p0.x - k * radius * sin(a0), y: p0.y + k * radius * cos(a0))
            let c2 = Point(x: p3.x + k * radius * sin(a1), y: p3.y - k * radius * cos(a1))
            path.addCurve(to: p3, control1: c1, control2: c2)
        }
        return path
    }
}

// MARK: - Cards

@View
struct StatTile {
    let title: String
    let value: String
    let delta: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote).foregroundColor(.secondary)
            Text(value).font(.system(size: 26, weight: .semibold))
            Text(String(format: "%@%.1f%%", delta >= 0 ? "▲ " : "▼ ", abs(delta)))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(delta >= 0 ? Color(hex: 0x3DD68C) : Color(hex: 0xFF5C5C))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .cornerRadius(12)
    }
}

@View
struct Card<Content: View> {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 14, weight: .semibold))
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card)
        .cornerRadius(12)
    }
}

// MARK: - Screen

@View
struct DashboardView {
    @State private var period = Period.week
    @State private var appearance = Appearance.system
    @Environment(\.colorScheme) private var system

    var body: some View {
        let series = period.series
        VStack(spacing: 14) {
            header

            HStack(spacing: 14) {
                StatTile(title: "Visitors", value: format(series.reduce(0, +)), delta: 12.4)
                StatTile(title: "Average", value: format(series.reduce(0, +) / Double(series.count)), delta: 3.1)
                StatTile(title: "Peak", value: format(series.max() ?? 0), delta: -1.8)
                StatTile(title: "Conversion", value: "3.9%", delta: 0.4)
            }

            HStack(spacing: 14) {
                // The left card is flexible and the right one fixed, so the
                // stack sizes the fixed one first and the chart gets the rest.
                Card("Traffic") {
                    LineChart(values: series, color: Theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack {
                        ForEach(period.labels.indices, id: \.self) { i in
                            Text(period.labels[i])
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }

                Card("Sources") {
                    HStack(spacing: 16) {
                        Ring(slices: sources, lineWidth: 18)
                            .frame(width: 120, height: 120)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(sources) { source in
                                HStack(spacing: 8) {
                                    Circle().fill(source.color).frame(width: 8, height: 8)
                                    Text(source.name).font(.footnote)
                                    Spacer()
                                    Text("\(Int(source.share * 100))%")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 14) {
                Card("Sessions") {
                    BarChart(values: series, color: Color(hex: 0x3DD68C))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Card("Activity") {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(events) { event in
                                HStack(alignment: .top, spacing: 10) {
                                    Circle().fill(event.color).frame(width: 8, height: 8)
                                        .padding(.top, 4)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(event.what).font(.footnote)
                                        Text(event.when)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .frame(width: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .colorScheme(appearance.scheme ?? system)
    }

    var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Overview").font(.system(size: 24, weight: .bold))
                Text("Last \(period.name)").font(.footnote).foregroundColor(.secondary)
            }
            Spacer()
            AppearancePicker(appearance: $appearance)
            HStack(spacing: 4) {
                ForEach(Period.allCases, id: \.self) { p in
                    Text(p.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(period == p ? .white : .secondary)
                        .padding(horizontal: 12, vertical: 6)
                        .background(period == p ? Theme.accent : Color.clear)
                        .cornerRadius(8)
                        .onTapGesture { period = p }
                }
            }
            .padding(3)
            .background(Theme.card)
            .cornerRadius(10)
        }
    }

    func format(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.1fk", value / 1000) : String(Int(value))
    }
}

@main
struct DashboardApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Dashboard", width: 1000, height: 700) {
            DashboardView()
        }
    }
}

