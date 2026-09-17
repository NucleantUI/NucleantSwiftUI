//
//  SketchApp.swift
//  Sketch
//
//  A drawing pad. A DragGesture over the canvas collects points into the
//  stroke in progress; finished strokes are `PathShape`s stacked in a
//  ZStack. Colour swatches and brush sizes are custom tap targets, undo and
//  clear are plain Buttons.
//

import NucleantSwiftUI

// MARK: - Model

struct Stroke: Identifiable {
    let id: Int
    var points: [Point]
    let color: Color
    let width: Double

    /// The polyline through the points — a dot for a single tap.
    func path(in size: Size) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        if points.count == 1 {
            let r = width / 2
            path.addEllipse(in: Rect(x: first.x - r, y: first.y - r, width: width, height: width))
            return path
        }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }
}

/// The first swatch is "ink": near-white on dark paper, near-black on light.
let swatches: [Color] = [
    Color.dynamic(light: Color(hex: 0x1C1F26), dark: Color(hex: 0xF5F5F7)),
    Color(hex: 0xFF5C5C), Color(hex: 0xFF9F0A), Color(hex: 0xFFD60A),
    Color(hex: 0x3DD68C), Color(hex: 0x4C8DFF), Color(hex: 0xB57BFF), Color(hex: 0x6C7A89),
]

let brushSizes: [Double] = [2, 5, 10, 18]

struct Theme {
    static let background = Color.background
    static let paper = Color.dynamic(light: Color.white, dark: Color(hex: 0x20232B))
    static let panel = Color.secondaryBackground
    static let muted = Color.dynamic(light: Color(white: 0.55), dark: Color(white: 0.3))
}

// MARK: - Canvas

@View
struct Canvas {
    @Binding var strokes: [Stroke]
    @Binding var current: Stroke?
    let color: Color
    let width: Double

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.paper)

            ForEach(strokes) { stroke in
                StrokeView(stroke: stroke)
            }
            if let current {
                StrokeView(stroke: current)
            }
        }
        .cornerRadius(12)
        .gesture(
            DragGesture()
                .onChanged { value in
                    // The first change is the press itself: start the stroke
                    // there. Later ones extend it.
                    if current == nil {
                        let id = (strokes.last?.id ?? 0) + 1
                        current = Stroke(id: id, points: [value.location], color: color, width: width)
                    } else {
                        current?.points.append(value.location)
                    }
                }
                .onEnded { _ in
                    if let stroke = current {
                        strokes.append(stroke)
                    }
                    current = nil
                }
        )
    }
}

/// One stroke, as a view. Split out so a finished stroke — whose inputs
/// never change — is reused by the framework rather than rebuilt every
/// time the stroke in progress grows.
@View
struct StrokeView {
    let stroke: Stroke

    var body: some View {
        PathShape { size in stroke.path(in: size) }
            .stroke(stroke.color, style: StrokeStyle(
                lineWidth: stroke.width, lineCap: .round, lineJoin: .round
            ))
    }
}

extension Stroke: Equatable {}

// MARK: - Tools

@View
struct Swatch {
    let color: Color
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(isSelected ? Color.primary : Color.clear, lineWidth: 2)
                .frame(width: 30, height: 30)
            Circle()
                .fill(color)
                .frame(width: 22, height: 22)
        }
    }
}

@View
struct BrushDot {
    let size: Double
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.fill : Color.clear)
                .frame(width: 34, height: 34)
            Circle()
                .fill(Color.primary)
                .frame(width: size + 2, height: size + 2)
        }
    }
}

// MARK: - Screen

@View
struct SketchView {
    @State private var strokes: [Stroke] = []
    @State private var current: Stroke? = nil
    @State private var color = swatches[0]
    @State private var width = brushSizes[1]
    @Environment(\.colorScheme) private var system

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            Canvas(strokes: $strokes, current: $current, color: color, width: width)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .colorScheme(AppearanceModel.shared.appearance.scheme ?? system)
    }

    var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(swatches.indices, id: \.self) { index in
                    Swatch(color: swatches[index], isSelected: swatches[index] == color)
                        .onTapGesture { color = swatches[index] }
                }
            }

            Divider().frame(height: 24)

            HStack(spacing: 2) {
                ForEach(brushSizes, id: \.self) { size in
                    BrushDot(size: size, isSelected: size == width)
                        .onTapGesture { width = size }
                }
            }

            Spacer()

            Button("Undo") { _ = strokes.popLast() }
                .tint(Theme.muted)
                .disabled(strokes.isEmpty)
            Button("Clear") { strokes.removeAll() }
                .tint(Color(hex: 0xC03A3A))
                .disabled(strokes.isEmpty)
        }
        .padding(horizontal: 12, vertical: 8)
        .background(Theme.panel)
        .cornerRadius(12)
    }
}

@main
struct SketchApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Sketch", width: 900, height: 640) {
            SketchView()
        }
        .commands { AppearanceCommands() }
    }
}
