//
//  AudioProcessor.swift
//  NucleantAudio
//

/// Makes the sound an `AudioPlayer` plays: a value that fills each output
/// buffer, called on the audio thread.
///
/// `process` runs under the player's lock, with the main actor's changes
/// (through `AudioPlayer.withProcessor`) landing between calls — so the
/// state it keeps from one buffer to the next is plain stored properties.
/// It must not allocate, block or wait on anything: it has as long as one
/// buffer lasts, and a late one is a click.
public protocol AudioProcessor: Sendable {
    /// Fill `buffer` — `buffer.count / channels` frames, `channels` samples
    /// each, interleaved — for an output running at `sampleRate`.
    mutating func process(into buffer: UnsafeMutableBufferPointer<Float>, channels: Int, sampleRate: Double)
}
