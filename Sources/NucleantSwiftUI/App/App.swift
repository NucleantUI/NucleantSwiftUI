//
//  App.swift
//  NucleantSwiftUI
//

import NucleantApplication
import NucleantThorVG
#if os(macOS)
import AppKit
#endif

/// A part of an app's user interface with a life cycle — currently, a window.
@MainActor
public protocol Scene {
    /// The windows this scene contributes. The runtime presents each one.
    func _makeWindows() -> [HostingWindow]
}

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
}

/// Several scenes in one `body`.
public struct _TupleScene: Scene {
    let scenes: [any Scene]

    public init(_ scenes: [any Scene]) {
        self.scenes = scenes
    }

    public func _makeWindows() -> [HostingWindow] {
        scenes.flatMap { $0._makeWindows() }
    }
}

@resultBuilder
@MainActor
public struct SceneBuilder {
    public static func buildBlock<S: Scene>(_ scene: S) -> S { scene }

    @_disfavoredOverload
    public static func buildBlock<each S: Scene>(_ scenes: repeat each S) -> _TupleScene {
        var collected: [any Scene] = []
        for scene in repeat (each scenes) {
            collected.append(scene)
        }
        return _TupleScene(collected)
    }
}

/// The entry point of a NucleantSwiftUI app.
///
/// ```swift
/// @main
/// struct DemoApp: NucleantApp {
///     var body: some Scene {
///         WindowGroup("Demo") { ContentView() }
///     }
/// }
/// ```
@MainActor
public protocol NucleantApp {
    associatedtype Body: Scene
    init()

    @SceneBuilder var body: Body { get }
}

extension NucleantApp {
    /// What `@main` calls. Builds the platform application, presents the
    /// scene's windows on launch, and runs the event loop.
    public static func main() {
        let runtime = AppRuntime(app: Self())
        runtime.setup()
        runtime.run()
    }
}

/// Knobs the runtime reads at launch. A namespace rather than statics on
/// `AppRuntime`, which is generic and so can't hold stored type properties.
public enum AppRuntimeSettings {
    /// ThorVG worker threads. `0` runs everything on the calling thread, which
    /// is what a GPU canvas wants — the raster workers only help the software
    /// backend. Set before `main()` to override.
    @MainActor public static var thorVGThreadCount: UInt32 = 0
}

/// Bridges a `NucleantApp` onto `NucleantApplication`, the platform-lifecycle
/// protocol the rest of the Nucleant stack is built around.
@MainActor
public final class AppRuntime<A: NucleantApp>: NucleantApplication {

    private let app: A

    /// Windows are held for the process's lifetime — each owns its engine and
    /// platform window, and `PlatformWindow` only weakly references back.
    private var windows: [HostingWindow] = []

    public var appDelegate: AppDelegate<AppRuntime<A>>?

    public init(app: A) {
        self.app = app
    }


    public func onStart() {
        // ThorVG's engine has to be up before any canvas is created —
        // `tvg_wgcanvas_create` returns null otherwise, which is exactly what a
        // missing init looks like from the outside. PyNucleantUI does the same
        // thing in `PyApp.init`.
        ThorEngine.ensureInitialized(threads: AppRuntimeSettings.thorVGThreadCount)

        windows = app.body._makeWindows()
        for window in windows {
            do {
                try window.present()
            } catch {
                fputs("NucleantSwiftUI: window present failed: \(error)\n", stderr)
            }
        }
    }

    /// Hand control to the platform event loop.
    ///
    /// On iOS the host owns the loop (`SDL_UIKitRunApp` / the UIKit runner
    /// starts it and calls `onStart` for us), so there is nothing to run here.
    public func run() {
        #if os(macOS)
        NSApplication.shared.run()
        #elseif os(iOS)
        onStart()
        #endif
    }
}
