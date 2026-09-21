//
//  ThorCanvasRender.swift
//  NucleantSwiftUI
//
import NucleantThorVG


@View @MainActor
public struct ThorCanvasRender<Context: ThorRenderContext> {
    
    @State var context: Context
    
    init(context: Context) {
        self.context = context
    }
    
    
    
}






@MainActor
@View
fileprivate struct ThorCanvasRenderTest {
    
    @State var instructions: CanvasInstructions //= .init(base: getThorCanvas(id: 0))
    
    var body: some View {
        ThorCanvasRender(context: instructions)
            .shader(.init(pyshader: "some pyshader code"))
            .onAppear {
                // call example instructions todo something on appear
            }
    }
    
    
}

extension ThorCanvasRenderTest {
    
    typealias CanvasSize = SIMD2<Float>
    
    final class DemoRender: ThorRenderContext {
        var base: Tvg_Canvas = tvg_wgcanvas_create(TVG_ENGINE_OPTION_DEFAULT)
        
        init(base: Tvg_Canvas) {
            self.base = base
        }
        
        func onAppear(context: borrowing ThorContext, size: SIMD2<Float>) {
            
        }
        
        func update(context: borrowing ThorContext, size: SIMD2<Float>) {
            
        }
    }
    
    final class CanvasInstructions: ThorRenderContext, @unchecked Sendable {
        
        public var base: Tvg_Canvas //= tvg_wgcanvas_create(TVG_ENGINE_OPTION_DEFAULT)
        
        var size: CanvasSize = .sizeZero
        
        private var root: TScene
        
        var rectShape: TShape?
        
        init(base: Tvg_Canvas) {
            self.base = base
            
            self.root = .init()
            
        }
        
        func on_init(context: borrowing ThorContext, size: CanvasSize) {
            self.size = size
            
            let rect = TShape()
            rect.append_rect(pos: .pointZero, size: size)
            
            rectShape = rect
            context.add(shape: rect)
        }
        
        func onAppear(context: borrowing ThorContext, size: SIMD2<Float>) {
            
        }
        
        func update(context: ThorContext, size: CanvasSize) {
            
            if self.size != size {
                
            }
            
            if let rect = rectShape {
                // resize rect
            }
        }
    }
    
}
