# Configure NucleantUI for docc display on github Pages

* show NucleantUI
* basic examples of how to use some of the api
* more show cases of advanced usage with shaders where we use the view as texture input.
* prepare for tutorials section showing howto make some of the Examples (no need to explain them just yet)

make modified version of https://github.com/Py-Swift/PySwiftKitDemoPlugin/tree/master/Sources/KvSwiftUI
that outputs nucleantui code instead, and script that builds it as wasm and bundle it..

* add it as page in our docc 

## Outcome

* Catalog: `Sources/NucleantUI/NucleantUI.docc` — landing page, basic-usage
  articles (`Articles/`), shader articles, four showcases of a view as a
  shader's texture (`Showcases/`: CRT mixer, magnifier, glass over a
  backdrop, instanced sparks over a view — each compiled and run, with a
  screenshot), and `Tutorials/`: a table of contents with four chapters and
  a stub tutorial per example (intro + its `Package.swift`).
* Kivy → NucleantUI: `Tools/KivyToNucleantUI`, its own package. The
  generator started from KvSwiftUI and writes `@View` structs and
  NucleantUI's own views; `kivy-to-nucleantui` is a native CLI,
  `KivyToNucleantUIPlayground` the wasm build behind
  `Tools/KivyToNucleantUI/Playground/index.html`. It shows Kivy →
  NucleantUI only; real kv-language support is `kvlang.md`.
* `Scripts/build-playground.sh` builds and gzips the wasm bundle;
  `Scripts/build-docs.sh` builds symbol graph + DocC for static hosting
  under `/NucleantUI/` and puts the playground at `/kivy-to-nucleantui/`,
  linked from the `KivyToNucleantUI` article.
* `.github/workflows/docs.yml` runs that on `macos-26` and deploys to Pages.

