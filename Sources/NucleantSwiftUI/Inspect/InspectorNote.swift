//
//  InspectorNote.swift
//  NucleantSwiftUI
//
import Foundation


public protocol InspectorNode: Identifiable {
    
    var id: Int { get }
    
    associatedtype Context: View
    var context: Context { get }
    var children: [any InspectorNode] { get }
}

public final class ViewInspectorNote<Context: View>: InspectorNode {
    public var id: Int = UUID().hashValue
    
    public let context: Context
    
    public init(context: Context) {
        self.context = context
    }
    
    public var children: [any InspectorNode] {
        []
    }
}


extension View {
    
    var inspectorNode: some InspectorNode {
        ViewInspectorNote(context: self)
    }
    
}


public final class TupleViewInspectorNode<each T: View>: View {
    //public let value: (repeat each T)
    
    public var id: Int = UUID().hashValue
    
    public typealias Context = TupleView<repeat each T>
    
    public let context: Context
    
    public init(context: Context) {
        self.context = context
    }
    
    
    
}
