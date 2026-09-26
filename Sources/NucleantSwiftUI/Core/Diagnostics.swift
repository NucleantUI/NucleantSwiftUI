//
//  Diagnostics.swift
//  NucleantSwiftUI
//
//  The framework's own diagnostic output, in one place.
//
//  C stdio is the corner of the standard library whose spelling is not the same
//  everywhere. Foundation re-exports the C library on every platform, but
//  `stdout` and `stderr` are declared there as mutable globals, and Swift 6
//  rejects naming one as shared mutable state — at every use site, on Linux and
//  Android alike. These are written from the render thread as well as the main
//  one, so that diagnosis is not wrong.
//
//  The problem is per-call-site, so it is worth solving once here rather than
//  fifteen times across App, ViewHost and ShaderSlotRegistry. Nothing below
//  names a stdio global except under `canImport(Darwin)`, where the overlay
//  makes it safe.
//

import Foundation

/// Write a diagnostic line to standard error.
///
/// `FileHandle` rather than `fputs(_:stderr)`: it is spelled the same on every
/// platform and names no global. On Android the bootstrap has already pointed
/// fd 2 at logcat, so this lands there.
func nucleantLogError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}

/// Flush buffered stdio, so an engine diagnostic printed on stdout lands next
/// to the line we are about to write rather than after it.
///
/// `fflush(nil)` — flush *every* open stream — instead of `fflush(stdout)`,
/// which would have to name the global. The extra streams cost nothing here.
func nucleantFlushStandardOutput() {
    fflush(nil)
}

/// Ask for standard output to be line-buffered.
///
/// The engine reports what went wrong on stdout, which is fully buffered when
/// the process is not on a terminal — Xcode's console included — so a failure
/// on a device otherwise shows up late or never. Line buffering costs nothing
/// in a GUI app.
///
/// Only on Darwin, the one platform whose overlay lets `stdout` be named from
/// concurrent code. Elsewhere this is a no-op and `nucleantFlushStandardOutput()`
/// at the diagnostic sites covers the same ground: on Android the bootstrap
/// redirects the descriptor into logcat, which is line-oriented already.
func nucleantLineBufferStandardOutput() {
    #if canImport(Darwin)
    setvbuf(stdout, nil, _IOLBF, 0)
    #endif
}
