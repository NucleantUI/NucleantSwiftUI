// swift-tools-version: 6.2

import PackageDescription

// A standalone app built on NucleantSwiftUI. The library is taken from the
// enclosing checkout; in your own project replace the path dependency with
//   .package(url: "https://github.com/NucleantUI/NucleantSwiftUI.git", branch: "master")
let package = Package(
    name: "TwentyFortyEight",
    platforms: [.macOS(.v14), .iOS(.v17)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "TwentyFortyEight",
            dependencies: [.product(name: "NucleantSwiftUI", package: "NucleantSwiftUI")]
        ),
    ]
)
