//
//  PrimaryViewRender.swift
//  NucleantSwiftUI
//



public protocol ViewRender {
    
}

public protocol AppRenderContext {
    
    associatedtype Context: View
    var context: Context { get }
    
}

struct ThorViewRender {
    
}


extension ViewRender {
    
}

extension View where Self: ViewRender {
    
}

extension TupleView: ViewRender where repeat each T: ViewRender {
    
}

extension Button: ViewRender where Label: ViewRender {
    
}
