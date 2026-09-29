// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacHUD",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sibling checkout: ~/dev/hudkit next to this repo.
        .package(path: "../hudkit"),
        // The voice host's kits (sibling checkouts): the brain, voice, and dictation.
        .package(path: "../hudkit/Kits/BrainKit"),
        .package(path: "../hudkit/Kits/VoiceKit"),
        .package(path: "../speakfree"),
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
        // The voice host: notch orb, dictation, agent and speech. Runs as MacHUD's child
        // process (Contents/Helpers/MacHUDVoice) so a model crash never takes down layouts.
        .target(
            name: "VoiceHostCore",
            dependencies: [
                .product(name: "HUDKit", package: "hudkit"),
                .product(name: "BrainKit", package: "BrainKit"),
                .product(name: "VoiceKit", package: "VoiceKit"),
                .product(name: "SpeakFreeLib", package: "speakfree"),
            ],
            path: "Sources/VoiceHostCore"
        ),
        .executableTarget(
            name: "MacHUDVoice",
            dependencies: ["VoiceHostCore"],
            path: "Sources/MacHUDVoice"
        ),
        // MacHUD as an MCP tool server (stdio) for the brain or any MCP client; built into
        // Contents/Helpers/machud-mcp. Talks to MacHUD only through its control socket.
        .target(
            name: "MacHUDMCPCore",
            dependencies: [.product(name: "HUDKit", package: "hudkit")],
            path: "Sources/MacHUDMCPCore"
        ),
        .executableTarget(
            name: "machud-mcp",
            dependencies: ["MacHUDMCPCore"],
            path: "Sources/MacHUDMCP"
        ),
        .testTarget(
            name: "MacHUDMCPTests",
            dependencies: ["MacHUDMCPCore", .product(name: "HUDKit", package: "hudkit")],
            path: "Tests/MacHUDMCPTests"
        ),
        .testTarget(
            name: "VoiceHostCoreTests",
            dependencies: ["VoiceHostCore"],
            path: "Tests/VoiceHostCoreTests"
        ),
        .testTarget(
            name: "MacHUDTests",
            dependencies: ["MacHUDCore"],
            path: "Tests/MacHUDTests"
        ),
    ]
)
