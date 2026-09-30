// swift-tools-version: 6.0

import PackageDescription

// Kivy kv → NucleantUI, for the documentation's playground.
//
// Its own package, not a target of NucleantUI's: it never links the framework
// (it only writes code that uses it), and the playground is built for
// WebAssembly, which NucleantUI's Vulkan/ThorVG stack does not target.
//
//   swift run kivy-to-nucleantui file.kv      # native, prints the Swift
//   ../../Scripts/build-playground.sh          # the wasm page for the docs
let package = Package(
    name: "KivyToNucleantUI",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "KivyToNucleantUI", targets: ["KivyToNucleantUI"]),
        .executable(name: "kivy-to-nucleantui", targets: ["kivy-to-nucleantui"]),
        .executable(name: "KivyToNucleantUIPlayground", targets: ["KivyToNucleantUIPlayground"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Py-Swift/SwiftyKvLang", branch: "master"),
        .package(url: "https://github.com/Py-Swift/PySwiftAST", branch: "master"),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit", from: "0.37.0"),
    ],
    targets: [
        .target(
            name: "KivyToNucleantUI",
            dependencies: [
                .product(name: "KvParser", package: "SwiftyKvLang"),
                .product(name: "PySwiftAST", package: "PySwiftAST"),
            ]
        ),
        .executableTarget(
            name: "kivy-to-nucleantui",
            dependencies: ["KivyToNucleantUI"]
        ),
        .executableTarget(
            name: "KivyToNucleantUIPlayground",
            dependencies: [
                "KivyToNucleantUI",
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
            ]
        ),
    ]
)
