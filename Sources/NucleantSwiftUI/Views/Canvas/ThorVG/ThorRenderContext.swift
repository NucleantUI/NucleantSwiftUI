//
//  ThorRenderContext.swift
//  NucleantSwiftUI
//
import NucleantThorVG

/// The paints and the two callbacks of a `ThorCanvasRender` view, on an object
/// the author owns — the class form of `ThorCanvas`'s two closures.
///
/// A class, so it can hold the `TCShape`s it added and mutate them in place
/// on `update`, and so the view compares it by identity: the same object is
/// the same input. Make it `@Observable` and read its properties in `update`
/// for a change to them to run `update` again. Both callbacks run on the
/// main actor, during layout.
public protocol ThorRenderContext: AnyObject {
    /// Once per node, on a canvas holding nothing: add the paints.
    func onAppear(context: borrowing ThorContext, size: SIMD2<Float>)
    /// After `onAppear`, and again whenever something it read changed or the
    /// size did — then the node is rasterized.
    func update(context: borrowing ThorContext, size: SIMD2<Float>)
}
