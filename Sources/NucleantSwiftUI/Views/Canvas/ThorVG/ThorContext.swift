//
//  ThorContext.swift
//  NucleantSwiftUI
//
import NucleantThorVG


public final class ThorContext: ThorGPUCanvas, @unchecked Sendable {
    public var base: Tvg_Canvas
    public init(base: Tvg_Canvas) {
        self.base = base
    }
}
