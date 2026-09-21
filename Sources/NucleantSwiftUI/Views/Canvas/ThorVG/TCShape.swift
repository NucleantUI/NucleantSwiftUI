//
//  TShape.swift
//  NucleantSwiftUI
//
//  Created by CodeBuilder on 20/09/2026.
//


public final class TShape: ThorShape {
    public var base: Tvg_Paint
    
    init(base: Tvg_Paint = tvg_shape_new()) {
        self.base = base
    }
}