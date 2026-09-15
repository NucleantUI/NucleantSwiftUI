//
//  main.swift
//  NucleantSwiftUIDemo
//
//  A showcase of the framework's surface — the pure-Swift equivalent of
//  TouchBay's SDLUI_Demo, running on the Nucleant stack.
//

import NucleantSwiftUI

/// The demo's colors. Surfaces are the framework's semantic colors, which
/// have a light and a dark appearance each; the accents are fixed and read
/// on both. `muted` is a button tint for secondary actions — white text
/// needs a darker grey under it in light mode than in dark.
struct Palette {
    static let background = Color.background
    static let panel = Color.secondaryBackground
    static let panelHighlight = Color.tertiaryBackground
    static let track = Color.fill
    static let muted = Color.dynamic(light: Color(white: 0.55), dark: Color(white: 0.3))
    static let accent = Color(hex: 0x4C8DFF)
    static let good = Color(hex: 0x3DD68C)
    static let warn = Color(hex: 0xFFB020)
}

/// What the Appearance control offers: follow the system, or force one.
enum Appearance: CaseIterable {
    case system, light, dark

    var name: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

struct Track: Identifiable {
    let id: Int
    let name: String
    var level: Double
    let color: Color
}

let defaultTracks = [
    Track(id: 0, name: "Kick",    level: 0.82, color: Palette.accent),
    Track(id: 1, name: "Snare",   level: 0.54, color: Palette.good),
    Track(id: 2, name: "Hats",    level: 0.37, color: Palette.warn),
    Track(id: 3, name: "Bass",    level: 0.71, color: Color(hex: 0xB57BFF)),
    Track(id: 4, name: "Pad",     level: 0.28, color: Color(hex: 0xFF6F91)),
    Track(id: 5, name: "Lead",    level: 0.63, color: Color(hex: 0x36C5D6)),
    Track(id: 6, name: "FX",      level: 0.19, color: Color(hex: 0xE0E4EA)),
]

@View
struct TrackRow {
    let name: String
    let color: Color
    @Binding var level: Double

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)

            Text(name)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 70, alignment: .leading)

            fader

            Text("\(Int(level * 100))%")
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(horizontal: 16, vertical: 10)
        .background(Palette.panelHighlight)
        .cornerRadius(10)
        // Right-click (long press on touch) for the presets.
        .contextMenu {
            Button("Mute") { level = 0 }
            Button("Half") { level = 0.5 }
            Button("Full") { level = 1 }
            Divider()
            Button("Nudge up") { level = min(1, level + 0.05) }
            Button("Nudge down") { level = max(0, level - 0.05) }
        }
    }

    /// A track behind, a fill in front sized by `level`, and a drag that sets
    /// it. The hit area is taller than the visible bar so it can actually be
    /// grabbed; the bar itself stays 8pt.
    var fader: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Palette.track)
                .frame(height: 8)

            Capsule()
                .fill(.linearGradient(
                    colors: [color.opacity(0.6), color],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .relativeSize(width: level)
                .frame(height: 8)
        }
        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
        .gesture(
            DragGesture()
                .onChanged { value in
                    guard value.bounds.width > 0 else { return }
                    level = min(1, max(0, value.location.x / value.bounds.width))
                }
        )
    }
}

// MARK: - Shaders
//
// The shaders themselves live in the framework now (`ShaderLibrary`), the same
// way TouchBay kept its collection in a `Shaders` target. This screen only
// lists them.

struct ShaderEntry: Identifiable {
    let id: Int
    let name: String
    let blurb: String
    let function: ShaderFunction
}

@MainActor
let shaderGallery: [ShaderEntry] = ShaderLibrary.all.enumerated().map { index, entry in
    ShaderEntry(id: index, name: entry.name, blurb: entry.blurb, function: entry.function)
}

/// One shader, full screen.
@View
struct ShaderScreen {
    let entry: ShaderEntry

