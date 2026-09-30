//
//  AudioClip.swift
//  NucleantAudio
//

/// A piece of decoded audio held in memory: one array of samples per
/// channel, all the same length, at `sampleRate`.
public struct AudioClip: Sendable {
    public var sampleRate: Double
    public var channels: [[Float]]

    public init(sampleRate: Double, channels: [[Float]]) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public init(sampleRate: Double, mono samples: [Float]) {
        self.init(sampleRate: sampleRate, channels: [samples])
    }

    public var frameCount: Int { channels.first?.count ?? 0 }

    public var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
}
