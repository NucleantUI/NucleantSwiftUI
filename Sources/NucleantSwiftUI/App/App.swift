//
//  App.swift
//  NucleantSwiftUI
//

import NucleantApplication
import NucleantThorVG
import NucleantWindow
#if os(macOS)
import AppKit
#endif
#if os(iOS)
import UIKit
import Platform_iOS
#endif
#if os(Linux)
import Glibc
#endif

/// A part of an app's user interface with a life cycle — currently, a window.
@MainActor
public protocol Scene {
    /// The windows this scene contributes. The runtime presents each one.
    func _makeWindows() -> [HostingWindow]

    /// The scene's `.commands`, added to the app's menu bar. Nothing by
    /// default; `.commands(content:)` wraps a scene to add some.
    func _lowerCommands(into menuBar: MenuBar)
}

extension Scene {
    public func _lowerCommands(into menuBar: MenuBar) {}
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

    public func _lowerCommands(into menuBar: MenuBar) {
        for scene in scenes {
            scene._lowerCommands(into: menuBar)
        }
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

    /// Force every window light or dark instead of following the system.
    /// `nil` — the default — follows it. Set before `main()`; a subtree can
    /// still be fixed the other way with `.colorScheme(_:)`.
    @MainActor public static var colorScheme: ColorScheme? = nil
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
        // The engine reports what went wrong on stdout, which is fully
        // buffered when the process isn't on a terminal — Xcode's console
        // included — so a failure on a device shows up late or never. Line
        // buffering costs nothing in a GUI app.
        nucleantLineBufferStandardOutput()

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
                nucleantLogError("NucleantSwiftUI: window present failed: \(error)\n")
            }
        }
        // Always, even with no `.commands`: the standard menus are what give
        // the app Quit, Close and the Edit shortcuts.
        installCommands(self)
    }

    /// Hand control to the platform event loop. Does not return.
    ///
    /// macOS: `setup()` already installed the delegate whose
    /// `applicationDidFinishLaunching` calls `onStart`, so this is just the
    /// run loop. iOS inverts that — `UIApplicationMain` owns the
    /// `UIApplication` and instantiates the delegate *by class name*, so the
    /// runtime can't be the delegate itself (a generic class has no ObjC
    /// name); `_AppLaunchDelegate` stands in and calls back here once a
    /// window scene is connected, which is the earliest `HostingWindow` can
    /// build a scene-owned `UIWindow`.
    public func run() {
        #if os(macOS)
        NSApplication.shared.run()
        #elseif os(iOS)
        // A bare executable — a SwiftPM executable product run on the
        // simulator, rather than an app target — has no bundle, and UIKit
        // aborts on the missing bundle identifier inside UIApplicationMain
        // with nothing to say why. Say why.
        guard Bundle.main.bundleIdentifier != nil else {
            nucleantLogError("""
                NucleantSwiftUI: no app bundle (\(Bundle.main.bundlePath)). \
                On iOS run an application target — for the demo, the \
                NucleantSwiftUIDemoApp scheme in XcodeExamples — not the \
                package's executable product.

                """)
            exit(1)
        }
        _AppLaunchDelegate.onLaunch = { [self] in onStart() }
        UIApplicationMain(
            CommandLine.argc,
            CommandLine.unsafeArgv,
            nil,
            NSStringFromClass(_AppLaunchDelegate.self)
        )
        #elseif os(Linux)
        // Linux is macOS's shape, not Android's: the delegate connects to the
        // display server, fires `onStart()` — which is where the windows get
        // presented — and hands this thread to the Wayland/X11 event loop,
        // returning only when the last window closes. Without this branch
        // `main()` returned here and the process exited before a window was
        // ever built, which is what "nothing happens on Linux" was.
        //
        // Straight to the delegate for the same reason as Android below: this
        // declaration shadows NucleantApplication's protocol-extension `run()`,
        // so calling it by name would resolve back here.
        //
        // The one thing neither Apple platform has to say: there may be no
        // display server to talk to — a bare TTY, an SSH shell with nothing
        // forwarded, a container without the socket bind-mounted. Report that
        // as itself rather than as a window that never appears.
        do {
            try appDelegate?.run()
        } catch {
            nucleantLogError("NucleantSwiftUI: no display server to open a window on: \(error)\n")
            exit(1)
        }
        #elseif os(Android)
        // Unlike every other platform this returns. The Activity owns the UI
        // thread and the main looper, so there is no event loop here to hand
        // the calling thread to, and the render loop belongs to
        // `PlatformWindow` — started when a surface appears, stopped when it
        // goes away. Keeping the process alive past this point is the
        // bootstrap's job, not this call's.
        //
        // Straight to the delegate rather than NucleantApplication's own
        // Android `run()`: that one is a protocol *extension* method, which
        // this declaration shadows, so calling it by name from here would
        // resolve back to this function. Both do the same one thing.
        appDelegate?.run()
        #endif
    }
}

extension AppRuntime: WindowCommands {
    /// The scenes' `.commands`, lowered. Evaluated when installed, so the
    /// menu reflects the state the scene body reads at that moment.
    public var menuBar: MenuBar {
        let menuBar = MenuBar()
        app.body._lowerCommands(into: menuBar)
        return menuBar
    }
}

#if os(iOS)
/// The `UIApplicationDelegate` the runtime hands to `UIApplicationMain`.
///
/// It decides *when* the app's windows get presented. With a scene manifest
/// in Info.plist (`UIApplicationSceneManifest`, the default for a modern
/// iOS target) UIKit asks for a scene configuration and the answer names
/// `_AppSceneDelegate`, which presents once its `UIWindowScene` connects —
/// that always happens after `didFinishLaunching`, and a window built from
/// the scene is what tracks Stage Manager resizing. Without a manifest UIKit
/// never connects a scene, so the legacy path presents right away onto a
/// screen-sized frame instead. Either way `onLaunch` fires exactly once.
public final class _AppLaunchDelegate: UIResponder, UIApplicationDelegate {
    /// Set by `AppRuntime.run()` before `UIApplicationMain` takes over.
    nonisolated(unsafe) static var onLaunch: (@MainActor () -> Void)?
    private nonisolated(unsafe) static var launched = false

    static func launchOnce() {
        guard !launched else { return }
        launched = true
        onLaunch?()
    }

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        if Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") == nil {
            Self.launchOnce()
        }
        return true
    }

    public func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // Built in code rather than named in the plist: the plist would need
        // the mangled `NucleantSwiftUI._AppSceneDelegate`, which is the
        // library's business, not the app's.
        let config = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        config.delegateClass = _AppSceneDelegate.self
        return config
    }

    /// UIKit asks the app delegate for the menu bar; the runtime's commands
    /// are waiting in the shared `UIKitMenuBar`.
    public override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        UIKitMenuBar.shared.build(with: builder)
    }
}

/// Records the connecting scene in `ActiveScene.current` — where
/// `HostingWindow.present()` looks for the scene to attach to — then lets
/// the runtime present.
public final class _AppSceneDelegate: UIResponder, UIWindowSceneDelegate {
    public func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        ActiveScene.current = windowScene
        _AppLaunchDelegate.launchOnce()
    }
}
#endif
