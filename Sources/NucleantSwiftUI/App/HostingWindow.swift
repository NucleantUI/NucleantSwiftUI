//
//  HostingWindow.swift
//  NucleantSwiftUI
//
//  The pure-Swift counterpart of PyNucleantUI's `WindowBase`: a
//  `NucleantWindow` that owns a platform window, a Vulkan engine and one
//  window-filling ThorVG node, and drives a `ViewHost` from the display link.
//
//  `NucleantWindow` and `WindowBaseDelegate` are non-isolated protocols, so the
//  witnesses here are non-isolated too; every one of them is in fact called on
//  the main thread (AppKit event dispatch, the display link), which is what
//  `MainActor.assumeIsolated` asserts before touching the host.
//

import NucleantVulkan
import NucleantThorVG
import NucleantWindow
import Foundation

#if os(macOS)
import AppKit
import Platform_MacOS
#endif
#if os(iOS)
import UIKit
import Platform_iOS
// `ActiveScene` — the connected `UIWindowScene` the window attaches to.
import NucleantApplication
#endif
#if os(Android)
import Platform_Android
#endif
#if os(Linux)
import Platform_Linux
// VkExtent2D — Linux has no CAMetalLayer whose drawable size the engine can
// read, so the swapchain size is supplied as a callback instead.
import CVulkan
#endif

public final class HostingWindow: NucleantWindow, @unchecked Sendable {

    public typealias Node = NucleantRenderNode

    public var renderEngine: NucleantRenderEngine?

    /// (x, y, width, height) in *pixels*, like every other Nucleant window.
    public var win_rect: SIMD4<Int>

    let title: String

    /// The view tree. Isolated to the main actor; every access below goes
    /// through `assumeIsolated`.
    let host: ViewHost

    #if os(macOS) || os(iOS) || os(Android) || os(Linux)
    /// Strongly held: `PlatformWindow` keeps only a weak `win_delegate` back
    /// here, so the window's lifetime is this object's to own.
    var platformWindow: PlatformWindow<HostingWindow>?
    #endif

    private var thorNode: ThorShaderNode<NucleantRenderNode>?

    /// GPU slots for `Shader` views — one per live shader, composited into the
    /// view's own rect rather than into the shared canvas.
    private var shaderSlots: ShaderSlotRegistry?

    /// Where the pointer last was, in points — shaders get it as a uniform.
    private var pointerLocation: Point = .zero

    /// The engine slot the canvas is bound to — held so a repaint can re-arm
    /// it directly. Its id also keys every engine-side map, so a resize has to
    /// name the same one the slot was appended with.
    private var slot: NucleantRenderNode?

    /// Backing-store pixels per point. Layout is in points; the renderer scales.
    private var displayScale: Double = 1

    #if os(macOS)
    /// Follows the app's effective appearance — System Settings, or a
    /// per-app override — for as long as the window lives.
    private var appearanceObservation: NSKeyValueObservation?
    #endif


    @MainActor
    public init<Root: View>(title: String, width: Double, height: Double, root: Root) {
        self.title = title
        self.win_rect = SIMD4(0, 0, Int(width), Int(height))
        self.host = ViewHost(root: root)
    }

    // MARK: - Bring-up

    public func present() throws {
        try MainActor.assumeIsolated {
            #if os(macOS)
            try presentMacOS()
            #elseif os(iOS)
            try presentIOS()
            #elseif os(Android)
            presentAndroid()
            #elseif os(Linux)
            try presentLinux()
            #else
            throw HostingWindowError.unsupportedPlatform
            #endif
        }
    }