    var body: some View {
        VStack(spacing: 12) {
            Text(entry.blurb)
                .font(.footnote)
                .foregroundColor(.secondary)

            Shader(entry.function)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
    }
}

/// The gallery. Every row carries a *live* shader thumbnail, so this screen
/// alone runs one compute node per row — each its own GPU slot, composited
/// into its own rect.
@View
struct ShaderGalleryScreen {
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(shaderGallery.count) shaders, each its own GPU node — all running at once.")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                ForEach(shaderGallery) { entry in
                    
                    NavigationLink(title: entry.name) {
                        ShaderScreen(entry: entry)
                    } label: {
                        HStack(spacing: 14) {
                            Shader(entry.function)
                                .frame(width: 120, height: 68)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name)
                                    .font(.system(size: 16, weight: .medium))
                                Text(entry.blurb)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Text("›")
                                .font(.system(size: 20))
                                .foregroundColor(.secondary)
                        }
                        .padding(horizontal: 14, vertical: 10)
                        .background(Palette.panelHighlight)
                        .cornerRadius(12)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Effects
//
// The other direction: a view as the shader's *input*. Every row below draws
// the same small card into a canvas of its own and runs one of the library's
// effects over it — text, rounded corners and alpha all go through the
// texture. The screen behind a row is the mixer under that effect, still
// fully interactive.

struct EffectEntry: Identifiable {
    let id: Int
    let name: String
    let blurb: String
    let function: ShaderFunction
}

@MainActor
let effectGallery: [EffectEntry] = ShaderLibrary.effects.enumerated().map { index, entry in
    EffectEntry(id: index, name: entry.name, blurb: entry.blurb, function: entry.function)
}

/// The view every effect row is applied to.
@View
struct EffectPreviewCard {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nucleant")
                .font(.system(size: 16, weight: .semibold))
            HStack(spacing: 8) {
                Circle().fill(Palette.accent).frame(width: 12, height: 12)
                Capsule().fill(Palette.good).frame(width: 64, height: 8)
                Capsule().fill(Palette.warn).frame(width: 32, height: 8)
            }
            Text("the view as a texture")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(width: 200, height: 92, alignment: .leading)
        .background(Palette.panel)
        .cornerRadius(10)
    }
}

@View
struct EffectsScreen {
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(effectGallery.count) effects over the same card — each row is its own canvas, sampled by its own shader.")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                ForEach(effectGallery) { entry in
                    NavigationLink(title: entry.name) {
                        EffectScreen(entry: entry)
                    } label: {
                        HStack(spacing: 14) {
                            EffectPreviewCard()
                                .shader(entry.function)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name)
                                    .font(.system(size: 16, weight: .medium))
                                Text(entry.blurb)
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Text("›")
                                .font(.system(size: 20))
                                .foregroundColor(.secondary)
                        }
                        .padding(horizontal: 14, vertical: 10)
                        .background(Palette.panelHighlight)
                        .cornerRadius(12)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// The mixer under one effect. The faders and the counter keep working: the
/// effect changes what is drawn, not what is there.
@View
struct EffectScreen {
    let entry: EffectEntry
    @State private var isEnabled = true
    @State private var tracks = Array(defaultTracks.prefix(4))

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(entry.blurb)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                Button(isEnabled ? "Effect on" : "Effect off") { isEnabled.toggle() }
                    .tint(isEnabled ? Palette.accent : Palette.muted)
            }

            VStack(spacing: 8) {
                Counter()
                ForEach(tracks.indices, id: \.self) { index in
                    TrackRow(
                        name: tracks[index].name,
                        color: tracks[index].color,
                        level: $tracks[index].level
                    )
                }
            }
            .padding(16)
            .background(Palette.panel)
            .cornerRadius(14)
            .shader(entry.function, isEnabled: isEnabled)

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Drag and drop
//
// A `Transferable` payload carried from a `.draggable` to a
// `.dropDestination`. The transfer goes through the payload's
// representations — the track below is JSON on the way across, and its name
// travels as plain text as well, so a text-only destination can take it.

/// A track as a drag payload. `Codable`, so JSON is its native form.
struct TrackItem: Codable, Identifiable, Transferable {
    let id: Int
    let name: String
    let hex: UInt32

