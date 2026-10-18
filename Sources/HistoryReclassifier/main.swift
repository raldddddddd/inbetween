import Foundation
import InbetweenCore

let confirmed = CommandLine.arguments.dropFirst().contains("--confirm")
guard CommandLine.arguments.dropFirst().allSatisfy({ $0 == "--confirm" }) else {
    fputs("Usage: inbetween-history-reclassifier [--confirm]\nWithout --confirm, this is a read-only preview.\n", stderr)
    exit(2)
}

do {
    let store = WaitSessionStore()
    let reclassifier = WaitSessionHistoryReclassifier()
    let original = try store.load()
    let proposed = reclassifier.reclassify(original)
    let preview = reclassifier.report(before: original, after: proposed)

    print("Sessions inspected: \(preview.inspectedSessionCount)")
    print("Session summaries to reclassify: \(preview.reclassifiedSessionSummaryCount)")
    print("Classification slices to reclassify: \(preview.reclassifiedSliceCount)")
    print("Reclassified slices: \(preview.productiveSliceCount) Productive, \(preview.distractedSliceCount) Distracted")
    print("Final effective slices: \(preview.finalProductiveSliceCount) Productive (\(Int(preview.finalProductiveSliceDuration))s), \(preview.finalDistractedSliceCount) Distracted (\(Int(preview.finalDistractedSliceDuration))s)")
    print("Final effective session summaries: \(preview.finalProductiveSessionSummaryCount) Productive, \(preview.finalDistractedSessionSummaryCount) Distracted")
    print("Unobserved gaps preserved: \(preview.preservedUnobservedGapCount)")
    print("Manual overrides preserved: \(preview.preservedManualOverrideCount)")
    print("Manual Unclassified overrides to replace: \(preview.replacedManualUnclassifiedOverrideCount)")
    print("Remaining Unclassified summaries: \(preview.remainingUnclassifiedSummaryCount)")
    print("Remaining Unclassified slices: \(preview.remainingUnclassifiedSliceCount)")

    if confirmed {
        let report = try reclassifier.apply(to: store, confirmed: true)
        if let backupURL = report.backupURL {
            print("Verified pre-write backup: \(backupURL.path)")
        }
        print("Persisted reclassified records: \(report.reclassifiedRecordCount)")
        print("Reloaded store verification: passed")
    } else {
        print("Preview only; no history was written. Pass --confirm to apply after reviewing this summary.")
    }
} catch {
    fputs("Historical reclassification stopped: \(error.localizedDescription)\n", stderr)
    exit(1)
}
