
# how is a shadernode life time handled atm?

i fear abit that current code will keep generate new RenderNode / ThorShader eachtime the view changes ?

is there ways to keep View instances tracked soo as long its just same view struct getting inited over n over it keeps RenderNode alive, and only updates it 


@View macro like ElementaryUI does 
where we can add something like 

```
struct ViewID {
    var id: Int
     
    init(line: Int = #line, col: Int = #column, file: String = #file) {
        var hash = Hasher()
        hash.combine(line)
        hash.combine(col)
        hash.combine(file)
        self.id = hash.finalize()
    }
    
}
```

```
@View
struct MyView {

    init() { # viewID: ViewID = .init() is added by macro to init function

    }

    var body: some View {

    }
}
```
and View macro adds View Protocol and so on.. 

allow it to detect @State etc and other @Properties
and write compare function that looks for changes between the @Property
ies (i assume we can just do check of dityMark in all of them)

so ViewID is used to ID what shadernode it ås connected 2 and compare function made by @View macro is used to tell if View is dirty or not ...


---

## Outcome

Short answer: GPU nodes were already long-lived — one `ThorShaderNode` per
window, and one slot per `Shader` view keyed by structural path
(`ShaderSlotRegistry`), rebuilt only on resize / source change. What was
rebuilt on every state change was the `ViewNode` layout tree, all the way
from the root when the root owned the state.

Done as sketched, with two corrections found by probing the compiler:

* `#line` in a nested default argument names the *declaration*, so
  `init(viewID: ViewID = .init())` gives every instance the same id (the
  playground does too). `_viewID: ViewID = #viewID` — a macro as a parameter
  default (SE-0422) — is call-site, so `@View` generates the init.
* A dirty mark on the wrappers isn't enough: a child whose props are unchanged
  can still be stale through a `Binding`. So `@State` now dirties its
  *readers* (key-path-granular), `Binding` compares by source, and the
  generated `_isEquivalent(to:)` covers the rest of the stored properties.

`@View struct Row { … }` — see `Core/ViewID.swift`, `Core/Equivalence.swift`,
`buildNode` in `Layout/ViewNode.swift`, and [PROCESS.md](PROCESS.md) §16 for
the numbers and the limits.
