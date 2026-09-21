//
//  ThorCanvas.swift
//  NucleantSwiftUI
//
import NucleantThorVG

@View @MainActor
public struct ThorCanvas {
    
    @State var canvas: ThorContext
    
    @State var onInit: (borrowing ThorContext, SIMD2<Float>) -> Void
    
    @State var renderer: (borrowing ThorContext, SIMD2<Float>) -> Void
    
    public var body: Never { bodyUnavailable() }
    
}




//@MainActor


func getThorCanvas(id: Int) -> OpaquePointer {
    fatalError("just for testing")
}



