//
//  WindowGroup.swift
//  NucleantUI
//

import NucleantWindow

/// A scene that presents one window over a view hierarchy.
public struct WindowGroup<Content: View>: Scene {
    let title: String
    let width: Double
    let height: Double
    let content: () -> Content

    public init(
        _ title: String = "Nucleant",
        width: Double = 900,
        height: Double = 600,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.width = width
        self.height = height
        self.content = content
    }

    public func _makeWindows() -> [HostingWindow] {
        [HostingWindow(title: title, width: width, height: height, root: content())]
    }

    public func _lowerCommands(into menuBar: MenuBar) {}
}
