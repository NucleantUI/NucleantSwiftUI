//
//  SamplerApp.swift
//  Sampler
//
//  A drum-pad sampler: eight synthesised sounds, a waveform display drawn
//  by a shader from a min/max envelope, trim and gain controls, and real
//  playback.
//
//  What it is here to show:
//
//  * `@Observable` models as the source of truth. Views hold plain
//    references (`let sample: Sample`) and read properties in `body`; a
//    write anywhere — a drag, a button, a background analysis finishing,
//    a 60 Hz playhead timer — rebuilds exactly the views that read it.
//  * `@Bindable` for two-way controls: the gain fader takes `$sample.gain`.
//  * `ShaderArgument`s: the envelope's two float arrays, the gain, the trim
//    and the playhead go to the GPU as named inputs, and the shader
//    re-dispatches whenever one of them changes.
//  * Accelerate on the CPU side: vDSP for synthesis and for the parallel
//    min/max reduction (Model.swift).
//

import Foundation
import NucleantSwiftUI

struct Theme {
    static let background = Color.background
    static let panel = Color.secondaryBackground
    static let pad = Color.tertiaryBackground
    /// Behind the waveform — handed to the shader as a `.color` argument,
    /// which resolves it for the scheme in effect like any other color.
    static let wave = Color.dynamic(light: Color(hex: 0xE4E6EC), dark: Color(hex: 0x14161C))
    static let muted = Color.dynamic(light: Color(white: 0.55), dark: Color(white: 0.3))
}

// MARK: - Waveform

/// The envelope shader. `mins(i)` / `maxs(i)` and `minsCount` come from
/// the `.floatArray` arguments; `gain`, `trimStart`, `trimEnd`, `playhead`
/// and `tint` from the scalar ones. Shader space is y-up, so `uv.y == 1` is
/// the top of the view and a positive sample fills the upper half.
///
/// The envelope is read at a fractional index and interpolated between
/// its two neighbours, so the edge is a polyline through the points
/// rather than a flat step per point — the points rarely line up one per
/// pixel column, and picking the nearest one draws stairs. The edge is
/// then softened over one pixel of height.
let envelopeShader = ShaderFunction("""
    float position = uv.x * float(minsCount) - 0.5;
    int i0 = int(floor(position));
    float t = fract(position);
    float lo = mix(mins(i0), mins(i0 + 1), t) * gain;
    float hi = mix(maxs(i0), maxs(i0 + 1), t) * gain;

    float py = 1.0 / resolution.y;
    float alpha;
    if (uv.y >= 0.5) {
        float edge = clamp((hi + 1.0) * 0.5, 0.0, 1.0);
        alpha = 1.0 - smoothstep(edge - py, edge + py, uv.y);
    } else {
        float edge = clamp((lo + 1.0) * 0.5, 0.0, 1.0);
        alpha = smoothstep(edge - py, edge + py, uv.y);
    }

    // Dim what the trim leaves out, and mark the trim edges.
    float inside = step(trimStart, uv.x) * step(uv.x, trimEnd);
    vec3 wave = mix(tint.rgb * 0.3, tint.rgb, inside);
    float px = 1.0 / resolution.x;
    float edges = max(1.0 - smoothstep(0.0, 1.5 * px, abs(uv.x - trimStart)),
                      1.0 - smoothstep(0.0, 1.5 * px, abs(uv.x - trimEnd)));

    vec3 background = paper.rgb;
    float centre = 1.0 - smoothstep(0.0, 1.0 / resolution.y, abs(uv.y - 0.5));
    vec3 color = mix(background, wave, alpha);
    color = mix(color, tint.rgb * 0.5, centre * 0.6);
    color = mix(color, tint.rgb, edges * 0.8);

    if (playhead >= 0.0) {
        float head = 1.0 - smoothstep(0.0, 1.5 * px, abs(uv.x - playhead));
        color = mix(color, vec3(1.0), head);
    }
    fragColor = vec4(color, 1.0);
""")

/// The waveform of one sample, with the trim points draggable over it.
@View
struct WaveformView {
    @Bindable var sample: Sample
    let playhead: Double?

    var body: some View {
        // Read here, in body, so the envelope filling in is a change this
        // view is registered for; an empty envelope draws as silence.
        let negatives = sample.envelope?.negatives ?? []
        let positives = sample.envelope?.positives ?? []

        // No overlay inside: a `Shader` composites over the canvas, so a
        // label stacked on it would be hidden. The editor's header carries
        // the status instead.
        Shader(envelopeShader, arguments: [
                .floatArray("mins", negatives),
                .floatArray("maxs", positives),
                .float("gain", Float(sample.gain)),
                .float("trimStart", Float(sample.trimStart)),
                .float("trimEnd", Float(sample.trimEnd)),
                .float("playhead", Float(playhead ?? -1)),
                .color("tint", sample.color),
                .color("paper", Theme.wave),
            ])
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gesture(
            DragGesture()
                .onChanged { value in
                    guard value.bounds.width > 0 else { return }
                    let x = min(1, max(0, value.location.x / value.bounds.width))
                    let startAt = value.startLocation.x / value.bounds.width
                    // Whichever trim edge was nearer when the drag began.
                    if abs(startAt - sample.trimStart) <= abs(startAt - sample.trimEnd) {
                        sample.trimStart = min(x, sample.trimEnd - 0.01)
                    } else {
                        sample.trimEnd = max(x, sample.trimStart + 0.01)
                    }
                }
        )
    }
}

