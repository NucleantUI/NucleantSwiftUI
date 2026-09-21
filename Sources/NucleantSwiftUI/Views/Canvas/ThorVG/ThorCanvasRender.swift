//
//  ThorCanvasRender.swift
//  NucleantSwiftUI
//
import NucleantThorVG


@View @MainActor
public struct ThorCanvasRender<Context: ThorRenderContext> {
    
    @State var context: Context
    
    public init(context: Context) {
        self.context = context
    }
    
    
    
}

