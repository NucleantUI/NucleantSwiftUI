//
//  TCScene.swift
//  NucleantSwiftUI
//
import NucleantThorVG

/// A ThorVG scene an author holds across frames — owned as `TCShape` is.
public final class TCScene: ThorScene {
    public var base: Tvg_Paint

    public init(base: Tvg_Paint = tvg_scene_new()) {
        self.base = base
        _ = tvg_paint_ref(base)
    }

    deinit {
        _ = tvg_paint_unref(base, true)
    }
}
