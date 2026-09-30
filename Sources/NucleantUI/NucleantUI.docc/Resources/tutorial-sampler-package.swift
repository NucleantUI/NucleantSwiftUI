// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Sampler",
    platforms: [.macOS(.v14), .iOS(.v17)],
    dependencies: [
        .package(url: "https://github.com/NucleantUI/NucleantUI.git", branch: "master"),
    ],
    targets: [
        .executableTarget(
            name: "Sampler",
            dependencies: [
                .product(name: "NucleantUI", package: "NucleantUI"),
                .product(name: "NucleantAudio", package: "NucleantUI"),
            ]
        ),
    ]
)
