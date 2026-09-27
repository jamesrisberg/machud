// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacHUD",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sibling checkout: ~/dev/hudkit next to this repo.
        .package(path: "../hudkit"),
    ],
    targets: [
        // Everything except the process entry point, so tests and other targets can link it.
        .target(
            name: "MacHUDCore",
            dependencies: [.product(name: "HUDKit", package: "hudkit")],
            path: "Sources/MacHUDCore"
        ),
        .executableTarget(
            name: "MacHUD",
            dependencies: ["MacHUDCore"],
            path: "Sources/MacHUD",
            // Info.plist and machud.json: assembled into the bundle by hud-build.sh.
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "MacHUDTests",
            dependencies: ["MacHUDCore"],
            path: "Tests/MacHUDTests"
        ),
    ]
)
