//
//  Scene.swift
//  NucleantUI
//

import NucleantWindow

/// A part of an app's user interface with a life cycle — currently, a window.
///
/// The same shape as `View`: a scene is either a composition of other
/// scenes, declared through `body`, or a primitive one (`WindowGroup`,
/// `TupleScene`, a `.commands` scene) that has `Body == Never` and answers
/// the two hooks below itself. A composite reduces to primitives through
/// the hooks' defaults, which recurse into `body`.
@MainActor @preconcurrency
public protocol Scene {
    /// The type of scene representing the body of this scene.
    associatedtype Body: Scene

    /// The content and behavior of the scene. Primitive scenes declare
    /// `Body == Never` and are never asked for it.
    @SceneBuilder @MainActor @preconcurrency var body: Body { get }

    /// The windows this scene contributes. The runtime presents each one.
    func _makeWindows() -> [HostingWindow]

    /// The scene's `.commands`, added to the app's menu bar.
    func _lowerCommands(into menuBar: MenuBar)
}

extension Scene {
    public func _makeWindows() -> [HostingWindow] {
        body._makeWindows()
    }

    public func _lowerCommands(into menuBar: MenuBar) {
        body._lowerCommands(into: menuBar)
    }
}

extension Scene where Body == Never {
    public var body: Never {
        preconditionFailure("body should not be called on the primitive scene \(Self.self).")
    }
}

// MARK: - Never as a Scene

extension Never: Scene {}
