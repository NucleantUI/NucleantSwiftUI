//
//  ThorRenderContext.swift
//  NucleantSwiftUI
//
import NucleantThorVG


public protocol ThorRenderContext: ThorGPUCanvas {
    
    init(base: Tvg_Canvas)
    
    func onAppear(context: borrowing ThorContext, size: SIMD2<Float>)
    func update(context: borrowing ThorContext, size: SIMD2<Float>)
    
}
