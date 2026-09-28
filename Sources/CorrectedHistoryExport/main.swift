import Foundation
import InbetweenCore
import InbetweenSemanticTools

struct Arguments {
    var historyPath: String?
    var outputPath: String?
    var summaryOnly = false

    init() throws {
        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--history": historyPath = iterator.next()
            case "--output": outputPath = iterator.next()
            case "--summary": summaryOnly = true
            case "--help", "-h": throw ExportError.usage
            default: throw ExportError.usage
            }
        }
        if (historyPath == nil && CommandLine.arguments.dropFirst().contains("--history"))
            || (outputPath == nil && CommandLine.arguments.dropFirst().contains("--output"))
            || (summaryOnly && outputPath != nil) {
            throw ExportError.usage
        }
    }
}

enum ExportError: Error { case usage }

func usage() {
    print("""
    Usage:
      inbetween-corrected-history-export --summary [--history path]
      inbetween-corrected-history-export --output path [--history path]

    Reads local completed waits with a manual classification correction. No data
    is transmitted. Use an ignored path such as
    semantic-evaluation-exports/corrected-contexts.json for personal exports.
    """)
}

do {
    let arguments = try Arguments()
    let historyURL = arguments.historyPath.map(URL.init(fileURLWithPath:)) ?? WaitSessionStore.defaultFileURL()
    let dataset = CorrectedHistoryDatasetExporter.makeDataset(
        sessions: try WaitSessionStore(fileURL: historyURL).load()
    )
    print("Manually corrected completed waits: \(dataset.correctedSessionCount)")
    print("Corrected slices: \(dataset.correctedSliceCount)")
    print("Legacy whole-wait corrections: \(dataset.legacyWholeWaitCorrectionCount)")
    print("Usable rich activity contexts: \(dataset.exportedContextCount)")
    if dataset.skippedNonSemanticSegmentCount > 0 {
        print("Skipped app-only segments: \(dataset.skippedNonSemanticSegmentCount)")
    }
    if dataset.correctedSessionCount < 20 {
        print("Dataset is small; model comparisons are preliminary until more corrections accumulate.")
    }
    if let outputPath = arguments.outputPath {
        let outputURL = URL(fileURLWithPath: outputPath)
        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(dataset).write(to: outputURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        print("Wrote local dataset: \(outputURL.path)")
    } else if !arguments.summaryOnly {
        usage()
    }
} catch ExportError.usage {
    usage()
    exit(2)
} catch {
    fputs("Corrected-history export failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
