// swift-tools-version:6.0
import PackageDescription

// Scanned by the GitHub Action smoke test (.github/workflows/action-smoke.yml), which
// expects exactly one result: `unusedFunction()`.
let package = Package(
    name: "ActionSmoke",
    targets: [.executableTarget(name: "ActionSmoke")]
)
