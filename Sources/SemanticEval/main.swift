import Foundation
import InbetweenCore
import InbetweenSemanticTools

private struct HandAuthoredEvaluationExample: Codable {
    let id: String
    let app: String
    let bundleID: String
    let domain: String?
    let pageTitle: String?
    let windowTitle: String?
    let resourceKind: ActivityResourceKind?
    let resourceName: String?
    let documentName: String?
    let resourcePath: String?
    let expected: String?
}

private struct EvaluationExample {
    let id: String
    let source: String
    let context: ActivityContext
    let expectedSemanticCategory: String?
    let semanticCategoryIsAmbiguous: Bool
    let userProductivityLabel: String?
    let correctionScope: String?
    let automaticClassification: String?
    let automaticReasonCodes: [String]
    let automaticAgreesWithManualCorrection: Bool?
}

private struct EvaluationResult: Encodable {
    let id: String
    let source: String
    let expectedSemanticCategory: String?
    let semanticCategoryIsAmbiguous: Bool
    let userProductivityLabel: String?
    let correctionScope: String?
    let automaticClassification: String?
    let automaticReasonCodes: [String]
    let automaticAgreesWithManualCorrection: Bool?
    let input: String
    let topCategory: String?
    let topSimilarity: Double?
    let competingCategory: String?
    let competingSimilarity: Double?
    let margin: Double?
    let evidence: String
}

private func loadExamples(at path: String) throws -> [EvaluationExample] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    if let handAuthored = try? JSONDecoder().decode([HandAuthoredEvaluationExample].self, from: data) {
        return handAuthored.compactMap { example in
            guard let context = ActivityContext(
                applicationBundleIdentifier: example.bundleID,
                applicationName: example.app,
                windowTitle: example.windowTitle,
                browserDomain: example.domain,
                browserPageTitle: example.pageTitle,
                resourceKind: example.resourceKind,
                resourceName: example.resourceName,
                documentName: example.documentName,
                resourcePath: example.resourcePath
            ) else { return nil }
            return EvaluationExample(
                id: example.id,
                source: "hand-authored",
                context: context,
                expectedSemanticCategory: example.expected,
                semanticCategoryIsAmbiguous: example.expected == nil,
                userProductivityLabel: nil,
                correctionScope: nil,
                automaticClassification: nil,
                automaticReasonCodes: [],
                automaticAgreesWithManualCorrection: nil
            )
        }
    }

    let exportedDecoder = JSONDecoder()
    exportedDecoder.dateDecodingStrategy = .iso8601
    let exported = try exportedDecoder.decode(CorrectedHistorySemanticDataset.self, from: data)
    return exported.examples.compactMap { example in
        guard let context = ActivityContext(
            applicationBundleIdentifier: example.applicationBundleIdentifier,
            applicationName: example.applicationName,
            windowTitle: example.windowTitle,
            browserDomain: example.browserDomain,
            browserPageTitle: example.browserPageTitle,
            resourceKind: example.resourceKind.flatMap(ActivityResourceKind.init(rawValue:)),
            resourceName: example.resourceName,
            documentName: example.documentName,
            resourcePath: example.resourcePath,
            presenceState: example.presenceState.flatMap(UserPresenceState.init(rawValue:))
        ) else { return nil }
        return EvaluationExample(
            id: example.id,
            source: "manual-correction",
            context: context,
            expectedSemanticCategory: example.semanticCategoryLabel,
            // Missing labels in real history mean unknown, not deliberately
            // ambiguous. This keeps user productivity and semantic labels apart.
            semanticCategoryIsAmbiguous: false,
            userProductivityLabel: example.manualClassification,
            correctionScope: example.correctionScope.rawValue,
            automaticClassification: example.automaticClassification,
            automaticReasonCodes: example.automaticReasonCodes,
            automaticAgreesWithManualCorrection: example.automaticAgreesWithManualCorrection
        )
    }
}

let arguments = CommandLine.arguments.dropFirst()
let jsonMode = arguments.first == "--json"
let corpusPath: String
if jsonMode {
    guard arguments.count == 2 else {
        fputs("Usage: inbetween-semantic-eval [--json path-to-hand-corpus-or-export]\n", stderr)
        exit(2)
    }
    corpusPath = String(arguments[arguments.index(after: arguments.startIndex)])
} else {
    corpusPath = "tools/semantic_eval_corpus.json"
}

do {
    let examples = try loadExamples(at: corpusPath)
    let analyzer = SemanticActivityAnalyzer()
    let results = examples.compactMap { example -> EvaluationResult? in
        guard let description = SemanticActivityDescription(context: example.context) else { return nil }
        let inference = analyzer.inference(for: example.context)
        let evidence: String
        switch analyzer.evidence(for: example.context) {
        case .productive: evidence = "productive"
        case .distracting: evidence = "distracting"
        case nil: evidence = "none"
        }
        return EvaluationResult(
            id: example.id,
            source: example.source,
            expectedSemanticCategory: example.expectedSemanticCategory,
            semanticCategoryIsAmbiguous: example.semanticCategoryIsAmbiguous,
            userProductivityLabel: example.userProductivityLabel,
            correctionScope: example.correctionScope,
            automaticClassification: example.automaticClassification,
            automaticReasonCodes: example.automaticReasonCodes,
            automaticAgreesWithManualCorrection: example.automaticAgreesWithManualCorrection,
            input: description.text,
            topCategory: inference?.category.rawValue,
            topSimilarity: inference?.similarity,
            competingCategory: inference?.competingCategory?.rawValue,
            competingSimilarity: inference?.competingSimilarity,
            margin: inference?.margin,
            evidence: evidence
        )
    }

    if jsonMode {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(results), as: UTF8.self))
    } else {
        for result in results {
            print("Input: \(result.input)")
            if let label = result.userProductivityLabel {
                print("  Manual productivity label: \(label); scope: \(result.correctionScope ?? "unknown"); automatic: \(result.automaticClassification ?? "Not recorded")")
            }
            guard let category = result.topCategory, let score = result.topSimilarity else {
                print("  Native sentence embedding unavailable; no semantic evidence.\n")
                continue
            }
            let competitor = result.competingCategory.map { " vs \($0) \(String(format: "%.3f", result.competingSimilarity ?? 0))" } ?? ""
            let expected = result.expectedSemanticCategory ?? (result.semanticCategoryIsAmbiguous ? "ambiguous" : "unlabeled")
            print("  Expected semantic category: \(expected)")
            print("  Top: \(category) \(String(format: "%.3f", score)); margin \(String(format: "%.3f", result.margin ?? 0))\(competitor)")
            print("  Evidence: \(result.evidence)\n")
        }
    }
} catch {
    fputs("Semantic evaluation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
