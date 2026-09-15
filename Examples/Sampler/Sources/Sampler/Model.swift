//
//  Model.swift
//  Sampler
//
//  The data side: `@Observable` classes the views read directly. A view that
//  reads `sample.gain` in its body is rebuilt when `gain` changes — through
//  a `$sample.gain` binding, from a button, or from a background task that
//  finished analysing a waveform — with no `@State` copy in between.
//

import Accelerate
import Foundation
import Observation
import NucleantSwiftUI

// MARK: - Envelope

/// A min/max envelope of a sample, the shape the waveform shader draws:
/// `resolution` points, each the extremes of one slice of the frames.
///
/// The reduction runs on a GCD global queue — `vDSP_minv`/`vDSP_maxv` over
/// each slice, slices in parallel with `concurrentPerform`, every iteration
/// writing its own index of a raw buffer so no lock is needed — and the
/// result is assigned back on the main queue. That assignment is what
/// redraws the waveform: the view read `negatives` while it was empty, and
/// observation brings it back.
///
/// GCD rather than a `Task`: `concurrentPerform` blocks the thread it is
/// called on until every iteration is done, which is fine for a global
/// queue's worker and is not for one of Swift concurrency's cooperative
/// threads — a detached task doing this was seen never to run at all.
@MainActor
@Observable
final class WaveformEnvelope {
    private(set) var negatives: [Float] = []
    private(set) var positives: [Float] = []
    private(set) var isReady = false

    /// 2048 points: more than the waveform has pixel columns at any
    /// window size it is likely to get, so the shader's interpolation is
    /// between points closer together than the pixels it draws.
    init(frames: [Float], resolution: Int = 2048) {
        let pointCount = max(1, resolution)
        DispatchQueue.global(qos: .userInitiated).async {
            let (mins, maxs) = WaveformEnvelope.reduce(frames, into: pointCount)
            DispatchQueue.main.async {
                self.negatives = mins
                self.positives = maxs
                self.isReady = true
            }
        }
    }

    nonisolated private static func reduce(_ frames: [Float], into pointCount: Int) -> ([Float], [Float]) {
        guard !frames.isEmpty else {
            return ([Float](repeating: 0, count: pointCount), [Float](repeating: 0, count: pointCount))
        }
        let samplesPerPoint = max(1, frames.count / pointCount)
        let mins = UnsafeMutableBufferPointer<Float>.allocate(capacity: pointCount)
        let maxs = UnsafeMutableBufferPointer<Float>.allocate(capacity: pointCount)
        mins.initialize(repeating: 0)
        maxs.initialize(repeating: 0)
        defer {
            mins.deallocate()
            maxs.deallocate()
        }
        let minBox = SendableBuffer(mins)
        let maxBox = SendableBuffer(maxs)

        DispatchQueue.concurrentPerform(iterations: pointCount) { point in
            let start = point * samplesPerPoint
            guard start + samplesPerPoint <= frames.count else { return }
            frames.withUnsafeBufferPointer { buffer in
                let slice = buffer.baseAddress!.advanced(by: start)
                let length = vDSP_Length(samplesPerPoint)
                var low: Float = 0
                var high: Float = 0
                vDSP_minv(slice, 1, &low, length)
                vDSP_maxv(slice, 1, &high, length)
                // Distinct index per iteration — race-free with no lock.
                minBox.buffer[point] = min(low, 0)
                maxBox.buffer[point] = max(high, 0)
            }
        }
        return (Array(mins), Array(maxs))
    }
}

/// The concurrency checker cannot see that `concurrentPerform`'s iterations
/// touch disjoint indices; this says so, once, for the two buffers above.
private struct SendableBuffer: @unchecked Sendable {
    let buffer: UnsafeMutableBufferPointer<Float>
    init(_ buffer: UnsafeMutableBufferPointer<Float>) { self.buffer = buffer }
}

// MARK: - Sample

/// One pad's sound: its frames, how it is trimmed and how loud it plays.
///
/// The frames are synthesised (`Synth`) rather than loaded, so the example
/// has no files to find; "Resample" makes a new variant and re-analyses it,
/// which is the async path a real capture would take.
@MainActor
@Observable
final class Sample: Identifiable {
    let id: Int
    let name: String
    let color: Color
    let kind: Synth.Kind
    nonisolated static let sampleRate = 44_100.0

