//
//  TupleScene.swift
//  NucleantUI
//

import NucleantWindow

/// Several scenes produced by one `@SceneBuilder` block.
public struct TupleScene<each Content: Scene>: Scene {
    public let value: (repeat each Content)

    public init(_ value: (repeat each Content)) {
        self.value = (repeat each value)
    }

    public func _makeWindows() -> [HostingWindow] {
        var windows: [HostingWindow] = []
        for scene in repeat (each value) {
            windows += scene._makeWindows()
        }
        return windows
    }

    /// Every scene's commands go into the one bar, in scene order.
    public func _lowerCommands(into menuBar: MenuBar) {
        for scene in repeat (each value) {
            scene._lowerCommands(into: menuBar)
        }
    }
}