    var color: Color { Color(hex: hex) }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
        ProxyRepresentation(exporting: \.name)
    }
}

let trackItems = [
    TrackItem(id: 0, name: "Kick",  hex: 0x4C8DFF),
    TrackItem(id: 1, name: "Snare", hex: 0x3DD68C),
    TrackItem(id: 2, name: "Hats",  hex: 0xFFB020),
    TrackItem(id: 3, name: "Bass",  hex: 0xB57BFF),
    TrackItem(id: 4, name: "Pad",   hex: 0xFF6F91),
]

/// One track as a small card — the palette entry and the preview that
/// follows the pointer are the same view.
@View
struct TrackChip {
    let item: TrackItem

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(item.color).frame(width: 10, height: 10)
            Text(item.name).font(.system(size: 14, weight: .medium))
        }
        .padding(horizontal: 12, vertical: 7)
        .background(Palette.panelHighlight)
        .cornerRadius(8)
    }
}

/// A destination for tracks. Lights up while a drag it can take is over it.
@View
struct Bus {
    let name: String
    @Binding var tracks: [TrackItem]
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name).font(.system(size: 15, weight: .semibold))
                Spacer()
                if !tracks.isEmpty {
                    Text("\(tracks.count)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            if tracks.isEmpty {
                Text("Drop tracks here")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(tracks) { track in
                TrackChip(item: track)
                    .draggable(track)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isTargeted ? Palette.accent.opacity(0.25) : Palette.panel)
        .border(isTargeted ? Palette.accent : Color.clear, width: 2, cornerRadius: 12)
        .cornerRadius(12)
        .dropDestination(for: TrackItem.self) { dropped, _ in
            // A track already on this bus stays where it is.
            let new = dropped.filter { item in !tracks.contains { $0.id == item.id } }
            tracks.append(contentsOf: new)
            return !new.isEmpty
        } isTargeted: { over in
            isTargeted = over
        }
    }
}

@View
struct DragDropScreen {
    @State private var busA: [TrackItem] = []
    @State private var busB: [TrackItem] = []
    @State private var notes: [String] = []
    @State private var notesTargeted = false
    @State private var lastDrop: Point? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Drag a track onto a bus. The tracks cross as JSON; the notes box takes plain text, which a track also is — and so is the label at the bottom.")
                .font(.footnote)
                .foregroundColor(.secondary)

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tracks").font(.system(size: 15, weight: .semibold))
                    ForEach(trackItems) { item in
                        TrackChip(item: item)
                            .draggable(item)
                    }
                    Spacer()
                }
                .padding(12)
                .frame(width: 150)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(Palette.panel)
                .cornerRadius(12)

                Bus(name: "Bus A", tracks: $busA)
                Bus(name: "Bus B", tracks: $busB)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(alignment: .top, spacing: 14) {
                notesBox

                VStack(alignment: .leading, spacing: 8) {
                    Text("drop me as text")
                        .font(.system(size: 14, weight: .medium))
                        .padding(horizontal: 12, vertical: 7)
                        .background(Palette.good.opacity(0.3))
                        .cornerRadius(8)
                        .draggable("a note from the label") {
                            Text("a note")
                                .padding(horizontal: 10, vertical: 6)
                                .background(Palette.good)
                                .cornerRadius(6)
                        }
                    Button("Clear") {
                        busA.removeAll()
                        busB.removeAll()
                        notes.removeAll()
                        lastDrop = nil
                    }
                    .tint(Palette.muted)
                }
            }
            .frame(height: 110)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Takes any drag that can be text: a track (through its proxy) or the
    /// label. Shows where the last one landed, in its own coordinates.
    var notesBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Notes").font(.system(size: 15, weight: .semibold))
                Spacer()
                if let lastDrop {
                    Text("last drop at \(Int(lastDrop.x)), \(Int(lastDrop.y))")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            Text(notes.isEmpty ? "Drop text here" : notes.joined(separator: " · "))
                .font(.footnote)
                .foregroundColor(notes.isEmpty ? .secondary : .primary)
                .lineLimit(3)
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(notesTargeted ? Palette.good.opacity(0.25) : Palette.panel)
        .border(notesTargeted ? Palette.good : Color.clear, width: 2, cornerRadius: 12)
        .cornerRadius(12)
        .dropDestination(for: String.self) { strings, location in
            notes.append(contentsOf: strings)
            lastDrop = location
            return true
        } isTargeted: { over in
            notesTargeted = over
        }
    }
}

