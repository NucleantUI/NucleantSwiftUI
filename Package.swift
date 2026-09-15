// swift-tools-version: 6.2

import PackageDescription
import CompilerPluginSupport
import Foundation

// MARK: - Dependency source

/// Build against the sibling checkouts (`../NucleantVulkan` etc.) or against
/// `master` of each repo on GitHub.
///
/// Decided the same way in every Nucleant package, so one setting covers the
/// whole chain: `NUCLEANT_LOCAL_DEV=1|0` in the environment wins; otherwise
/// local when the sibling checkouts exist next to this package — true in a
/// development tree, false for a clone SwiftPM made under `.build/checkouts`.
/// (A package fetched by revision may not have path dependencies, so the
/// upstream packages must make the same choice, and do.)
let localDev: Bool = {
    if let flag = ProcessInfo.processInfo.environment["NUCLEANT_LOCAL_DEV"] {
        return ["1", "true", "yes"].contains(flag.lowercased())
    }
    let siblings = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    return FileManager.default.fileExists(atPath: siblings.appendingPathComponent("NucleantVulkan").path)
}()

/// The Nucleant packages this one is built on, from wherever
/// `localDev` says. Product names and `package:` identities are the same
/// either way — SwiftPM derives a path dependency's identity from the
/// directory name and a URL dependency's from the repository name, and those
/// match — so the targets below never need to know which source is in use.
func nucleantDependencies() -> [Package.Dependency] {
    let repos = ["NucleantVulkan", "NucleantThorVG", "NucleantApplication", "PyShader"]
    return repos.map { name in
        localDev
            ? .package(path: "../\(name)")
            : .package(url: "https://github.com/NucleantUI/\(name).git", branch: "master")
    }
}

let package = Package(
    name: "NucleantSwiftUI",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "NucleantSwiftUI", targets: ["NucleantSwiftUI"]),
        .executable(name: "NucleantSwiftUIDemo", targets: ["NucleantSwiftUIDemo"]),
    ],
    dependencies: nucleantDependencies() + [
        // Pinned to the version the sibling packages already resolve, so the
        // toolchain's prebuilt swift-syntax is used instead of a source build.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "602.0.0"),
    ],
    targets: [
        // Compiler plugin behind `@View` and `#viewID`. Runs at build time only;
        // nothing from swift-syntax ends up in the framework.
        .macro(
            name: "NucleantSwiftUIMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "NucleantSwiftUI",
            dependencies: [
                "NucleantSwiftUIMacros",
                .product(name: "NucleantVulkan", package: "NucleantVulkan"),
                .product(name: "NucleantShader", package: "NucleantVulkan"),
                .product(name: "PyShader", package: "PyShader"),
                .product(name: "NucleantThorVG", package: "NucleantThorVG"),
                .product(name: "NucleantApplication", package: "NucleantApplication"),
                .product(name: "NucleantWindow", package: "NucleantApplication"),
                .product(name: "Platform_MacOS", package: "NucleantApplication", condition: .when(platforms: [.macOS])),
                .product(name: "Platform_iOS", package: "NucleantApplication", condition: .when(platforms: [.iOS])),
            ],
            // The default faces (Roboto, Roboto Mono) travel with the library,
            // so text looks the same on every platform and never depends on
            // what fonts the OS happens to ship — see FontRegistry.
            resources: [.copy("Resources/Fonts")]
        ),
        .executableTarget(
            name: "NucleantSwiftUIDemo",
            dependencies: ["NucleantSwiftUI"]
        ),
    ]
)
