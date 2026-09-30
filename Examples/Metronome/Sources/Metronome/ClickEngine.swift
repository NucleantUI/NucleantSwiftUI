//
//  ClickEngine.swift
//  Metronome
//
//  The clicks, synthesised sample by sample by `RenderState`, an
//  `AudioProcessor` that NucleantAudio's `AudioPlayer` runs on the audio
//  thread. Timing lives there: `process` counts samples to the next tick, so
//  the beat is as steady as the output clock, whatever the UI is doing. The
//  main actor only hands settings in and reads back which tick sounded last,
//  both through `withProcessor`, under the player's lock.
//

import Foundation
import NucleantAudio

enum ClickSound: CaseIterable, Identifiable, Sendable {
    case click, woodblock, beep

    var id: Self { self }

    var name: String {
        switch self {
        case .click:     return "Click"
        case .woodblock: return "Woodblock"
        case .beep:      return "Beep"
        }
    }
}

/// Everything the render block needs to know about what to play.
struct ClickSettings: Sendable, Equatable {
    var isRunning = false
    var tempo = 120.0
    var ticksPerBeat = 1
    var beatsPerBar = 4
    var accentsFirstBeat = true
    var volume = 0.8
    var sound = ClickSound.click
}

/// Which tick sounded last, and how long ago.
struct ClickPosition: Sendable {
    /// Ticks since the start, or -1 before the first one.
    var tick: Int
    var secondsSinceTick: Double
}

@MainActor
final class ClickEngine {
    /// `nil` when no output could be opened; the metronome then runs silent.
    private let player: AudioPlayer<RenderState>?

    init() {
        do {
            player = try AudioPlayer(RenderState())
        } catch {
            print("Metronome: could not open audio output — \(error)")
            player = nil
        }
    }

    /// Play with `settings` from now on. `restart` starts the count again
    /// from the first beat of a bar, with a tick straight away.
    func update(_ settings: ClickSettings, restart: Bool) {
        guard let player else { return }
        if settings.isRunning, !player.isRunning {
            do {
                try player.start()
            } catch {
                print("Metronome: could not start audio output — \(error)")
            }
        }
        player.withProcessor { state in
            state.settings = settings
            if restart { state.restart() }
        }
    }

    var position: ClickPosition {
        guard let player else { return ClickPosition(tick: -1, secondsSinceTick: 0) }
        return player.withProcessor { state in
            ClickPosition(tick: state.lastTick, secondsSinceTick: Double(state.samplesSinceTick) / state.sampleRate)
        }
    }
}

// MARK: - Rendering

/// What the audio thread keeps from one buffer to the next.
struct RenderState: AudioProcessor {
    var settings = ClickSettings()
    /// The output's rate, as of the last buffer.
    private(set) var sampleRate = 48_000.0

    private var samplesUntilTick = 0.0
    private var nextTick = 0
    private(set) var lastTick = -1
    private(set) var samplesSinceTick = 0
    private var voice = Voice()

    mutating func restart() {
        samplesUntilTick = 0
        nextTick = 0
        lastTick = -1
    }

    mutating func process(into buffer: UnsafeMutableBufferPointer<Float>, channels: Int, sampleRate: Double) {
        self.sampleRate = sampleRate
        // Volume on a square law, closer to how loud it sounds.
        let gain = settings.volume * settings.volume
        for frame in 0..<(buffer.count / channels) {
            if settings.isRunning {
                if samplesUntilTick <= 0 {
                    voice.trigger(kind(of: nextTick), sound: settings.sound, sampleRate: sampleRate)
                    lastTick = nextTick
                    nextTick += 1
                    samplesSinceTick = 0
                    samplesUntilTick += sampleRate * 60 / (settings.tempo * Double(settings.ticksPerBeat))
                }
                samplesUntilTick -= 1
            }
            samplesSinceTick += 1
            let sample = Float(tanh(voice.next() * gain))
            for channel in 0..<channels {
                buffer[frame * channels + channel] = sample
            }
        }
    }

    private func kind(of tick: Int) -> Voice.Kind {
        let perBeat = max(1, settings.ticksPerBeat)
        guard tick % perBeat == 0 else { return .subdivision }
        let beat = (tick / perBeat) % max(1, settings.beatsPerBar)
        return settings.accentsFirstBeat && beat == 0 ? .accent : .beat
    }
}

/// One click ringing out: a sine and an overtone under an exponential
/// decay, with a very short attack so it does not pop.
struct Voice: Sendable {
    enum Kind {
        case accent, beat, subdivision
    }

    private var age = 0
    private var length = 0
    private var amplitude = 0.0
    private var decay = 1.0
    private var attack = 1.0
    private var phase = 0.0
    private var step = 0.0
    private var overtone = 0.0
    private var overtoneRatio = 1.0

    mutating func trigger(_ kind: Kind, sound: ClickSound, sampleRate: Double) {
        let frequency: Double
        let seconds: Double
        switch sound {
        case .click:
            frequency = kind == .accent ? 2_000 : kind == .beat ? 1_500 : 1_100
            seconds = 0.006
            overtone = 0.2
            overtoneRatio = 2.3
        case .woodblock:
            frequency = kind == .accent ? 1_150 : kind == .beat ? 900 : 700
            seconds = 0.018
            overtone = 0.45
            overtoneRatio = 2.76
        case .beep:
            frequency = kind == .accent ? 1_760 : kind == .beat ? 880 : 660
            seconds = 0.045
            overtone = 0
            overtoneRatio = 1
        }
        amplitude = kind == .accent ? 1 : kind == .beat ? 0.75 : 0.4
        decay = seconds * sampleRate
        attack = 0.0005 * sampleRate
        length = Int(decay * 9)
        step = 2 * .pi * frequency / sampleRate
        phase = 0
        age = 0
    }

    mutating func next() -> Double {
        guard age < length else { return 0 }
        let envelope = exp(-Double(age) / decay) * min(1, Double(age) / attack)
        let wave = sin(phase) + overtone * sin(phase * overtoneRatio)
        phase += step
        age += 1
        return amplitude * envelope * wave
    }
}
