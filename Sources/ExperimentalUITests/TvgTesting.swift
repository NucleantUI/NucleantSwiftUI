//
//  TvgTesting.swift
//  NucleantSwiftUI
//
import NucleantThorVG



@View @MainActor
fileprivate struct CanvasThorTest {
    
    @State var instructions: CanvasInstructions = .init()
    
    @State var tRect: TCShape = .init()
    
    @State var shader: ShaderFunction
    
    var body: some View {
        ThorCanvas(
            onInit: { context, size in
                let rect = tRect
                rect.append_rect(pos: .zero, size: size)
                rect.set_fill_color(r: 255, g: 255, b: 255)
                context.add(shape: rect)
            },
            renderer: { context, size in
                // update tRect size
                // update fill color
            }
        )
        
        .shader(.init(pyshader: "some pyshader code"))
        .onAppear {
            
        }
        
    }
    
    
}






extension CanvasThorTest {
    
    typealias CanvasSize = SIMD2<Float>
    
    class CanvasInstructions {
        
        
        var size: CanvasSize = .sizeZero
        
        private var root: TCScene
        
        var rectShape: TCShape?
        
        init() {
            
            root = .init()
        }
        
        func on_init(context: ThorContext, size: CanvasSize) {
            self.size = size
            
            let rect = TCShape()
            rect.append_rect(pos: .pointZero, size: size)
            
            rectShape = rect
            
        }
        
        func update(context: ThorContext, size: CanvasSize) {
            
            if self.size != size {
                
            }
        }
    }
    
}





@MainActor
@View
fileprivate struct ThorCanvasRenderTest {
    
    @State var instructions: CanvasInstructions
    
    var body: some View {
        ThorCanvasRender(context: instructions)
            .shader(instructions.currentShader)
            .onAppear {
                // call example instructions todo something on appear
            }
    }
    
    
}

extension ThorCanvasRenderTest {
    
    typealias CanvasSize = SIMD2<Float>
    
    final class CanvasInstructions: ThorRenderContext, @unchecked Sendable {
        
        public var base: Tvg_Canvas //= tvg_wgcanvas_create(TVG_ENGINE_OPTION_DEFAULT)
        
        var size: CanvasSize = .sizeZero
        
        private var root: TCScene
        
        var rectShape: TCShape?
        
        var currentShader: ShaderFunction = .init(pyshader: "some pyshader code")
        
        init(base: Tvg_Canvas) {
            self.base = base
            
            self.root = .init()
            
        }
        
        func on_init(context: borrowing ThorContext, size: CanvasSize) {
            self.size = size
            
            let rect = TCShape()
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


