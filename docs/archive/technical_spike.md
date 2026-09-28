# Phase 0 Technical Spike — Codex State Detection

## 1. Objective

Determine whether a native macOS process can reliably infer the current state of ChatGPT Desktop / Codex without screenshots, cloud AI, or modifying the user's Codex workflow.

This phase is an experiment, not the product.

The key question is:

> Can macOS Accessibility information reliably tell us when Codex starts working, needs the user, and finishes?

## 2. Primary Approach

Use macOS Accessibility APIs.

Relevant native concepts may include:

- `AXUIElement`
- `AXObserver`
- `NSWorkspace`
- `NSRunningApplication`

The prototype should:

1. Detect whether ChatGPT Desktop is running.
2. Locate relevant ChatGPT/Codex windows.
3. Inspect accessible roles, labels, values, titles, buttons, and status elements.
4. Observe UI changes where possible.
5. infer a small state machine.
6. Log every state transition with a timestamp and supporting evidence.

Do not use screenshots in the first experiment.

## 3. State Model

The detector should initially expose:

### `idle`

ChatGPT/Codex is available, but no tracked Codex task is actively executing.

### `working`

A Codex task is actively reasoning, editing, running commands, running tools, testing, or otherwise processing.

### `needsUser`

Codex cannot continue until the user provides input, approval, or a decision.

### `finished`

A transition event emitted when a previously active task reaches a ready/terminal state.

After `finished`, the persistent state may return to `idle`.

### `unknown`

The detector cannot confidently determine the state.

Prefer `unknown` to guessing.

## 4. First Prototype

The Phase 0 program may be a simple Swift command-line executable or minimal macOS app.

It does not need polished UI.

Example output:

```text
16:02:11 CHATGPT_FOUND
16:02:14 IDLE
16:03:07 WORKING evidence="Stop button visible"
16:05:33 NEEDS_USER evidence="Approval controls visible"
16:05:48 WORKING
16:09:12 FINISHED
16:09:12 IDLE
```

For debugging, the prototype may print a sanitized representation of relevant Accessibility elements.

Do not persist large Accessibility tree dumps by default.

## 5. Detection Strategy

Prefer signals in this order:

1. explicit accessibility state/control associated with active Codex work,
2. stable accessible labels or buttons,
3. observable window/control transitions,
4. multiple weak signals combined by deterministic rules.

Do not depend on one hard-coded English string if a more structural signal exists.

Do not use pixel positions.

Do not use OCR.

Do not use screenshots or vision models in Phase 0.

## 6. State Machine Requirements

The detector should use transition history.

For example, an idle-looking UI after a known `working` state may generate:

```text
working -> finished -> idle
```

An idle-looking UI seen when the detector first attaches should simply be:

```text
idle
```

The detector must avoid repeatedly emitting `finished`.

## 7. Ground-Truth Testing

Testing must compare detector output against manually recorded ground truth.

For each controlled run, record:

- prompt/task submitted time,
- actual work start,
- actual approval/input request,
- user approval/input time,
- actual completion/failure/cancellation time,
- detector transitions,
- detector latency,
- incorrect transitions.

The experiment should contain at least 30 controlled task runs before a reliability conclusion is made.

## 8. Required Scenarios

At minimum test:

1. simple text response,
2. small file edit,
3. multi-file edit,
4. long shell command,
5. build operation,
6. test suite operation,
7. approval request,
8. clarification/user-input request,
9. work resumes after approval,
10. task failure,
11. user cancellation,
12. context compaction,
13. switching Codex conversations,
14. ChatGPT in the background,
15. ChatGPT minimized,
16. sleep and wake,
17. ChatGPT quit/relaunch,
18. Codex task followed immediately by another task,
19. long-running task with little visible UI change,
20. multiple open Codex conversations if the client permits concurrent activity.

Repeat representative cases enough times to expose inconsistent behavior.

## 9. Metrics

Track:

- working-start true positives,
- working-start misses,
- false working starts,
- needs-user true positives,
- needs-user misses,
- false needs-user states,
- finish true positives,
- missed finishes,
- premature finishes,
- median transition latency,
- worst observed transition latency,
- unknown-state frequency.

## 10. Provisional Go / No-Go Criteria

The Accessibility-based detector may be used as the product foundation only if:

- all critical state transitions can be detected without screenshots,
- there are no repeated premature `finished` events while Codex is still working,
- `working` and `finished` transition accuracy is at least 95% across the controlled runs,
- median transition latency is 3 seconds or less,
- `needsUser` is reliable enough to notify without frequent false alarms,
- minimized/background operation remains functional,
- behavior is explainable from stable Accessibility signals rather than fragile pixel positions.

These thresholds are provisional. If the UI exposes a clearly deterministic event source, use stricter expectations.

## 11. Failure Modes to Document

Record whether detection breaks because of:

- Accessibility permission missing,
- ChatGPT process not found,
- relevant controls not exposed,
- labels changing,
- multiple windows,
- localization,
- minimized/background behavior,
- UI redesign,
- sleep/wake,
- concurrent Codex work.

## 12. Fallback Investigation

Only if Accessibility is insufficient, investigate alternatives in this order:

1. supported Codex-local events, logs, hooks, or app-server interfaces,
2. a local companion integration with a supported Codex mechanism,
3. screen capture / vision only as a last resort.

Do not depend on undocumented internal protocols in production without explicitly documenting the compatibility risk.

## 13. Deliverables

Phase 0 should produce:

- working probe source,
- permission instructions,
- structured transition log,
- test-run results,
- accuracy/latency summary,
- list of reliable Accessibility signals,
- list of unreliable signals,
- recommendation:
  - `PROCEED`,
  - `PROCEED_WITH_LIMITATIONS`,
  - or `DO_NOT_PROCEED`.

## 14. Phase 0 Definition of Done

Phase 0 is done when:

- the probe builds and runs on the development Mac,
- Accessibility permission handling works,
- all required test scenarios have been exercised,
- metrics have been calculated,
- limitations are documented,
- a clear go/no-go decision has been made.

Do not begin the full productivity product before this decision.
