//
//  ClipPlayback.swift
//  NucleantAudio
//

/// An `AudioProcessor` that plays one `AudioClip` from the start, once —
/// what a sampler pad does. `play` again restarts it, with the new clip.
///
/// The clip is resampled to the output's rate by linear interpolation. A
/// mono clip goes to every output channel; otherwise channel N plays on
/// output N, and outputs past the clip's last channel repeat it.
public struct ClipPlayback: AudioProcessor {
    private var clip: AudioClip?
    /// Where playback is, in the clip's frames.
    private var position = 0.0

    public init() {}

    public mutating func play(_ clip: AudioClip) {
        self.clip = clip
        position = 0
    }

    /// Called from the main actor, so the clip is released there and never
    /// on the audio thread.
    public mutating func stop() {
        clip = nil
        position = 0
    }

    public var isPlaying: Bool {
        guard let clip else { return false }
        return position < Double(clip.frameCount)
    }

    /// Seconds into the clip while it plays; `nil` otherwise.
    public var currentTime: Double? {
        guard isPlaying, let clip else { return nil }
        return position / clip.sampleRate
    }

    public mutating func process(into buffer: UnsafeMutableBufferPointer<Float>, channels: Int, sampleRate: Double) {
        guard let clip, clip.frameCount > 0, !clip.channels.isEmpty, sampleRate > 0 else {
            buffer.update(repeating: 0)
            return
        }
        let step = clip.sampleRate / sampleRate
        let last = clip.frameCount - 1
        let frames = buffer.count / channels
        for frame in 0..<frames {
            let index = Int(position)
            let fraction = Float(position - Double(index))
            for channel in 0..<channels {
                let samples = clip.channels[min(channel, clip.channels.count - 1)]
                var value: Float = 0
                if index <= last {
                    let next = samples[min(index + 1, last)]
                    value = samples[index] + (next - samples[index]) * fraction
                }
                buffer[frame * channels + channel] = value
            }
            // Past the end the position stops moving; the clip itself is
            // left for `stop` or the next `play` to release.
            if index <= last { position += step }
        }
    }
}