    /// The scheme the window shows: the app's override if it set one, else
    /// what the system says.
    @MainActor
    private static func systemColorScheme() -> ColorScheme {
        if let forced = AppRuntimeSettings.colorScheme { return forced }
        #if os(macOS)
        let match = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return match == .darkAqua ? .dark : .light
        #elseif os(iOS)
        return UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
        #elseif os(Linux)
        // The desktop's own setting, through the XDG portal — see
        // DesktopAppearance. A desktop with no preference gets light, the same
        // answer as a platform with nothing to ask.
        return DesktopAppearance.colorScheme() == .dark ? .dark : .light
        #else
        return .light
        #endif
    }

    /// Put `scheme` into the root environment, paint the window's clear
    /// color to match, and rebuild everything — every dynamic color on
    /// screen resolves differently now.
    @MainActor
    private func applyColorScheme(_ scheme: ColorScheme) {
        guard host.environment.colorScheme != scheme || renderEngine.map({ $0.clearColor.a == 0 }) == true else { return }
        host.environment.colorScheme = scheme
        let background = Color.background.resolved(for: scheme)
        renderEngine?.clearColor = (
            Float(background.red), Float(background.green), Float(background.blue), 1
        )
        host.invalidate()
        markNeedsRedraw()
    }

    #if os(macOS)
    @MainActor
    private func presentMacOS() throws {
        // 1. Platform window + its CAMetalLayer-backed view. Its display link
        //    starts immediately and no-ops until `win_delegate` and the engine
        //    below are in place.
        let platformWindow = PlatformWindow<HostingWindow>(
            contentRect: NSRect(
                x: Double(win_rect.x),
                y: Double(win_rect.y),
                width: Double(win_rect.z),
                height: Double(win_rect.w)
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        // 2. The Vulkan engine renders into that layer.
        let engine = try NucleantRenderEngine(metalLayer: platformWindow.metalLayer)
        self.renderEngine = engine
        self.platformWindow = platformWindow
        platformWindow.win_delegate = self

        displayScale = Double(platformWindow.metalLayer.contentsScale)

        // 3. One window-filling ThorVG node for the whole tree.
        attachCanvas(engine: engine, width: win_rect.z, height: win_rect.w)

        // 4. Light or dark, now and whenever the system changes its mind.
        applyColorScheme(Self.systemColorScheme())
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            // AppKit posts this on the main thread.
            MainActor.assumeIsolated {
                self?.applyColorScheme(Self.systemColorScheme())
            }
        }

        // 5. Show it.
        platformWindow.title = title
        // A window built from a bare `contentRect` sits at the screen's
        // bottom-left corner (AppKit's origin), which on a multi-display setup
        // is easy to lose entirely. Centre it, as a freshly opened document
        // window would be.
        platformWindow.center()
        platformWindow.makeKeyAndOrderFront(nil)
        platformWindow.makeFirstResponder(platformWindow.contentView)

        // 6. Seed the size. AppKit posts `windowDidResize` only for actual
        //    resizes, so without this the tree never learns how big it is.
        if let size = platformWindow.contentView?.bounds.size {
            on_size(w: Double(size.width), h: Double(size.height))
        }
    }
    #endif

    #if os(iOS)
    @MainActor
    private func presentIOS() throws {
        // iOS ignores the requested size: the connecting scene's bounds are the
        // window, in normal mode and under Stage Manager alike.
        let scale = Double(ActiveScene.current?.screen.scale ?? 2.0)
        let bounds = ActiveScene.current?.coordinateSpace.bounds ?? UIScreen.main.bounds
        win_rect = SIMD4(
            Int(bounds.origin.x), Int(bounds.origin.y),
            Int(bounds.width * scale), Int(bounds.height * scale)
        )

        let platformWindow: PlatformWindow<HostingWindow>
        if let windowScene = ActiveScene.current {
            platformWindow = PlatformWindow<HostingWindow>(windowScene: windowScene)
        } else {
            platformWindow = PlatformWindow<HostingWindow>(frame: bounds)
        }

        let engine = try NucleantRenderEngine(metalLayer: platformWindow.metalLayer)
        self.renderEngine = engine
        self.platformWindow = platformWindow
        platformWindow.win_delegate = self
        displayScale = Double(platformWindow.metalLayer.contentsScale)
        // A finger has no scroll wheel, and no right button.
        host.scrollsOnDrag = true
        host.opensContextMenuOnLongPress = true
        // Seeded once; a later appearance change is not tracked on iOS yet.
        defer { applyColorScheme(Self.systemColorScheme()) }

        attachCanvas(engine: engine, width: win_rect.z, height: win_rect.w)

        platformWindow.makeKeyAndVisible()
        // Points here — `on_size` applies the scale itself, and `win_rect`
        // above is already in pixels.
        on_size(w: Double(bounds.width), h: Double(bounds.height))
    }
    #endif

    #if os(Linux)
    @MainActor
    private func presentLinux() throws {
        // 1. A Wayland or X11 toplevel, whichever `LinuxSession.detect()` says
        //    the session is. Its frame loop starts in init and no-ops until
        //    `win_delegate` and the engine below are in place, exactly as the
        //    display link does on macOS.
        let platformWindow = try PlatformWindow<HostingWindow>(
            width: win_rect.z,
            height: win_rect.w,
            title: title
        )

        // 2. The engine renders through VK_KHR_wayland_surface or
        //    VK_KHR_xcb_surface, from whichever raw handles the active backend
        //    hands over — there is no layer object to pass, and no drawable to
        //    ask for a size, so the swapchain reads `bufferWidth/Height`
        //    through this callback whenever it recreates itself. Weak, because
        //    the engine is owned by this window and outlives nothing.
        let getExtent: () -> VkExtent2D = { [weak platformWindow] in
            VkExtent2D(
                width: platformWindow?.bufferWidth ?? 0,
                height: platformWindow?.bufferHeight ?? 0
            )
        }
        let engine: NucleantRenderEngine
        switch platformWindow.vulkanSurfaceKind {
        case .wayland(let display, let surface):
            engine = try NucleantRenderEngine(
                waylandDisplay: display,
                waylandSurface: surface,
                getExtent: getExtent
            )
        case .xcb(let connection, let window):
            engine = try NucleantRenderEngine(
                xcbConnection: connection,
                xcbWindow: window,
                getExtent: getExtent
            )
        }
        self.renderEngine = engine
        self.platformWindow = platformWindow
        platformWindow.win_delegate = self

        displayScale = platformWindow.scale

        // 3. One window-filling ThorVG node for the whole tree, in pixels.
        attachCanvas(engine: engine, width: win_rect.z, height: win_rect.w)

        // 4. Light or dark, from the desktop. Neither Wayland nor X11 carries
        //    this — it is a desktop setting, not a display-server one — so it
        //    comes from the XDG portal, which is where every other toolkit
        //    reads it. Seeded once: the portal will also *signal* a change,
        //    which macOS follows through `effectiveAppearance` but this does
        //    not yet.
        applyColorScheme(Self.systemColorScheme())

        // 5. Show it. On X11 this is the real `xcb_map_window`; on Wayland a
        //    window only becomes visible on its first attached buffer, so it is
        //    the frame loop below that actually puts it on screen.
        platformWindow.show()

        // 6. Seed the size. Both backends report a resize only when one
        //    happens — a WM that honours the requested size never sends
        //    one — so without this the tree never learns how big it is.
        //    Points, which is what the backends report and what `on_size`
        //    scales itself; `win_rect` is already in pixels.
        on_size(w: platformWindow.width, h: platformWindow.height)
    }
    #endif

    #if os(Android)
    /// Attach to the Activity's surface.
    ///
    /// Inverted from the Apple platforms: there, this creates a window and then
    /// an engine for it. Android gives the app exactly one surface, owned by the
    /// Activity and often created before this code runs at all, so
    /// `PlatformWindow` builds the engine itself the moment a surface is
    /// available — and does it again whenever the surface is replaced, which
    /// happens on every background/resume. The canvas is therefore bound in
    /// `on_surface_recreated()` rather than here; by the time `present()`
    /// returns, that may already have been called.
    ///
    /// Non-throwing for the same reason: there is nothing to fail here. A
    /// surface that has not arrived yet is the normal case, not an error.
    @MainActor
    private func presentAndroid() {
        nucleantLogError("[trace] presentAndroid: creating PlatformWindow\n")
        let platformWindow = PlatformWindow<HostingWindow>()
        self.platformWindow = platformWindow
        platformWindow.win_delegate = self

        // Android has no pointer: the same two gestures iOS substitutes.
        host.scrollsOnDrag = true
        host.opensContextMenuOnLongPress = true
        // Points-to-pixels, from the display. Android reports it as
        // `DisplayMetrics.density` and only Java can read it, so the Activity
        // hands it over before the app starts — see AndroidSurfaceHost. The
        // surface size arrives in pixels, so this is what turns it into the
        // points the layout works in.
        displayScale = AndroidSurfaceHost.displayScale
        applyColorScheme(Self.systemColorScheme())

        nucleantLogError("[trace] presentAndroid: calling present()\n")
        platformWindow.present()
        nucleantLogError("[trace] presentAndroid: present() returned, engine=\(renderEngine != nil)\n")
    }
    #endif

    /// The engine was rebuilt against a new surface, so the canvas bound into
    /// the old one is gone with it.
    ///
    /// Only Android calls this: it is the one platform where the render surface
    /// can be destroyed and recreated under a window that outlives it — every
    /// background/resume cycle — so the node tree has to be rebound rather than
    /// rebuilt from scratch.
    public func on_surface_recreated() {
        MainActor.assumeIsolated {
            nucleantLogError("[trace] on_surface_recreated: engine=\(renderEngine != nil) rect=\(win_rect.z)x\(win_rect.w)\n")
            guard let engine = renderEngine else {
                nucleantLogError("[trace] on_surface_recreated: NO ENGINE — canvas not attached\n")
                return
            }
            attachCanvas(engine: engine, width: win_rect.z, height: win_rect.w)
        }
    }

    /// Build the ThorVG node and bind it as the engine's single slot. Mirrors
    /// what `RenderBinder.bindSlot` does for a Python canvas, minus the switch
    /// over canvas kinds — there is only one here.
    @MainActor
    private func attachCanvas(engine: NucleantRenderEngine, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        guard let node = engine.makeThorWidgetNode(width: width, height: height) else {
            // The engine reports *why* on stdout, which is fully buffered when
            // the process isn't attached to a terminal — flush it so the
            // reason lands next to this line rather than being lost.
            nucleantFlushStandardOutput()
            nucleantLogError("NucleantSwiftUI: ThorVG node build (\(width)x\(height)) failed\n")
            return
        }
        nucleantLogError("[trace] attachCanvas: node built \(width)x\(height)\n")
        let slot = NucleantRenderNode(
            id: Int.random(in: Int.min...Int.max),
            context: .thor(node)
        )
        slot.observeContext()
        engine.append(slot)
        thorNode = node
        self.slot = slot

        let renderer = ThorDisplayRenderer(canvas: node.canvas.base)
        renderer.scale = displayScale
        host.renderer = renderer

        let shaderSlots = ShaderSlotRegistry(engine: engine)
        shaderSlots.scale = displayScale
        host.shaderSlots = shaderSlots
        self.shaderSlots = shaderSlots
        host.environment.displayScale = displayScale
        // The tree may already have been laid out against a size that arrived
        // before the canvas existed; force one pass through the new renderer.
        host.invalidate()
        markNeedsRedraw()
    }

    /// The canvas contents changed — rasterize it on the next engine pass.
    ///
    /// Set on the slot directly rather than left to Observation: the chain from
    /// `node.dirty` only fires on a *change*, so a second repaint while `dirty`
    /// was already `true` would raise no notification.
    @MainActor
    private func markNeedsRedraw() {
        thorNode?.dirty = true
        slot?.needsRender = true
    }

    // MARK: - NucleantWindow

    /// A frame already queued on the main dispatch queue and not yet run —
    /// a display-link tick that arrives meanwhile is dropped, not stacked.
    private var isFramePending = false

    /// Per display-link tick: queue one frame on the main dispatch queue.
    ///
    /// Not drawn here, in the display link's own callback. A frame blocks
    /// the main thread for most of a display period (the present waits for
    /// the next vsync), and a run loop whose display-link source is always
    /// ready and always slow never gets round to servicing the main
    /// dispatch queue — so `DispatchQueue.main.async`, `Task { @MainActor
    /// in … }` and `await MainActor.run` all sat unrun, sometimes for good,
    /// while a run-loop `Timer` fired fine. Seen as an `@Observable` model
    /// updated from a background analysis never redrawing. Queued through
    /// the main queue instead, the frame takes its FIFO turn with every
    /// other main-actor block, and the display-link callback is cheap
    /// enough that the loop always drains the queue before the next tick.
    public func onFrame(_ dt: Double) {
        #if os(Android) || os(Linux)
        // Both platforms tick from a loop of their own on the process main
        // thread — the Activity's Choreographer on Android, `X11Display.run()`
        // / `WaylandDisplay.run()` here — so the isolation holds, and there is
        // no run loop underneath either of them servicing the main *dispatch*
        // queue. A hop through `DispatchQueue.main.async` would queue frames
        // that nothing ever drains, which is a window that stays black.
        MainActor.assumeIsolated {
            renderFrame(dt)
        }
        #else
        MainActor.assumeIsolated {
            guard !isFramePending else { return }
            isFramePending = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isFramePending = false
                    self.renderFrame(dt)
                }
            }
        }
        #endif
    }

    /// Rebuild if anything invalidated, then let the engine composite.
    @MainActor
    private func renderFrame(_ dt: Double) {
        if host.update() {
            markNeedsRedraw()
        }
        // Shaders are animated by definition: advance their clocks and
        // re-arm them every frame. This is the one thing on screen that is
        // never idle, and it is opt-in — a tree with no `Shader` view in it
        // does nothing here.
        shaderSlots?.tick(dt, pointer: pointerLocation)
        renderEngine?.drawFrame(dt)
    }

    /// Content resized to `w × h` **points**.
    public func on_size(w: Double, h: Double) {
        MainActor.assumeIsolated {
            #if os(macOS) || os(iOS)
            displayScale = Double(platformWindow?.metalLayer.contentsScale ?? 1)
            #elseif os(Linux)
            // The same re-read, from the backend's own scale: a window dragged
            // to a display with a different scale factor gets told through a
            // resize and nothing else.
            displayScale = platformWindow?.scale ?? 1
            #endif
            let pixelWidth = Int(w * displayScale)
            let pixelHeight = Int(h * displayScale)
            win_rect.z = pixelWidth
            win_rect.w = pixelHeight

            host.renderer?.scale = displayScale
            shaderSlots?.scale = displayScale
            host.environment.displayScale = displayScale
            host.setSize(Size(width: w, height: h))

            // The canvas is sized in pixels and fills the window, so it follows
            // the swapchain. `resizeThorNode` keeps the node's identity — the
            // slot, its z-order and the `Tvg_Canvas` all survive.
            if let engine = renderEngine {
                if let node = thorNode, let slot {
                    if node.width != UInt32(pixelWidth) || node.height != UInt32(pixelHeight) {
                        _ = engine.resizeThorNode(
                            node,
                            id: slot.id,
                            width: pixelWidth,
                            height: pixelHeight
                        )
                        // The canvas is a new target at a new size — the tree
                        // has to be repainted onto it, not just relaid out.
                        host.invalidate()
                    }
                } else {
                    // The first size arrived before the canvas could be built
                    // (a zero-sized window at bring-up) — build it now.
                    attachCanvas(engine: engine, width: pixelWidth, height: pixelHeight)
                }
            }
        }
    }

    // MARK: - Input

    /// AppKit reports mouse locations from the window's *bottom* left; the view
    /// system works top-down, so the y axis is flipped once, here.
    private func viewPoint(x: Double, y: Double) -> Point {
        #if os(macOS)
        return Point(x: x, y: contentHeightInPoints - y)
        #elseif os(Android)
        // MotionEvent reports pixels; the view tree is laid out in points.
        // Apple hands UIKit/AppKit coordinates over already in points, which
        // is why only this platform divides.
        let scale = displayScale > 0 ? displayScale : 1
        return Point(x: x / scale, y: y / scale)
        #else
        return Point(x: x, y: y)
        #endif
    }

    private var contentHeightInPoints: Double {
        Double(win_rect.w) / (displayScale > 0 ? displayScale : 1)
    }

    public func on_mouse_down(x: Double, y: Double) {
        MainActor.assumeIsolated { host.pointerDown(at: viewPoint(x: x, y: y)) }
    }

    public func on_mouse_up(x: Double, y: Double) {
        MainActor.assumeIsolated { host.pointerUp(at: viewPoint(x: x, y: y)) }
    }

    public func on_mouse_dragged(x: Double, y: Double) {
        MainActor.assumeIsolated { host.pointerMoved(to: viewPoint(x: x, y: y)) }
    }

    public func on_mouse_moved(x: Double, y: Double) {
        MainActor.assumeIsolated {
            let point = viewPoint(x: x, y: y)
            pointerLocation = point
            host.pointerMoved(to: point)
        }
    }

    public func on_right_mouse_down(x: Double, y: Double) {
        MainActor.assumeIsolated { host.secondaryClick(at: viewPoint(x: x, y: y)) }
    }

    public func on_right_mouse_up(x: Double, y: Double) {}

    public func on_scroll(dx: Double, dy: Double) {
        MainActor.assumeIsolated { host.scroll(dx: dx, dy: dy) }
    }

    public func on_key_down(keyCode: UInt16, characters: String?) {}
    public func on_key_up(keyCode: UInt16, characters: String?) {}

    public func on_touch_down(id: Int, x: Double, y: Double) {
        MainActor.assumeIsolated { host.pointerDown(id: id, at: viewPoint(x: x, y: y)) }
    }

    public func on_touch_moved(id: Int, x: Double, y: Double) {
        MainActor.assumeIsolated { host.pointerMoved(id: id, to: viewPoint(x: x, y: y)) }
    }

    public func on_touch_up(id: Int, x: Double, y: Double) {
        MainActor.assumeIsolated { host.pointerUp(id: id, at: viewPoint(x: x, y: y)) }
    }

    public func on_touch_cancelled(id: Int, x: Double, y: Double) {
        MainActor.assumeIsolated { host.pointerCancelled(id: id, at: viewPoint(x: x, y: y)) }
    }
}

public enum HostingWindowError: Error {
    case unsupportedPlatform
}

#if os(macOS)
// `PlatformWindow` routes AppKit events to its `win_delegate` through
// `WindowBaseDelegate`; the mapping onto the `on_*` methods above is the
// default implementation on `NucleantWindow where Self: WindowBaseDelegate`.
extension HostingWindow: WindowBaseDelegate {}
#endif

#if os(iOS)
extension HostingWindow: WindowTouchDelegate {}
#endif

#if os(Linux)
// Linux is the one platform where pointer, keyboard and touch are all live at
// once — a `wl_seat` can advertise all three — so `WaylandWindowDelegate` is
// the union of the two Apple protocols above. Its default implementations
// (Platform_Linux) forward to the same `on_*` methods.
extension HostingWindow: WaylandWindowDelegate {}
#endif
