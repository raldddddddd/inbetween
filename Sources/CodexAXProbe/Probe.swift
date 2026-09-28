import AppKit
@preconcurrency import ApplicationServices
import CryptoKit
import Foundation

func fingerprint(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func supportedAttributeNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
    return (names as? [String] ?? []).sorted()
}

private func supportedParameterizedAttributeNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success else { return [] }
    return (names as? [String] ?? []).sorted()
}

private func supportedActionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return (names as? [String] ?? []).sorted()
}

private func uiElementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

struct Snapshot {
    var signals: [Signal] = []
    var diagnostic: [[String: Any]] = []
    var complete = true
}

// Read structural/control metadata only. Never read text areas, document contents, or input values.
func snapshot(_ roots: [(element: AXUIElement, path: String)], inspect: Bool) -> Snapshot {
    var result = Snapshot()
    var queue: [(AXUIElement, String, Int)] = []
    var seenByHash: [Int: [AXUIElement]] = [:]
    var seenCount = 0
    func insertIfNew(_ element: AXUIElement) -> Bool {
        let hash = Int(CFHash(element))
        if seenByHash[hash, default: []].contains(where: { CFEqual($0, element) }) { return false }
        seenByHash[hash, default: []].append(element)
        seenCount += 1
        return true
    }
    for root in roots where insertIfNew(root.element) {
        queue.append((root.element, root.path, 0))
    }
    var cursor = 0
    let deadline = Date().addingTimeInterval(2)
    while cursor < queue.count {
        guard cursor < 2000, Date() < deadline else { result.complete = false; break }
        let (element, path, depth) = queue[cursor]
        cursor += 1
        let role = attribute(element, kAXRoleAttribute) as? String ?? "AXUnknown"
        if role == "AXUnknown" { result.complete = false }
        let subrole = attribute(element, kAXSubroleAttribute) as? String
        let enabled = attribute(element, kAXEnabledAttribute) as? Bool
        let focused = attribute(element, kAXFocusedAttribute) as? Bool
        let supported = inspect ? supportedAttributeNames(element) : []
        let supportedSet = Set(supported)
        let actions = inspect ? supportedActionNames(element) : []
        let parameterized = inspect ? supportedParameterizedAttributeNames(element) : []
        var stateAttributes: [String: Bool] = [:]
        if inspect {
            for name in DiagnosticPolicy.readableBooleanAttributes(supported: supportedSet) {
                if let value = attribute(element, name) as? Bool {
                    stateAttributes[name] = value
                }
            }
        }
        var rawMetadata: [String: String] = [:]
        let detectorNames = DiagnosticPolicy.detectorStringAttributes(for: role)
        let diagnosticNames = inspect ? DiagnosticPolicy.readableStringAttributes(for: role) : []
        for name in Set(detectorNames + diagnosticNames) {
            if let value = attribute(element, name) as? String, !value.isEmpty {
                rawMetadata[name] = value
            }
        }
        let hashes = inspect
            ? DiagnosticPolicy.sanitizedFingerprints(role: role, values: rawMetadata)
            : [:]
        if enabled != false {
            for name in detectorNames {
                if let value = rawMetadata[name] {
                    result.signals.append(Signal(role: role, attribute: name, sha256: fingerprint(value)))
                }
            }
        }

        var relationshipCounts: [String: Int] = [:]
        var relationshipErrors: [String] = []
        let relationships = inspect
            ? DiagnosticPolicy.childRelationships(supported: supportedSet)
            : [kAXChildrenAttribute as String]
        for relationship in relationships {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, relationship as CFString, &value)
            if error == .noValue || error == .attributeUnsupported { continue }
            guard error == .success, let children = value as? [AXUIElement] else {
                result.complete = false
                relationshipErrors.append(relationship)
                continue
            }
            relationshipCounts[relationship] = children.count
            guard depth < 40 else {
                if !children.isEmpty { result.complete = false }
                continue
            }
            for (index, child) in children.enumerated() {
                guard insertIfNew(child) else { continue }
                if seenCount > 2000 { result.complete = false; break }
                queue.append((child, "\(path)/\(relationship)[\(index)]", depth + 1))
            }
            if seenCount > 2000 { break }
        }

        if inspect {
            var row: [String: Any] = [
                "path": path,
                "role": role,
                "fingerprints": hashes,
                "supportedAttributes": supported,
                "supportedParameterizedAttributes": parameterized,
                "actions": actions,
                "childRelationships": relationshipCounts,
            ]
            if let subrole { row["subrole"] = subrole }
            if let enabled { row["enabled"] = enabled }
            if let focused { row["focused"] = focused }
            if !stateAttributes.isEmpty { row["stateAttributes"] = stateAttributes }
            let suppressed = DiagnosticPolicy.suppressedContentAttributes(for: role, supported: supportedSet)
            if !suppressed.isEmpty { row["contentMetadataSuppressed"] = suppressed }
            if !relationshipErrors.isEmpty { row["relationshipReadErrors"] = relationshipErrors.sorted() }
            result.diagnostic.append(row)
        }
    }
    return result
}

