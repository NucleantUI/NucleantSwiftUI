// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Photos",
    platforms: [.macOS(.v14), .iOS(.v17)],
    dependencies: [
        .package(url: "https://github.com/NucleantUI/NucleantUI.git", branch: "master"),
    ],
    targets: [
        .executableTarget(
            name: "Photos",
            dependencies: [.product(name: "NucleantUI", package: "NucleantUI")]
        ),
    ]
)