@View
struct AboutScreen {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("NucleantSwiftUI").font(.title2)
            Text("SwiftUI-shaped views over NucleantApplication, NucleantVulkan and NucleantThorVG.")
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@View
struct Counter {
    @State private var count = 0

    var body: some View {
        HStack(spacing: 16) {
            Button("−") { count -= 1 }
            Text("\(count)")
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .frame(width: 80, alignment: .center)
            Button("+") { count += 1 }
        }
    }
}

/// System / Light / Dark. A segmented control from tap targets — the
/// selected segment takes the tint, the others the panel color.
@View
struct AppearancePicker {
    @Binding var appearance: Appearance

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Appearance.allCases, id: \.self) { choice in
                Text(choice.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(appearance == choice ? .white : .secondary)
                    .padding(horizontal: 10, vertical: 5)
                    .background(appearance == choice ? Palette.accent : Color.clear)
                    .cornerRadius(6)
                    .onTapGesture { appearance = choice }
            }
        }
        .padding(2)
        .background(Palette.panelHighlight)
        .cornerRadius(8)
    }
}

@View
struct ContentView {
    @Binding var appearance: Appearance
    @State private var showDetails = true
    @State private var tracks = defaultTracks

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            Counter()
                .frame(maxWidth: .infinity, alignment: .center)

            HStack(spacing: 12) {
                Button(showDetails ? "Hide mixer" : "Show mixer") {
                    showDetails.toggle()
                }
                .tint(Palette.accent)

                Button("Reset") { tracks = defaultTracks }
                    .tint(Palette.muted)

                NavigationLink("Shaders") { ShaderGalleryScreen() }

                NavigationLink("Effects") { EffectsScreen() }

                NavigationLink("Drag & drop") { DragDropScreen() }

                NavigationLink("About") { AboutScreen() }

                Spacer()

                Text("NucleantSwiftUI \(NucleantSwiftUI.version)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Divider()

            if showDetails {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach(tracks.indices, id: \.self) { index in
                            TrackRow(
                                name: tracks[index].name,
                                color: tracks[index].color,
                                level: $tracks[index].level
                            )
                        }
                    }
                }
            } else {
                VStack {
                    Spacer()
                    Text("Mixer hidden")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.background)
    }

    var header: some View {
        HStack(alignment: .center, spacing: 14) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.linearGradient(
                    colors: [Palette.accent, Color(hex: 0xB57BFF)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("Nucleant Mixer")
                    .font(.system(size: 22, weight: .bold))
                Text("SwiftUI-shaped views, ThorVG on Vulkan")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Spacer()

            AppearancePicker(appearance: $appearance)
        }
    }
}

/// The root: owns the appearance choice and applies it under itself, so
/// the whole tree — navigation bar included — resolves its colors against
/// the chosen scheme. "System" hands down what the window was seeded with,
/// which follows System Settings as it changes.
@View
struct RootView {
    @State private var appearance = Appearance.system
    @Environment(\.colorScheme) private var system

    var body: some View {
        NavigationStack("Nucleant Mixer") {
            ContentView(appearance: $appearance)
        }
        .background(Palette.background)
        .colorScheme(appearance.scheme ?? system)
    }
}

@main
struct DemoApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Nucleant SwiftUI Demo", width: 900, height: 620) {
            RootView()
        }
    }
}
