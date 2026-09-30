//
//  Player.swift
//  Sampler
//
//  Plays a sample's frames through NucleantAudio's `AudioPlayer` and walks a
//  playhead across the bank while it sounds. The playhead is an
//  `@Observable` property written from a timer, sixty times a second, from
//  where the audio thread says playback has got to; the waveform view reads
//  it, so each write is a rebuild of that view and a re-dispatch of its
//  shader with the new position — nothing else on screen is touched.
//

import Foundation
import NucleantAudio
import NucleantUI

@MainActor
final class Player {
    /// `nil` when no output could be opened; the pads then play silent.
    private let output: AudioPlayer<ClipPlayback>?
    private var timer: Timer?
    private var duration: Double = 0

    init() {
        do {
            let output = try AudioPlayer(ClipPlayback())
            try output.start()
            self.output = output
        } catch {
            fputs("Sampler: audio output failed to start: \(error)\n", stderr)
            output = nil
        }
    }

    func play(_ sample: Sample, in bank: SampleBank) {
        let frames = sample.playableFrames
        guard !frames.isEmpty, let output else { return }
        let clip = AudioClip(sampleRate: Sample.sampleRate, mono: frames)
        output.withProcessor { $0.play(clip) }

        bank.lastTriggeredID = sample.id
        duration = clip.duration
        bank.playhead = 0
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(bank) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick(_ bank: SampleBank) {
        guard let output, duration > 0 else { return }
        if let elapsed = output.withProcessor({ $0.currentTime }) {
            bank.playhead = elapsed / duration
        } else {
            output.withProcessor { $0.stop() }
            bank.playhead = nil
            bank.lastTriggeredID = nil
            timer?.invalidate()
            timer = nil
        }
    }
}