@MainActor
@main
enum Probe {
    private static let defaultBundleIdentifier = "com.openai.codex"

    static func main() {
        do { try run() }
        catch {
            fputs("Probe error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") {
            print("""
            codex-ax-probe [--request-permission] [--once] [--inspect]
              [--bundle-id \(defaultBundleIdentifier)] [--window INDEX]
              [--rules experiments/rules.json] [--run RUN_ID] [--log PATH]
            JSONL on stdout; --log appends locally. --inspect emits hashed control metadata.
            Default rules are deliberately empty. No detection is validated yet.
            """)
            return
        }
        let flags: Set<String> = ["--request-permission", "--once", "--inspect"]
        let options: Set<String> = ["--bundle-id", "--window", "--rules", "--run", "--log"]
        var values: [String: String] = [:]
        var index = 0
        while index < args.count {
            let arg = args[index]
            if flags.contains(arg) { index += 1; continue }
            guard options.contains(arg), index + 1 < args.count else {
                throw NSError(domain: "Arguments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown or missing argument: \(arg)"])
            }
            values[arg] = args[index + 1]
            index += 2
        }
        let windowIndex: Int?
        if let value = values["--window"] {
            guard let parsed = Int(value), parsed >= 0 else {
                throw NSError(domain: "Arguments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Window must be a nonnegative index"])
            }
            windowIndex = parsed
        } else { windowIndex = nil }
        let rules = try JSONDecoder().decode(Rules.self, from: Data(contentsOf:
            URL(fileURLWithPath: values["--rules"] ?? "experiments/rules.json")))
        var log: FileHandle?
        if let path = values["--log"] {
            if !FileManager.default.fileExists(atPath: path) {
                guard FileManager.default.createFile(atPath: path, contents: nil) else {
                    throw NSError(domain: "Log", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create log"])
                }
            }
            log = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try log?.seekToEnd()
        }
        defer { try? log?.close() }
        let runID = values["--run"] ?? "unassigned"
        func permissionInstructions() {
            fputs("Accessibility permission is unavailable. Run with --request-permission, then enable the probe or its launching terminal in System Settings > Privacy & Security > Accessibility and restart the probe. No screen-recording permission is needed.\n", stderr)
        }
        func emit(_ kind: String, _ fields: [String: Any], at date: Date = Date()) throws {
            var record = fields
            record["kind"] = kind
            record["time"] = date.timeIntervalSince1970
            record["run"] = runID
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data([10])
            FileHandle.standardOutput.write(data)
            try log?.write(contentsOf: data)
        }
        if args.contains("--request-permission") {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        var machine = Machine()
        var observedPID: pid_t?
        var observer: AXObserver?
        var lastHealth: String?
        var lastSample: Date?
        let bundle = values["--bundle-id"] ?? defaultBundleIdentifier
        let ruleEncoder = JSONEncoder()
        ruleEncoder.outputFormatting = [.sortedKeys]
        try emit("configuration", ["bundle": bundle, "signalRules": rules.scope.count + rules.idle.count + rules.working.count + rules.needsUser.count,
                                   "rulesSHA256": fingerprint(String(decoding: try ruleEncoder.encode(rules), as: UTF8.self)),
                                   "schemaVersion": 1, "pollSeconds": 1, "idleConfirmationSeconds": 2])
        repeat {
            var state = State.unknown
            var evidence: [String] = []
            var identity: String?
            var health = "accessibility_permission_missing"
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
            if AXIsProcessTrusted() {
                health = "process_not_found"
                if apps.count > 1 { health = "multiple_matching_processes" }
                if apps.count == 1, let app = apps.first {
                    let pid = app.processIdentifier
                    let axApp = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(axApp, 0.1)
                    if observedPID != pid {
                        if let observer { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode) }
                        observer = nil
                        observedPID = pid
                        var created: AXObserver?
                        let status = AXObserverCreate(pid, { _, _, _, _ in
                            CFRunLoopStop(CFRunLoopGetCurrent())
                        }, &created)
                        if status == .success, let created {
                            observer = created
                            CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
                            var subscribed = 0
                            for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXUIElementDestroyedNotification] {
                                if AXObserverAddNotification(created, axApp, notification as CFString, nil) == .success { subscribed += 1 }
                            }
                            try emit("observer", ["subscriptions": subscribed, "fallback": "one_second_polling"])
                        } else {
                            try emit("observer", ["subscriptions": 0, "fallback": "one_second_polling"])
                        }
                    }
                    health = "windows_unavailable"
                    if let windows = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] {
                        let selected = windowIndex ?? 0
                        if windows.count > 1 && windowIndex == nil {
                            health = "multiple_windows_require_explicit_selection"
                        } else if windows.indices.contains(selected) {
                            let window = windows[selected]
                            let title = attribute(window, kAXTitleAttribute) as? String
                            identity = "\(pid):\(selected):\(fingerprint(title ?? ""))"
                            var roots: [(element: AXUIElement, path: String)] = [(window, "window")]
                            if args.contains("--inspect"),
                               let focused = uiElementAttribute(axApp, kAXFocusedUIElementAttribute) {
                                roots.append((focused, "applicationFocusedUIElement"))
                            }
                            let captured = snapshot(roots, inspect: args.contains("--inspect"))
                            (state, evidence) = rules.classify(captured.signals, complete: captured.complete)
                            health = captured.complete ? "snapshot_available" : "snapshot_incomplete"
                            if args.contains("--inspect") {
                                try emit("inspection", ["window": selected, "complete": captured.complete, "controls": captured.diagnostic])
                            }
                        } else { health = "selected_window_not_found" }
                    }
                }
            }
            if health != lastHealth {
                try emit("health", ["reason": health, "processFound": !apps.isEmpty, "accessibilityTrusted": AXIsProcessTrusted()])
                if health == "accessibility_permission_missing" { permissionInstructions() }
                lastHealth = health
            }
            if state == .unknown { evidence.append(health) }
            let now = Date()
            if let lastSample, now.timeIntervalSince(lastSample) > 5 {
                for transition in machine.update(.unknown, identity: nil, at: now) {
                    try emit("transition", ["state": transition.rawValue, "evidence": ["sampling_gap"]], at: now)
                }
                try emit("health", ["reason": "sampling_gap", "seconds": now.timeIntervalSince(lastSample)])
            }
            lastSample = now
            try emit("sample", ["state": state.rawValue, "evidence": evidence], at: now)
            for transition in machine.update(state, identity: identity, at: now) {
                let supporting = transition == .finished ? evidence + ["previous_working_and_idle_confirmed_for_two_seconds"]
                    : transition == .unknown && state != .unknown ? ["observation_identity_changed"] : evidence
                try emit("transition", ["state": transition.rawValue, "evidence": supporting], at: now)
            }
            if args.contains("--once") { break }
            // A timer keeps the run loop alive even when AX permission/observers are absent.
            let timer = Timer(timeInterval: 1, repeats: false) { _ in }
            RunLoop.current.add(timer, forMode: .default)
            CFRunLoopRunInMode(.defaultMode, 1, false)
            timer.invalidate()
        } while true
    }
}
