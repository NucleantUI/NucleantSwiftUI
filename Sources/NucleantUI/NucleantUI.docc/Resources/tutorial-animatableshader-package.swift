// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AnimatableShader",
    platforms: [.macOS(.v14), .iOS(.v17)],
    dependencies: [
        .package(url: "https://github.com/NucleantUI/NucleantUI.git", branch: "master"),
    ],
    targets: [
        .executableTarget(
            name: "AnimatableShader",
            dependencies: [.product(name: "NucleantUI", package: "NucleantUI")],
            // The shaders stay .py files, read at launch.
            resources: [
                .copy("OrientedBox.py"),
                .copy("LonelyWaters.py"),
                .copy("RadarTrace.py"),
                .copy("LightFollows.py"),
            ]
        ),
    ]
)
