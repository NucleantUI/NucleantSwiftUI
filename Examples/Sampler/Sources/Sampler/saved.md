also to note when making new View

```swift
ZStack {
    Color.red // renders to current RenderNode in current View struct
        .shader(ColorBend()) // now here it would be smart that it does what it current did
                            // with just targeting a region of the vkimage
    SomeShader() // by default it means new rendernode since we draw on top of Thor Context
    Text("we made shader soo now we need new RenderNode")
        .shader(SomeShader) // now we use the part of RenderNode that post process with shader of the vkimage
} 
```
View struct which ZStack is used inside is Rendered to VkImage by joining all VKImages / surfaces
* Color.red - just added to the root RenderNode as instruction, next 2 elements requires new Nodes, soo unless something outside triggers change, this part is rasterized and doesnt need re-render if SomeShader changes, only a new render of current VKImage + SomeShader result and Text result
* SomeShader - since new Node then parent just needs to add VKImage as what to draw next
* Text - well have to be new node but easy to add .shader to it since 


introduce in NucleantVulkan
* OverlayShaderNode
just accepts same VkImage from parent, but post processes on a region of it..

```swift
VStack {
    Color.red // renders to current RenderNode in current View struct
        .shader(ColorBend()) // uses OverlayShaderNode
    Color.green // renders to same parent RenderNode
        .shader(ColorBend()) // uses OverlayShaderNode
    Color.blue // renders to same parent RenderNode
        .shader(ColorBend()) // uses OverlayShaderNode
}
    .shader(Wave()) // uses the RenderNode own postProcess part
```
this isnt specific for VStack but good case for how it should also behave different 
with .shader based on what View types being used.
but if a Layout dont overlap subviews then it has no reason to generate
RenderNode 


# Notes to HostingWindow

Window IS NOT A RENDERNODE, it already went wrong here
a big giant primary VkImage is used, and i dont believe that one Giant Surface
is going by default take less memory than 4-5 smaller RenderNodes + VkImage
just by default...



# Resize == RenderNode new VkImage
having to reallocate VkImage because of size change can never be as expensive vs what happened in
NucleantTouchBayUI
single changes result in completely change of all ThorVG drawing instructions resulting in 80-100% cpu use when changes happened all over the place..

in NucleantUI the concept is you pay for extra vram usage but only dirty RenderNodes needs to re-draw
pr frame and rest of the time it just samples current rendered VkImages..

* re-allocate VkImage by nearest 8 / 16 / 32 pixel size
lets say we start with a 128 x 128 RenderNode/VkImage and UI resizes it to 128 x 130
instead of reallocate extactly that size just update it to 136 x 136
```swift
public final class NucleantRenderNode: RenderContainerNode, @unchecked Sendable {

    ....


    public var compositeRect: SIMD4<Double>?
}
```


# AnyView, Any , any Something rules...
using the following
* Any - i will not even accept this in any Rendering part simply not written right if its required
* AnyView - should be last resort - even ForEach will have type for Element and we shouldnt have to mask Type only as very last resort
* any Protocol - should be last resort when too complicated to solve multi types which is confirms to a protocol

in TouchBayUI
i hat no issues making a generic Class type that could be inited by the Root View
which then would also define generic types down the node tree

while View structs is momentary and would have issues keeping a RenderNode alive
then a HostingWindow should just contain a Dictionary of example
```swift
public final class RenderNodeManager: @unchecked Sendable {
    
    public static let shared: RenderNodeManager = .init()
    
    var nodes: [Int: UnsafeMutableRawPointer] = [:]

    public func getNode<T: NucleantRenderNode>(key: Int) -> T {
        // Views controls type RenderNode represents
        // soo it should be "safe" enough to just unsafeBitCast
        // from Raw to type Requested
        // and when a View triggers its final
        // .onDisappear then we remove the node
        // and deallocate it
        if let raw = nodes[key] {
            return Unmanaged<T>.fromOpaque(raw).takeUnretainedValue()
        }
        
        fatalError("setup new rendernode")
        
    }
    
    public func deleteNode(key: Int) {
        if let node = nodes.removeValue(forKey: key) {
            node.deallocate() // or whatever required to cleanup 
        }
    }
}
```



# @View
```swift
@View @MainActor
public struct ThorCanvas {
    
    @State var canvas: ThorContext
    
    @State var onInit: (borrowing ThorContext, SIMD2<Float>) -> Void // closures shouldnt be compared at all
    
    @State var renderer: (borrowing ThorContext, SIMD2<Float>) -> Void
    
    public var body: Never { bodyUnavailable() }
    
}
```
* 'onInit' is a closure, so no two 'ThorCanvas' values are ever equivalent and this view is rebuilt whenever its parent is; take a Binding or a value instead if the parent re-runs often (from macro 'View ')
* 'renderer' is a closure, so no two 'ThorCanvas' values are ever equivalent and this view is rebuilt whenever its parent is; take a Binding or a value instead if the parent re-runs often (from macro 'View ')

clossures are not valid to compare
if nothing to compare then we are not chaging anything and
```swift
@MainActor public func _isEquivalent(to other: Self) -> Bool {
    false // not the true as before, we nothing chaging the view so just return false
    // Shaders updates in seperate pipeline
    // so we got no reason to update, unless it changes size
    // which is another pipeline also...
}
```



# Why 1 rendernode was terrible also
i spotted the issue because i was preparing for

```swift
@View @MainActor
public struct ThorCanvas {
    
    @State var canvas: ThorContext
    
    @State var onInit: (borrowing ThorContext, SIMD2<Float>) -> Void
    
    @State var renderer: (borrowing ThorContext, SIMD2<Float>) -> Void
    
    public var body: Never { bodyUnavailable() }
    
}
```

```swift
@View @MainActor
public struct ThorCanvasRender<Context: ThorRenderContext> {
    
    @State var context: Context
    
    public init(context: Context) {
        self.context = context
    }
    
    
    
}
```
2 new CanvasViews to express direct ThorVG canvas drawing 

and later
```swift
@View @MainActor
public struct SkiaCanvasRender<Context: ThorRenderContext> {
    
    @State var context: Context
    
    public init(context: Context) {
        self.context = context
    }
    
    
    
}
```
Views that mostly makes sense to have own RenderNode

we properly going to introduce even more later on...

