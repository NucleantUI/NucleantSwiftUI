// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Issues",
    platforms: [.macOS(.v14), .iOS(.v17)],
    dependencies: [
        .package(url: "https://github.com/NucleantUI/NucleantUI.git", branch: "master"),
    ],
    targets: [
        .executableTarget(
            name: "Issues",
            dependencies: [
                .product(name: "NucleantUI", package: "NucleantUI"),
            ]
        ),
    ]
)
