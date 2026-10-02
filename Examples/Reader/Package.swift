// swift-tools-version: 6.2

import PackageDescription

// A standalone app built on NucleantUI. The library is taken from the
// enclosing checkout; in your own project replace the path dependency with
//   .package(url: "https://github.com/NucleantUI/NucleantUI.git", branch: "master")
let package = Package(
    name: "Reader",
    platforms: [.macOS(.v14), .iOS(.v17)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "Reader",
            dependencies: [.product(name: "NucleantUI", package: "NucleantUI")]
        ),
    ]
)
