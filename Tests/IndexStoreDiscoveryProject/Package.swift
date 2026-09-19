// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "IndexStoreDiscoveryProject",
    targets: [
        .target(name: "ExternalTarget"),
        .target(name: "TargetA", dependencies: ["ExternalTarget"]),
        .executableTarget(name: "MainTarget", dependencies: ["TargetA"]),
    ]
)
