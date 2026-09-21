//
//  ExperimentalUITests.swift
//  NucleantSwiftUI
//
// Only to test Render methods
// not part of NucleantSwiftUI
import NucleantSwiftUI

public final class RenderNodeManager: @unchecked Sendable {
    
    public static let shared: RenderNodeManager = .init()
    
    var nodes: [Int: UnsafeMutableRawPointer] = [:]

    public func getNode<T: NucleantRenderNode>(key: Int) -> T {
        // Views controls type RenderNode represents
        // soo it should be "safe" enough to just unsafeBitCast
        // from Raw to type Requested
        // and when a View triggers its final
        // .onDisappear then we remove the node
        // and deallocate it
        if let raw = nodes[key] {
            return Unmanaged<T>.fromOpaque(raw).takeUnretainedValue()
        }
        
        fatalError("setup new rendernode")
        
    }
    
    public func deleteNode(key: Int) {
        if let node = nodes.removeValue(forKey: key) {
            node.deallocate()
        }
    }
}

@main
struct ExperimentalUITestsApp: NucleantApp {
    var body: some Scene {
        WindowGroup("ExperimentalUITestsApp", width: 900, height: 620) {
            
        }
    }
}