    private(set) var frames: [Float] = []
    private(set) var envelope: WaveformEnvelope?
    private(set) var variant = 0
    /// True from "Resample" until the new frames have been rendered.
    private(set) var isRendering = false

    /// Playback gain; `1` is unity. The waveform is drawn scaled by it.
    var gain: Double = 1
    /// Trim, as fractions of the sample's length.
    var trimStart: Double = 0
    var trimEnd: Double = 1

    init(id: Int, name: String, color: Color, kind: Synth.Kind) {
        self.id = id
        self.name = name
        self.color = color
        self.kind = kind
        resample()
    }

    var duration: Double { Double(frames.count) / Sample.sampleRate }

    var trimmedDuration: Double { duration * max(0, trimEnd - trimStart) }

    /// A fresh take: new frames, and a new envelope that starts empty and
    /// fills in when its analysis lands.
    ///
    /// Synthesis runs in a detached task and comes back through
    /// `MainActor.run` — the Swift-concurrency way to hand a result to an
    /// `@Observable` model, and the other half of what the envelope does
    /// with GCD. Both writes reach the views the same way: the views read
    /// these properties, so the writes rebuild them.
    func resample() {
        variant += 1
        isRendering = true
        let kind = kind, variant = variant
        Task.detached(priority: .userInitiated) {
            let frames = Synth.render(kind, variant: variant, sampleRate: Sample.sampleRate)
            await MainActor.run {
                self.frames = frames
                self.envelope = WaveformEnvelope(frames: frames)
                self.isRendering = false
            }
        }
    }

    /// The frames between the trim points, at `gain` — what plays.
    var playableFrames: [Float] {
        let lower = Int(Double(frames.count) * min(trimStart, trimEnd))
        let upper = Int(Double(frames.count) * max(trimStart, trimEnd))
        guard upper > lower else { return [] }
        var out = Array(frames[lower..<upper])
        var scale = Float(gain)
        vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(out.count))
        return out
    }
}

// MARK: - Bank

/// The pads, which one is selected, and what is playing.
@MainActor
@Observable
final class SampleBank {
    let samples: [Sample]
    var selectedID: Int
    /// Position of the playhead within the selected sample's trim, 0…1,
    /// while something plays; `nil` otherwise. Written by the player's
    /// timer, read by the waveform — observation carries each step across.
    var playhead: Double? = nil
    /// The pad last triggered, for its flash.
    var lastTriggeredID: Int? = nil

    init() {
        samples = [
            Sample(id: 0, name: "Kick",  color: Color(hex: 0x4C8DFF), kind: .kick),
            Sample(id: 1, name: "Snare", color: Color(hex: 0xFF5C5C), kind: .snare),
            Sample(id: 2, name: "Hat",   color: Color(hex: 0xFFD60A), kind: .hat),
            Sample(id: 3, name: "Clap",  color: Color(hex: 0xFF9F0A), kind: .clap),
            Sample(id: 4, name: "Bass",  color: Color(hex: 0xB57BFF), kind: .bass),
            Sample(id: 5, name: "Pluck", color: Color(hex: 0x3DD68C), kind: .pluck),
            Sample(id: 6, name: "Pad",   color: Color(hex: 0x36C5D6), kind: .pad),
            Sample(id: 7, name: "Noise", color: Color(hex: 0xE0E4EA), kind: .noise),
        ]
        selectedID = 0
    }

    var selected: Sample { samples.first { $0.id == selectedID } ?? samples[0] }
}

// MARK: - Synthesis

/// Drum-machine sounds made with Accelerate: ramps from `vDSP_vramp`, sines
/// from `vvsinf`, envelopes multiplied in with `vDSP_vmul`, and a tiny
/// xorshift for noise. Deterministic per variant, so "Resample" is a
/// different take every time and the same take every run.
enum Synth {
    enum Kind { case kick, snare, hat, clap, bass, pluck, pad, noise }

