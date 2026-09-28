// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Inbetween",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Inbetween", targets: ["InbetweenApp"]),
        .executable(name: "codex-ax-probe", targets: ["CodexAXProbe"]),
        .executable(name: "inbetween-semantic-eval", targets: ["SemanticEval"]),
        .executable(name: "inbetween-corrected-history-export", targets: ["CorrectedHistoryExport"]),
        .executable(name: "inbetween-scenario-runner", targets: ["ScenarioRunner"])
    ],
    targets: [
        .target(name: "InbetweenCore"),
        // Development-only utilities. InbetweenApp does not depend on this
        // target, so it cannot affect the shipped classifier or monitoring.
        .target(name: "InbetweenSemanticTools", dependencies: ["InbetweenCore"]),
        .target(name: "InbetweenScenarioTools", dependencies: ["InbetweenCore"]),
        .executableTarget(name: "InbetweenApp", dependencies: ["InbetweenCore"]),
        .executableTarget(name: "CodexAXProbe"),
        .executableTarget(name: "SemanticEval", dependencies: ["InbetweenCore", "InbetweenSemanticTools"]),
        .executableTarget(name: "CorrectedHistoryExport", dependencies: ["InbetweenCore", "InbetweenSemanticTools"]),
        .executableTarget(name: "ScenarioRunner", dependencies: ["InbetweenScenarioTools"]),
        .testTarget(name: "InbetweenCoreTests", dependencies: ["InbetweenCore"]),
        .testTarget(name: "CodexAXProbeTests", dependencies: ["CodexAXProbe"]),
        .testTarget(name: "InbetweenSemanticToolsTests", dependencies: ["InbetweenSemanticTools"]),
        .testTarget(name: "InbetweenScenarioToolsTests", dependencies: ["InbetweenScenarioTools"])
    ]
)