// MARK: - Controls

/// A horizontal fader over a `Binding<Double>` in `range`.
@View
struct Fader {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let color: Color
    let format: (Double) -> String

    var body: some View {
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 44, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.fill).frame(height: 8)
                Capsule()
                    .fill(.linearGradient(colors: [color.opacity(0.6), color], startPoint: .leading, endPoint: .trailing))
                    .relativeSize(width: max(0.01, fraction))
                    .frame(height: 8)
            }
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
            .gesture(
                DragGesture().onChanged { drag in
                    guard drag.bounds.width > 0 else { return }
                    let t = min(1, max(0, drag.location.x / drag.bounds.width))
                    value = range.lowerBound + t * (range.upperBound - range.lowerBound)
                }
            )
            Text(format(value))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
    }
}

@View
struct Pad {
    let sample: Sample
    let isSelected: Bool
    let isTriggered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(sample.color).frame(width: 10, height: 10)
                Text(sample.name).font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            Text(sample.isRendering ? "rendering…"
                 : sample.envelope?.isReady == true
                     ? String(format: "%.2fs · take %d", sample.duration, sample.variant)
                     : "analysing…")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(isTriggered ? sample.color.opacity(0.35) : Theme.pad)
        .cornerRadius(10)
        .border(isSelected ? sample.color : Color.clear, width: 2, cornerRadius: 10)
    }
}

// MARK: - Editor

/// The selected sample's controls. `@Bindable` makes `$sample.gain` a
/// binding straight into the object; every other read is tracked too, so
/// "Resample" — which swaps in a new envelope — redraws the readout here
/// and the waveform, and nothing else.
@View
struct SampleEditor {
    @Bindable var sample: Sample
    let bank: SampleBank
    let player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(sample.color).frame(width: 12, height: 12)
                Text(sample.name).font(.system(size: 20, weight: .bold))
                Text(sample.isRendering ? "rendering…"
                     : sample.envelope?.isReady == true
                         ? String(format: "%.2fs of %.2fs", sample.trimmedDuration, sample.duration)
                         : "analysing…")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Play") { player.play(sample, in: bank) }
                    .tint(sample.color)
                Button("Resample") { sample.resample() }
                    .tint(Theme.muted)
                Button("Reset trim") {
                    sample.trimStart = 0
                    sample.trimEnd = 1
                }
                .tint(Theme.muted)
            }

            WaveformView(sample: sample, playhead: bank.playhead)
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
                .cornerRadius(10)

            Fader(title: "Gain", value: $sample.gain, range: 0...2, color: sample.color) {
                String(format: "%+.1f dB", 20 * log10(max($0, 0.001)))
            }
            Fader(title: "Start", value: $sample.trimStart, range: 0...1, color: sample.color) {
                String(format: "%.2fs", $0 * sample.duration)
            }
            Fader(title: "End", value: $sample.trimEnd, range: 0...1, color: sample.color) {
                String(format: "%.2fs", $0 * sample.duration)
            }
        }
        .padding(16)
        .background(Theme.panel)
        .cornerRadius(14)
    }
}

// MARK: - Screen

@View
struct SamplerView {
    let bank: SampleBank
    let player: Player
    @Environment(\.colorScheme) private var system

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sampler").font(.system(size: 26, weight: .bold))
                    Text("Tap a pad to select and play it. Drag on the waveform to trim.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(bank.playhead.map { String(format: "playing %3.0f%%", $0 * 100) } ?? "stopped")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            pads

            SampleEditor(sample: bank.selected, bank: bank, player: player)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .colorScheme(AppearanceModel.shared.appearance.scheme ?? system)
    }

    var pads: some View {
        VStack(spacing: 8) {
            ForEach(0..<2) { row in
                HStack(spacing: 8) {
                    ForEach(bank.samples[(row * 4)..<(row * 4 + 4)]) { sample in
                        Pad(
                            sample: sample,
                            isSelected: sample.id == bank.selectedID,
                            isTriggered: sample.id == bank.lastTriggeredID
                        )
                        .onTapGesture {
                            bank.selectedID = sample.id
                            player.play(sample, in: bank)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 72, maxHeight: 72)
            }
        }
    }
}

@main
struct SamplerApp: NucleantApp {
    var body: some Scene {
        WindowGroup("Sampler", width: 860, height: 640) {
            SamplerView(bank: SampleBank(), player: Player())
        }
        .commands { AppearanceCommands() }
    }
}
