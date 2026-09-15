//
//  Player.swift
//  Sampler
//
//  Plays a sample's frames through AVAudioEngine and walks a playhead
//  across the bank while it sounds. The playhead is an `@Observable`
//  property written from a timer, sixty times a second; the waveform view
//  reads it, so each write is a rebuild of that view and a re-dispatch of
//  its shader with the new position — nothing else on screen is touched.
//

import AVFoundation
import Foundation
import NucleantSwiftUI

@MainActor
final class Player {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Sample.sampleRate, channels: 1)!
    private var timer: Timer?
    private var startedAt: Date?
    private var duration: Double = 0

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            fputs("Sampler: audio engine failed to start: \(error)\n", stderr)
        }
    }

    func play(_ sample: Sample, in bank: SampleBank) {
        let frames = sample.playableFrames
        guard !frames.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames.count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames.count)
        frames.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: frames.count)
        }
        node.stop()
        node.scheduleBuffer(buffer)
        node.play()

        bank.lastTriggeredID = sample.id
        duration = Double(frames.count) / Sample.sampleRate
        startedAt = Date()
        bank.playhead = 0
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(bank) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick(_ bank: SampleBank) {
        guard let startedAt, duration > 0 else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= duration {
            bank.playhead = nil
            bank.lastTriggeredID = nil
            timer?.invalidate()
            timer = nil
        } else {
            bank.playhead = elapsed / duration
        }
    }
}
