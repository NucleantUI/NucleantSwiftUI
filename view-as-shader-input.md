
# Make View act as Shader Texture input 
in https://github.com/NucleantUI/PyNucleantUI

we hat this feature of adding shader to canvasbase object and allow post processing by shader where 

since each CanvasBase type rendered it own VKImage which shader used 
same can be done when using the .shader(ShaderFunctionOrOtherInputTypes) in real SwiftUI

the main Core of our Vulkan Render is designed todo this, so should be easy to express with this
NucleantSwiftUI besides the current way of displaying shaders

## Outcome

Done as `.shader(_:isEnabled:)` on `View` — PROCESS.md §19.

* The view's subtree is drawn into a ThorVG canvas of its own
  (`makeThorWidgetNode`, the same path PyNucleantUI's canvases took), kept
  in the engine's node list but never composited (`compositesToWindow`).
* That canvas is the texture input of the same `OGLShaderNode` a `Shader`
  view uses — `register(image:imageView:)` finally has a caller — and the
  shader's output composites where the view is. Two images rather than
  PyNucleantUI's in-place pass, so blur/ripple-style neighbour sampling is
  not a race.
* In the shader: `layer(uv)`, `uContent`, ShaderToy's `iChannel0`. The
  canvas is drawn y-up through a root scene transform so all three agree
  with the y-up `uv`, and an unmodified ShaderToy post-process works.
* Canvases are pooled: bringing one up is ~60ms (ThorVG's wg renderer
  compiles pipelines on its first target), retargeting one <1ms.
* Static shaders dispatch once; `ShaderLibrary.effects` has eight
  examples; the demo's `Effects` screen runs the mixer under each.

