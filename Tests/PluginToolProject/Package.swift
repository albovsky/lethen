// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PluginToolProject",
    targets: [
        .target(name: "ExternalTarget"),
        .target(name: "TargetA", dependencies: ["ExternalTarget"]),
        .executableTarget(name: "MainTarget", dependencies: ["TargetA"]),
        // Used only by the command plugin, so `swift build --build-tests` never compiles it.
        .executableTarget(name: "UnbuiltTool", dependencies: ["TargetA"]),
        .plugin(
            name: "ToolPlugin",
            capability: .command(intent: .custom(verb: "tool", description: "Runs the tool")),
            dependencies: ["UnbuiltTool"]
        ),
    ]
)
