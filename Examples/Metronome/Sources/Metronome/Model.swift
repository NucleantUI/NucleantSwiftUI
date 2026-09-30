//
//  Model.swift
//  Metronome
//
//  The metronome as one `@Observable` model. Every setting the controls
//  bind to hands the click engine a fresh copy of them as it changes; a
//  60 Hz timer, running only while it plays, reads back which beat is
//  sounding for the beat lights.
//

import Foundation
import NucleantUI
import Observation

enum Meter: CaseIterable, Identifiable {
    case twoFour, threeFour, fourFour, fiveFour, sixEight

    var id: Self { self }

    var name: String {
        switch self {
        case .twoFour:   return "2/4"
        case .threeFour: return "3/4"
        case .fourFour:  return "4/4"
        case .fiveFour:  return "5/4"
        case .sixEight:  return "6/8"
        }
    }

    var beats: Int {
        switch self {
        case .twoFour:   return 2
        case .threeFour: return 3
        case .fourFour:  return 4
        case .fiveFour:  return 5
        case .sixEight:  return 6
        }
    }
}

enum Subdivision: CaseIterable, Identifiable {
    case quarters, eighths, triplets, sixteenths

    var id: Self { self }

    var name: String {
        switch self {
        case .quarters:   return "None"
        case .eighths:    return "Eighths"
        case .triplets:   return "Triplets"
        case .sixteenths: return "Sixteenths"
        }
    }

    var ticksPerBeat: Int {
        switch self {
        case .quarters:   return 1
        case .eighths:    return 2
        case .triplets:   return 3
        case .sixteenths: return 4
        }
    }
}

/// A named tempo to jump to.
enum TempoPreset: CaseIterable, Identifiable {
    case largo, adagio, andante, moderato, allegro, presto

    var id: Self { self }

    var name: String {
        switch self {
        case .largo:    return "Largo"
        case .adagio:   return "Adagio"
        case .andante:  return "Andante"
        case .moderato: return "Moderato"
        case .allegro:  return "Allegro"
        case .presto:   return "Presto"
        }
    }

    var bpm: Int {
        switch self {
        case .largo:    return 50
        case .adagio:   return 70
        case .andante:  return 92
        case .moderato: return 112
        case .allegro:  return 132
        case .presto:   return 184
        }
    }
}

/// The traditional name for the range a tempo falls in.
func tempoMarking(_ bpm: Int) -> String {
    switch bpm {
    case ..<40:     return "Grave"
    case 40..<60:   return "Largo"
    case 60..<66:   return "Larghetto"
    case 66..<76:   return "Adagio"
    case 76..<108:  return "Andante"
    case 108..<120: return "Moderato"
    case 120..<156: return "Allegro"
    case 156..<176: return "Vivace"
    case 176..<200: return "Presto"
    default:        return "Prestissimo"
    }
}

@MainActor
@Observable
final class Metronome {
    static let tempoRange = 30...300

    var tempo = 120 {
        didSet {
            let clamped = min(Self.tempoRange.upperBound, max(Self.tempoRange.lowerBound, tempo))
            if clamped != tempo { tempo = clamped; return }
            // A preset stays chosen only while the tempo is still its own.
            if let preset, preset.bpm != tempo { self.preset = nil }
            push(restart: false)
        }
    }

    /// The tempo as the slider sets it.
    var tempoValue: Double {
        get { Double(tempo) }
        set { tempo = Int(newValue.rounded()) }
    }

    /// The preset last chosen, while the tempo is still its tempo.
    var preset: TempoPreset? = nil {
        didSet {
            if let preset, preset.bpm != tempo { tempo = preset.bpm }
        }
    }

    var meter = Meter.fourFour {
        didSet { push(restart: true) }
    }

    var subdivision = Subdivision.quarters {
        didSet { push(restart: true) }
    }

    var sound = ClickSound.click {
        didSet { push(restart: false) }
    }

    var volume = 0.8 {
        didSet { push(restart: false) }
    }

    var accentsFirstBeat = true {
        didSet { push(restart: false) }
    }

    /// Whether the whole tempo panel flashes on each beat.
    var flashesOnBeat = true

    var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            push(restart: true)
            isPlaying ? startPolling() : stopPolling()
        }
    }

    /// The beat of the bar sounding now, 0-based; `nil` while stopped.
    private(set) var beat: Int?

    /// Whether a beat sounded within the last tenth of a second.
    private(set) var isFlashing = false

    @ObservationIgnored private let engine = ClickEngine()
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var taps: [Date] = []

    /// Tap tempo: the average gap between the last few taps, if they came
    /// close enough together to be one run of taps.
    func tap() {
        let now = Date()
        if let last = taps.last, now.timeIntervalSince(last) > 2 {
            taps.removeAll()
        }
        taps.append(now)
        taps = Array(taps.suffix(5))
        guard taps.count >= 2, let first = taps.first, let last = taps.last else { return }
        let interval = last.timeIntervalSince(first) / Double(taps.count - 1)
        tempo = Int((60 / interval).rounded())
    }

    private func push(restart: Bool) {
        engine.update(
            ClickSettings(
                isRunning: isPlaying,
                tempo: Double(tempo),
                ticksPerBeat: subdivision.ticksPerBeat,
                beatsPerBar: meter.beats,
                accentsFirstBeat: accentsFirstBeat,
                volume: volume,
                sound: sound
            ),
            restart: restart
        )
    }

    private func startPolling() {
        guard poll == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            // The main run loop fires this on the main thread.
            MainActor.assumeIsolated { self?.readPosition() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func stopPolling() {
        poll?.invalidate()
        poll = nil
        beat = nil
        isFlashing = false
    }

    /// Only writes what changed, so a frame with the same beat rebuilds
    /// nothing.
    private func readPosition() {
        let position = engine.position
        guard position.tick >= 0 else { return }
        let perBeat = subdivision.ticksPerBeat
        let current = (position.tick / perBeat) % meter.beats
        if beat != current { beat = current }
        let secondsSinceBeat = position.secondsSinceTick
            + Double(position.tick % perBeat) * 60 / (Double(tempo) * Double(perBeat))
        let flashing = secondsSinceBeat < 0.1
        if isFlashing != flashing { isFlashing = flashing }
    }
}
