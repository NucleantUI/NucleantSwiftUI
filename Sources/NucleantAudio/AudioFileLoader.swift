//
//  AudioFileLoader.swift
//  NucleantAudio
//
//  The part every platform shares. The decoding itself is `decode(_:)`,
//  defined once per platform in `AudioFileLoader+<Platform>.swift`.
//

import Foundation

/// Loads an audio file into memory as an `AudioClip`, decoded to Float
/// samples at the file's own sample rate.
public struct AudioFileLoader: Sendable {
    public init() {}

    public func load(contentsOf url: URL) throws -> AudioClip {
        try decode(url)
    }
}

public enum AudioFileError: Error {
    /// The file could not be opened or decoded.
    case unreadable(URL)
}
