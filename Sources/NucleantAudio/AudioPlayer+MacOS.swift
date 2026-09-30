//
//  AudioPlayer+MacOS.swift
//  NucleantAudio
//
//  AVAudioEngine with one `AVAudioSourceNode` into the main mixer. The
//  engine's standard format is deinterleaved, so the processor renders into
//  an interleaved scratch buffer allocated up front, and each channel is
//  copied out to its own buffer — for mono that copy is the whole of it.
//

#if os(macOS)
import AVFoundation

final class AudioBackend<Processor: AudioProcessor> {
    private let engine = AVAudioEngine()
    let sampleRate: Double

    init(channels: Int, box: ProcessorBox<Processor>) throws {
        let deviceRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = deviceRate > 0 ? deviceRate : 48_000
        self.sampleRate = sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)) else {
            throw AudioPlayerError.unsupportedFormat(channels: channels, sampleRate: sampleRate)
        }
        let source = Self.makeSource(format: format, channels: channels, box: box)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
    }

    /// Kept out of any actor: a render block formed in a main-actor context
    /// would be inferred to run there, and the audio thread calling it would
    /// trip the isolation check.
    private nonisolated static func makeSource(
        format: AVAudioFormat,
        channels: Int,
        box: ProcessorBox<Processor>
    ) -> AVAudioSourceNode {
        let sampleRate = format.sampleRate
        let scratch = Scratch(frames: 4096, channels: channels)
        return AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let outputs = UnsafeMutableAudioBufferListPointer(bufferList)
            var done = 0
            let total = Int(frameCount)
            // In chunks, should the device ever ask for more than the
            // scratch holds.
            while done < total {
                let frames = min(total - done, scratch.frames)
                let interleaved = UnsafeMutableBufferPointer(rebasing: scratch.buffer[0..<(frames * channels)])
                box.process(into: interleaved, channels: channels, sampleRate: sampleRate)
                for (channel, output) in outputs.enumerated() where channel < channels {
                    guard let data = output.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for frame in 0..<frames {
                        data[done + frame] = interleaved[frame * channels + channel]
                    }
                }
                done += frames
            }
            return noErr
        }
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
    }
}

/// The render block's interleaved buffer, allocated once so the audio
/// thread never does. Only that thread touches it after `init`.
private final class Scratch: @unchecked Sendable {
    let frames: Int
    let buffer: UnsafeMutableBufferPointer<Float>

    init(frames: Int, channels: Int) {
        self.frames = frames
        buffer = .allocate(capacity: frames * channels)
        buffer.initialize(repeating: 0)
    }

    deinit {
        buffer.deallocate()
    }
}
#endif