    static func render(_ kind: Kind, variant: Int, sampleRate: Double) -> [Float] {
        var rng = XorShift(seed: UInt32(truncatingIfNeeded: 0x9E37 &+ variant &* 7919 &+ kindSeed(kind)))
        let sr = Float(sampleRate)
        switch kind {
        case .kick:
            let n = Int(sr * 0.5)
            // Pitch sweep 150→45 Hz over 80 ms with an exponential decay.
            let f0: Float = 130 + rng.next(in: 0...40), f1: Float = 42
            var phase: Float = 0
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let t = Float(i) / sr
                let f = f1 + (f0 - f1) * exp(-t * 28)
                phase += 2 * .pi * f / sr
                out[i] = sin(phase)
            }
            return multiply(out, by: decay(n, seconds: 0.35 + rng.next(in: 0...0.1), sampleRate: sr))
        case .snare:
            let n = Int(sr * 0.3)
            let tone = multiply(sine(n, hz: 180 + rng.next(in: 0...40), sampleRate: sr), by: decay(n, seconds: 0.08, sampleRate: sr))
            let hiss = multiply(noise(n, &rng), by: decay(n, seconds: 0.16 + rng.next(in: 0...0.08), sampleRate: sr))
            return mix(tone, 0.7, hiss, 0.8)
        case .hat:
            let n = Int(sr * 0.12)
            // Noise with a crude high-pass: differentiate.
            var white = noise(n, &rng)
            vDSP_vsub(white, 1, Array(white.dropFirst()) + [0], 1, &white, 1, vDSP_Length(n))
            return multiply(white, by: decay(n, seconds: 0.03 + rng.next(in: 0...0.04), sampleRate: sr))
        case .clap:
            let n = Int(sr * 0.35)
            // Three short bursts then a tail.
            var out = [Float](repeating: 0, count: n)
            let white = noise(n, &rng)
            for burst in 0..<3 {
                let start = Int(Float(burst) * 0.011 * sr)
                let env = decay(n, seconds: 0.012, sampleRate: sr)
                for i in start..<n { out[i] += white[i] * env[i - start] * 0.6 }
            }
            let tail = multiply(white, by: decay(n, seconds: 0.12 + rng.next(in: 0...0.08), sampleRate: sr))
            return mix(out, 1, Array(repeating: 0, count: Int(0.03 * sr)) + tail, 0.5)
        case .bass:
            let n = Int(sr * 0.6)
            let hz: Float = [55, 58.27, 65.41, 73.42][Int(rng.next(in: 0...3.99))]
            // A saw from summed harmonics, filtered by the envelope's shape.
            var out = [Float](repeating: 0, count: n)
            for k in 1...12 {
                let h = sine(n, hz: hz * Float(k), sampleRate: sr)
                let amp = 1 / Float(k)
                out = mix(out, 1, h, amp)
            }
            return multiply(out, by: adsr(n, attack: 0.005, decayTo: 0.4, hold: 0.25, release: 0.2, sampleRate: sr))
        case .pluck:
            let n = Int(sr * 0.5)
            let hz: Float = [220, 261.63, 329.63, 392][Int(rng.next(in: 0...3.99))]
            let fundamental = sine(n, hz: hz, sampleRate: sr)
            let second = multiply(sine(n, hz: hz * 2.01, sampleRate: sr), by: decay(n, seconds: 0.08, sampleRate: sr))
            return multiply(mix(fundamental, 0.8, second, 0.5), by: decay(n, seconds: 0.25 + rng.next(in: 0...0.1), sampleRate: sr))
        case .pad:
            let n = Int(sr * 1.2)
            let root: Float = [110, 130.81, 146.83][Int(rng.next(in: 0...2.99))]
            let chord = mix(
                mix(sine(n, hz: root, sampleRate: sr), 0.5, sine(n, hz: root * 1.5, sampleRate: sr), 0.4),
                1,
                mix(sine(n, hz: root * 1.26, sampleRate: sr), 0.35, sine(n, hz: root * 2.003, sampleRate: sr), 0.25),
                1
            )
            // Slow tremolo so the envelope has some shape to it.
            let lfo = sine(n, hz: 3 + rng.next(in: 0...2), sampleRate: sr).map { 0.75 + 0.25 * $0 }
            return multiply(multiply(chord, by: lfo), by: adsr(n, attack: 0.2, decayTo: 0.8, hold: 0.5, release: 0.4, sampleRate: sr))
        case .noise:
            let n = Int(sr * 0.4)
            let white = noise(n, &rng)
            let sweep = (0..<n).map { i -> Float in
                let t = Float(i) / Float(n)
                return 0.2 + 0.8 * sin(t * .pi * (1 + rng.next(in: 0...0) + 2))
            }
            return multiply(white, by: sweep)
        }
    }

    private static func kindSeed(_ kind: Kind) -> Int {
        switch kind {
        case .kick: return 1
        case .snare: return 2
        case .hat: return 3
        case .clap: return 4
        case .bass: return 5
        case .pluck: return 6
        case .pad: return 7
        case .noise: return 8
        }
    }

    /// `sin(2π f t)` for `n` samples: a ramp of phases from `vDSP_vramp`,
    /// then `vvsinf` over the whole array at once.
    static func sine(_ n: Int, hz: Float, sampleRate: Float) -> [Float] {
        var phases = [Float](repeating: 0, count: n)
        var start: Float = 0
        var step = 2 * Float.pi * hz / sampleRate
        vDSP_vramp(&start, &step, &phases, 1, vDSP_Length(n))
        var out = [Float](repeating: 0, count: n)
        var count = Int32(n)
        vvsinf(&out, phases, &count)
        return out
    }

    /// `exp(-t / seconds)`.
    static func decay(_ n: Int, seconds: Float, sampleRate: Float) -> [Float] {
        var times = [Float](repeating: 0, count: n)
        var start: Float = 0
        var step = -1 / (seconds * sampleRate)
        vDSP_vramp(&start, &step, &times, 1, vDSP_Length(n))
        var out = [Float](repeating: 0, count: n)
        var count = Int32(n)
        vvexpf(&out, times, &count)
        return out
    }

    static func adsr(_ n: Int, attack: Float, decayTo: Float, hold: Float, release: Float, sampleRate: Float) -> [Float] {
        let a = Int(attack * sampleRate), h = Int(hold * sampleRate), r = Int(release * sampleRate)
        return (0..<n).map { i in
            if i < a { return Float(i) / Float(max(a, 1)) }
            if i < a + h { return 1 - (1 - decayTo) * Float(i - a) / Float(max(h, 1)) }
            let t = Float(i - a - h) / Float(max(r, 1))
            return max(0, decayTo * (1 - t))
        }
    }

    static func multiply(_ a: [Float], by b: [Float]) -> [Float] {
        let n = min(a.count, b.count)
        var out = [Float](repeating: 0, count: n)
        vDSP_vmul(a, 1, b, 1, &out, 1, vDSP_Length(n))
        return out
    }

    static func mix(_ a: [Float], _ ga: Float, _ b: [Float], _ gb: Float) -> [Float] {
        let n = max(a.count, b.count)
        var out = [Float](repeating: 0, count: n)
        var ga = ga, gb = gb
        var sa = a + [Float](repeating: 0, count: n - a.count)
        var sb = b + [Float](repeating: 0, count: n - b.count)
        vDSP_vsmul(sa, 1, &ga, &sa, 1, vDSP_Length(n))
        vDSP_vsmul(sb, 1, &gb, &sb, 1, vDSP_Length(n))
        vDSP_vadd(sa, 1, sb, 1, &out, 1, vDSP_Length(n))
        return out
    }

    static func noise(_ n: Int, _ rng: inout XorShift) -> [Float] {
        (0..<n).map { _ in rng.next(in: -1...1) }
    }

    struct XorShift {
        private var state: UInt32
        init(seed: UInt32) { state = seed == 0 ? 0x1234_5678 : seed }
        mutating func nextUInt32() -> UInt32 {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return state
        }
        mutating func next(in range: ClosedRange<Float>) -> Float {
            let unit = Float(nextUInt32() >> 8) / Float(1 << 24)
            return range.lowerBound + unit * (range.upperBound - range.lowerBound)
        }
    }
}
