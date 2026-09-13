//
//  main.swift
//  NucleantSwiftUIDemo
//
//  A showcase of the framework's surface — the pure-Swift equivalent of
//  TouchBay's SDLUI_Demo, running on the Nucleant stack.
//

import NucleantSwiftUI

struct Palette {
    static let panel = Color(hex: 0x1C1F26)
    static let panelHighlight = Color(hex: 0x272B34)
    static let accent = Color(hex: 0x4C8DFF)
    static let good = Color(hex: 0x3DD68C)
    static let warn = Color(hex: 0xFFB020)
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
    }

    /// A track behind, a fill in front sized by `level`, and a drag that sets
    /// it. The hit area is taller than the visible bar so it can actually be
    /// grabbed; the bar itself stays 8pt.
    var fader: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color(white: 1, opacity: 0.08))
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
                    .tint(isEnabled ? Palette.accent : Color(white: 0.3))
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

@View
struct ContentView {
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
                    .tint(Color(white: 0.3))

                NavigationLink("Shaders") { ShaderGalleryScreen() }

                NavigationLink("Effects") { EffectsScreen() }

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
        .background(Color(hex: 0x11141A))
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
        }
    }
}

@main
struct DemoApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Nucleant SwiftUI Demo", width: 900, height: 620) {
            NavigationStack("Nucleant Mixer") {
                ContentView()
            }
            .background(Color(hex: 0x11141A))
        }
    }
}
