//
//  SceneTests.swift
//  NucleantUITests
//
//  `@SceneBuilder` and `@CommandsBuilder`: which windows an app's scenes
//  contribute, and which menus their `.commands` add to the bar, in order.
//

import Testing
import NucleantWindow
@testable import NucleantUI

/// A menu named `name` with nothing in it.
struct NamedMenu: Commands {
    let name: String

    var body: some Commands {
        CommandMenu(name) {}
    }
}

/// Two menus, then one picked by `showsHelp`, then one only when `extra`.
struct BranchingCommands: Commands {
    let showsHelp: Bool
    let extra: Bool

    var body: some Commands {
        NamedMenu(name: "File")
        NamedMenu(name: "Edit")
        if showsHelp {
            NamedMenu(name: "Help")
        } else {
            NamedMenu(name: "Tips")
        }
        if extra {
            NamedMenu(name: "Extra")
        }
    }
}

/// A scene of the app's own, composed from two window groups.
struct EditorScenes: Scene {
    var body: some Scene {
        WindowGroup("Editor") { EmptyView() }
            .commands { NamedMenu(name: "Editor") }
        WindowGroup("Inspector") { EmptyView() }
            .commands { NamedMenu(name: "Inspector") }
    }
}

/// An app body with a composite scene beside a plain one.
@MainActor
struct ThreeWindowApp {
    @SceneBuilder var body: some Scene {
        EditorScenes()
        WindowGroup("Console") { EmptyView() }
            .commands { NamedMenu(name: "Console") }
    }
}

@MainActor
private func menuTitles<S: Scene>(of scene: S) -> [String] {
    let menuBar = MenuBar()
    scene._lowerCommands(into: menuBar)
    return menuBar.menus.map(\.title)
}

@MainActor
private func menuTitles<C: Commands>(of commands: C) -> [String] {
    let menuBar = MenuBar()
    commands._lower(into: menuBar)
    return menuBar.menus.map(\.title)
}

@MainActor
@Suite
struct SceneTests {
    @Test func multipleScenesBuildATupleScene() {
        let body = ThreeWindowApp().body
        #expect(type(of: body) == TupleScene<EditorScenes, CommandsScene<WindowGroup<EmptyView>, NamedMenu>>.self)
    }

    @Test func everySceneContributesItsWindowsInOrder() {
        let windows = ThreeWindowApp().body._makeWindows()
        #expect(windows.map(\.title) == ["Editor", "Inspector", "Console"])
    }

    @Test func everySceneContributesItsCommandsInOrder() {
        #expect(menuTitles(of: ThreeWindowApp().body) == ["Editor", "Inspector", "Console"])
    }

    @Test func aSingleSceneIsPassedThrough() {
        let scene = WindowGroup("Only") { EmptyView() }
        #expect(scene._makeWindows().map(\.title) == ["Only"])
        #expect(menuTitles(of: scene).isEmpty)
    }

    @Test func ifElseLowersTheTakenBranch() {
        #expect(menuTitles(of: BranchingCommands(showsHelp: true, extra: false)) == ["File", "Edit", "Help"])
        #expect(menuTitles(of: BranchingCommands(showsHelp: false, extra: false)) == ["File", "Edit", "Tips"])
    }

    @Test func bareIfLowersOnlyWhenTrue() {
        #expect(menuTitles(of: BranchingCommands(showsHelp: true, extra: true)) == ["File", "Edit", "Help", "Extra"])
    }

    @Test func emptyCommandsAddNothing() {
        let scene = WindowGroup("Plain") { EmptyView() }.commands {}
        #expect(menuTitles(of: scene).isEmpty)
    }
}
