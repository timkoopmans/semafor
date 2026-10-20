// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Semafor",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(
            name: "SemaforCore",
            dependencies: ["CSQLite"]
        ),
        .executableTarget(
            name: "SemaforApp",
            dependencies: ["SemaforCore"]
        ),
        .executableTarget(
            name: "SemaforSmoke",
            dependencies: ["SemaforCore"]
        ),
        .testTarget(
            name: "SemaforCoreTests",
            dependencies: ["SemaforCore"],
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
