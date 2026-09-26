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
/// Android is always a cross-compile: `Package.swift` is evaluated by the *host*
/// toolchain, so `#if os(Android)` here would describe the host and never be
/// true. NucleantApplication only declares its `Platform_Android` product under
/// the same env opt-in, so referencing that product unconditionally would break
/// every non-Android resolve — the two manifests have to agree on the signal.
let isAndroid = ProcessInfo.processInfo.environment["SWIFT_ANDROID_HOME"] != nil
    || ProcessInfo.processInfo.environment["ANDROID_BUILD"] != nil

/// Linux is the mirror image: NucleantApplication declares `Platform_Linux`
/// only when it is being built *on* Linux, because that provider's CWayland
/// target compiles wayland-scanner output against <wayland-client.h>, which no
/// Apple SDK has — so naming the product unconditionally would break every
/// Apple resolve, the same way naming Platform_Android does. Unlike Android
/// there is no cross-compile into Linux, so a host check is the target check.
/// `&& !isAndroid` because the Android host *is* Linux.
#if os(Linux)
let isLinux = !isAndroid
#else
let isLinux = false
#endif

/// The platform provider NucleantSwiftUI links directly, for the
/// `PlatformWindow` that `HostingWindow` owns. Only one is ever in scope.
func platformProviders() -> [Target.Dependency] {
    var deps: [Target.Dependency] = [
        .product(name: "Platform_MacOS", package: "NucleantApplication", condition: .when(platforms: [.macOS])),
        .product(name: "Platform_iOS", package: "NucleantApplication", condition: .when(platforms: [.iOS])),
    ]
    if isLinux {
        deps.append(.product(name: "Platform_Linux", package: "NucleantApplication", condition: .when(platforms: [.linux])))
    }
    if isAndroid {
        deps.append(.product(name: "Platform_Android", package: "NucleantApplication", condition: .when(platforms: [.android])))
        // The Java edge (jextract's `org.nucleantui.NucleantBridge`). Linked in
        // here rather than declared by every app, so an Android app's package
        // names NucleantSwiftUI and nothing else — the same way it does not
        // name Platform_Android.
        deps.append(.product(name: "NucleantBridge", package: "NucleantApplication", condition: .when(platforms: [.android])))
    }
    return deps
}

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
        .executable(name: "ExperimentalUITests", targets: ["ExperimentalUITests"]),
    ],
    dependencies: nucleantDependencies() + [
        // Pinned to the version the sibling packages already resolve, so the
        // toolchain's prebuilt swift-syntax is used instead of a source build.
        // 603 rather than 602: swift-java 0.4.2 — which the Android bootstrap
        // needs, because 0.1.2 does not compile on Swift 6.3.3 — requires it,
        // and an `exact:` pin here decides the version for the whole graph.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.2"),
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
            ] + platformProviders(),
            // The default faces (Roboto, Roboto Mono) travel with the library,
            // so text looks the same on every platform and never depends on
            // what fonts the OS happens to ship — see FontRegistry.
            resources: [.copy("Resources/Fonts")]
        ),
        .executableTarget(
            name: "NucleantSwiftUIDemo",
            dependencies: ["NucleantSwiftUI"]
        ),
        .executableTarget(
            name: "ExperimentalUITests",
            dependencies: ["NucleantSwiftUI", .product(name: "NucleantThorVG", package: "NucleantThorVG")]
        ),
    ]
)
