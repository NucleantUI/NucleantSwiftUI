//
//  AudioFileLoader+MacOS.swift
//  NucleantAudio
//
//  `AVAudioFile`, whose processing format is always deinterleaved Float32 —
//  so every format Core Audio reads (WAV, AIFF, CAF, MP3, AAC/M4A, FLAC, …)
//  comes out as the same thing.
//

#if os(macOS)
import AVFoundation

extension AudioFileLoader {
    func decode(_ url: URL) throws -> AudioClip {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AudioFileError.unreadable(url)
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else {
            throw AudioFileError.unreadable(url)
        }
        let frames = Int(buffer.frameLength)
        let channels = (0..<Int(format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: data[channel], count: frames))
        }
        return AudioClip(sampleRate: format.sampleRate, channels: channels)
    }
}
#endif
