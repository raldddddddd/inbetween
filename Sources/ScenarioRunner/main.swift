import Foundation
import InbetweenScenarioTools

let defaultFixturePath = "tools/scenarios/inbetween_scenarios.json"
let arguments = Array(CommandLine.arguments.dropFirst())

func usage() {
    print("""
    Usage:
      inbetween-scenario-runner --list [--file path]
      inbetween-scenario-runner --all [--summary] [--file path]
      inbetween-scenario-runner scenario-name [--summary] [--file path]

    Scenarios run entirely in memory and never access Inbetween's local history,
    personal rules, hooks, permissions, notifications, or menu-bar UI.
    """)
}

func fixturePath(from arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: "--file"), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

do {
    let path = fixturePath(from: arguments) ?? defaultFixturePath
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let document = try JSONDecoder().decode(ScenarioDocument.self, from: data)
    guard document.schemaVersion == 1 else { throw ScenarioHarnessError.invalidFixture("Unsupported scenario schema version \(document.schemaVersion)") }
    if arguments.contains("--list") {
        for scenario in document.scenarios { print("\(scenario.name) — \(scenario.description)") }
        exit(0)
    }
    let names = arguments.filter { !$0.hasPrefix("--") && $0 != path }
    let scenarios: [ScenarioFixture]
    if arguments.contains("--all") {
        scenarios = document.scenarios
    } else if let name = names.first, let scenario = document.scenarios.first(where: { $0.name == name }) {
        scenarios = [scenario]
    } else {
        usage()
        exit(2)
    }

    let summaryMode = arguments.contains("--summary")
    var failed = false
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for scenario in scenarios {
        let result = try ScenarioHarness.run(scenario)
        if summaryMode {
            if result.passed {
                print("PASS  \(result.name)")
            } else {
                print("FAIL  \(result.name): \(result.assertionFailures.joined(separator: "; "))")
            }
        } else {
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
        }
        if !result.passed { failed = true }
    }
    if summaryMode {
        print("Scenarios: \(scenarios.count) \(failed ? "with failures" : "passed")")
    }
    exit(failed ? 1 : 0)
} catch {
    fputs("Scenario runner failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
