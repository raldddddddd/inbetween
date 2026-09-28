# Phase 0 report — 2026-09-27

**Decision: DO_NOT_PROCEED.** The prototype is implemented and idle/working
calibration is complete for the current client build. Expanded, repeated real AX
captures found no stable positive Codex-specific state signal within the privacy
constraints. Accessibility calibration is therefore insufficient. The 30-run
measured evaluation was not started because there is no detector rule to
evaluate. Phase 1 has not begun.

The empirically confirmed default target is now `com.openai.codex`. Computer
Use's application inventory, `lsappinfo`, the installed app's `Info.plist`, and
the two existing AX inspection captures agree on that identifier. The current
installation is `/Applications/ChatGPT.app`, version 26.924.22138, build 11645.

## Significant files

| File | Purpose |
|---|---|
| `Package.swift` | Native macOS executable and experiment tests |
| `Sources/CodexAXProbe/Probe.swift` | Permission handling, process/window discovery, bounded AX inspection, observer/polling, JSONL logs |
| `Sources/CodexAXProbe/DiagnosticPolicy.swift` | Privacy policy for diagnostic labels, alternate AX child relationships, and hashed metadata |
| `Sources/CodexAXProbe/Detector.swift` | Configurable deterministic rules and history-based state machine |
| `Tests/CodexAXProbeTests/DetectorTests.swift` | Completion, transient idle, scope conflicts, evidence loss, approval/resume tests |
| `Tests/CodexAXProbeTests/DiagnosticPolicyTests.swift` | Diagnostic traversal policy and content-suppression tests |
| `experiments/rules.json` | Empty calibration rules; no assumed English client labels |
| `tools/experiment.py` | Independent manual truth recording and event accuracy/latency calculations |
| `tools/test_experiment.py` | Synthetic metric correctness checks, not controlled Codex runs |
| `docs/archive/phase0_experiment.md` | Permission instructions, calibration workflow, complete run matrix, metric definitions |
| `README.md`, `.gitignore` | Entry point and exclusions for build caches/local test logs |

No external dependencies added or removed. The probe uses Swift/Foundation,
AppKit, ApplicationServices and CryptoKit supplied by macOS. The experiment helper
uses Python 3 standard-library modules. No screenshots, network services, cloud
AI, persistence framework, SwiftUI product UI or productivity features are added.
No commit was made; this directory was not a Git checkout during implementation.

## Verification results

Development host: Apple Silicon macOS, Apple Swift 6.4, Xcode macOS 27 SDK.
Deployment target: macOS 13 or newer. Other macOS versions have not been tested.

| Check | Result |
|---|---|
| Swift executable build | PASS through `swift test`, with writable temporary caches |
| Swift detector tests | PASS: 5 tests, 0 failures |
| Swift diagnostic policy tests | PASS: 7 tests, 0 failures |
| Python metric tests | PASS: 3 tests, 0 failures |
| Actual permission-denied launch | PASS: exit 0, health reason `accessibility_permission_missing`, unknown sample, no crash |
| Historical launch with old target absent | PASS: the prior `com.openai.chat` default had `processFound: false`, exit 0; this does not validate current-target absence handling with permission granted |
| Explicit absent target | PASS: `invalid.inbetween.not-running`, `processFound: false`, exit 0 |
| Continuous denied-permission probe | PASS: 4 samples over 3.3 seconds, minimum spacing 1.003 seconds, remained running until test termination |
| Metrics command with zero controlled runs | PASS: reports 0 runs, unavailable latency and `DO_NOT_PROCEED`; does not treat smoke logs as controlled runs |
| Granted-permission/no-process branch | NOT EXERCISED for the corrected target |
| macOS permission prompt and grant/revoke recovery | PARTIAL: the stable Terminal-launched executable was trusted throughout calibration; explicit revoke/recovery remains untested |
| Live AX windows, controls and notification subscriptions | PASS for inspection: corrected-target external observer found the process/window, registered 3 subscriptions, and continuously captured complete snapshots |
| Repeated idle/working calibration | INSUFFICIENT: 2 working and 2 idle intervals; no stable positive Codex-specific state signal |
| Controlled task scenarios | PENDING: 0 of 30 minimum runs; all 20 scenarios pending |
| Default target bundle ID | PASS: runtime/help default is `com.openai.codex`; one-shot output verified below |
| Computer Use ground truth | UNAVAILABLE: app inventory works, but direct access to `com.openai.codex` is safety-blocked |
| Desktop app-server ground truth | UNAVAILABLE: useful event schema exists, but the running Desktop session has no supported control socket |

Initial build failed because the sandbox prevented writes to the default module
cache. Redirecting module caches/scratch output to `/tmp` allowed compilation.
SwiftPM emitted user-cache warnings; they did not affect the passing build or
tests. The legacy Accessibility permission constant requires a
`@preconcurrency` import; the probe executes AX calls on the main actor.
An initial continuous-run check exposed extra polls when unrelated run-loop
sources woke it. The wait now continues through unrelated sources; the repeated
check confirmed the intended polling cadence without permission or AX observers.

The smoke runs are local JSONL files under `experiments/`, excluded from Git.
They establish safe execution only, not detection reliability. The metric tests
use artificial timelines to verify calculations and are never counted as task
runs. No detector start/finish/needs-user accuracy or latency can be calculated
from these smoke runs.

Historical smoke records created before the bundle correction contain
`com.openai.chat`. They remain unchanged because they are captured outputs, not
defaults or current evidence. The two later inspection captures target
`com.openai.codex` and successfully found the process, window, and three AX
observer subscriptions.

The rebuilt executable's verification run emitted `"bundle":"com.openai.codex"`
without a `--bundle-id` override and its help text showed the same default. A
direct sandbox launch lacked Accessibility consent and safely returned
`accessibility_permission_missing`; launching the stable executable through the
already trusted Terminal produced complete live calibration snapshots.

## Accuracy and latency summary

| Metric | Controlled evidence |
|---|---|
| Working true positives / misses / false starts | Not measured |
| Needs-user true positives / misses / false states | Not measured |
| Finish true positives / misses / premature finishes | Not measured |
| Working and finish accuracy ≥95% | Not established |
| Median latency ≤3 seconds / worst latency | Not measured |
| Unknown-state frequency | Not measured for controlled runs |
| Minimized/background operation | Not established |
| Stable, explainable client signals | Not established |

## Signals and limitations

**Reliable client Accessibility signals: none validated yet.** No AX rule is
enabled by default. Positive scope and state signals must be established before
evaluation. The probe can match stable identifiers or control label fingerprints
without hard-coded English words. Disabled elements are excluded from matching.
Control metadata is read transiently and hashed; raw labels/values are not logged.
Input values, transcript text, document text and source code are not read.

**Unreliable/unvalidated candidates:** generic Stop/Send controls (may appear in
normal ChatGPT), approval labels (may change by locale), enabled controls that
remain exposed offscreen, window titles (may vary with tasks), and UI absence.
These are cautions about candidates, not observed failures from a client test.
There is no proven task/conversation identifier yet. A completion cannot be
attributed to a task if the client does not expose that identity.

Repeated idle and working captures on the current installation expose no stable
positive Codex-specific distinction. The deeper renderer-facing group chain has
no identifiers, progress indicators, or changing busy state. The only repeated
fingerprint changes occurred below the native full-screen window control; their
enabled state alternated between samples, and both candidate fingerprints
coexisted during the second working interval. They are window-menu artifacts,
not task-state evidence. This is not enough to configure idle or working rules.

### Expanded diagnostic visibility

The old inspection was shallow in its output even when traversal succeeded. It
followed only `AXChildren` and emitted rows only for windows, buttons, menu
buttons, progress indicators, or elements with identifiers. Groups, scroll
areas, web areas, toolbars and other containers without identifiers were omitted
from the JSON. It also did not report subroles, focus, help, supported attributes,
actions, parameterized attributes, or alternate descendant relationships. The
three generic buttons are likely native window controls, but the old output did
not include their subroles and therefore could not establish that.

Diagnostic mode now:

- emits every visited element with role/subrole, enabled/focused flags, supported
  attribute names, parameterized attribute names, action names and child counts;
- fingerprints identifiers on every role and title/description/help only on an
  allowlist of control roles;
- records that label-like attributes were suppressed on content/container roles
  without reading their values;
- follows `AXChildren`, `AXVisibleChildren`, `AXContents`, `AXRows`, `AXColumns`,
  `AXTabs`, and `AXChildrenInNavigationOrder`, with cycle/duplicate detection and
  the existing depth, element and time bounds;
- fingerprints `AXDOMIdentifier` when exposed and records safe Boolean state
  attributes such as `AXElementBusy`, selected, required, edited, minimized,
  main, modal and full-screen state;
- adds the application's focused AX element as a diagnostic root when available,
  which may expose a renderer subtree not attached to the window's ordinary
  children.

Normal non-`--inspect` detection keeps the previous metadata and `AXChildren`
behavior. No rule was added or changed. Two working intervals supplied 48 and
128 complete foreground snapshots; two conservative idle intervals supplied 104
and 33. The observer remained external and independently timestamped, and task
activity supplied the state labels. No prompt, transcript, document, source,
screen, OCR, or vision content was collected.

## Independent automation assessment

The requested idle/working calibration was automated successfully without using
Computer Use to inspect Codex. A trusted Terminal launched the external probe;
this chat's active and scheduled post-turn idle periods supplied independent
ground truth. The probe continued sampling across both transitions.

Reliable end-to-end measured-evaluation automation is not currently possible
without weakening the experiment. The supported
Codex CLI can generate an experimental app-server schema containing exact turn
start/completion and needs-user flags, but `codex app-server proxy` cannot attach
to this Desktop instance because its documented control socket is absent. A new
daemon would exercise a different runtime and would not produce Desktop AX
transitions. The app's task-list API provides only coarse status to this agent,
not a reproducible local event stream for the repository harness. macOS process
states are likewise not task states.

Automated detector capture, timestamps, metrics, coverage checks, and incomplete
run exclusion remain usable. Calibration state labels, task submission, approval
and clarification timing, cancellation/failure confirmation, window/background/
minimized conditions, sleep/wake, relaunch, conversation switching, compaction,
and concurrent-task attribution still require human confirmation. Ambiguous or
unobserved transitions remain `unknown`/inconclusive.

No product automation harness was added. Calibration orchestration used the
existing external executable and local temporary logs only. A measured-evaluation
harness based on the detector's own AX signal would create invalid ground truth.
The detailed evidence and future reassessment conditions are in
`phase0_experiment.md`.

Document during actual runs: permission loss, absent/relaunched process,
unexposed controls, changed labels/localization, multiple windows, background or
minimized behavior, redesigns, sleep/wake, concurrent work and conversation
switching. The probe:

- Reports `unknown` for missing permission, unavailable windows, incomplete
  snapshots, missing Codex scope, absent state signals and conflicts.
- Refuses automatic selection when more than one window is open. Explicit AX
  window index selection is experimental and may drift after reordering.
- Uses PID/window index/title fingerprint as a coarse observation identity.
  Switching conversations in a window with the same title can escape that check.
- Invalidates completion history on unknown observations, changed identity or
  sampling gaps; this favors missed finishes over unsupported completion events.
- Requires two seconds of positive idle evidence before one `finished` event,
  then returns to idle. This does not prove the UI's idle signal is correct.
- Uses notification wakeups for app window changes plus polling. Actual observer
  support has not been verified. Traversal bounds and IPC time add latency;
  large trees may stay unknown.
- Tracks one selected window. It cannot yet promise attribution of concurrent
  work or completions in hidden conversations. This must be part of the gate.

No detector fallback has been adopted. Accessibility calibration is complete for
the current build and insufficient; the app-server inspection assessed only an
independent test oracle. The separate sandbox launch's missing permission was
not used as evidence for that conclusion.

## Specification conflicts and deviations

No product features or exclusions were violated. The CLI is expressly allowed
by the spike despite the eventual SwiftUI direction. The three source
specifications were left unchanged.

The app-server protocol was inspected only as a possible independent experiment
oracle, as explicitly requested for this continuation. It was not adopted as a
detector, production dependency, or fallback architecture, and no daemon was
started. Phase 0 still evaluates the Accessibility detector specified by the
technical spike.

The technical spike says at least 30 controlled runs are required before a
reliability conclusion and defines Phase 0 completion as exercising all required
scenarios and calculating metrics. Those requirements are **not met**. The user
explicitly required stopping calibration if expanded AX inspection still could
not distinguish repeated known-idle and known-working intervals, so the matrix
was not started with an uncalibrated detector. `DO_NOT_PROCEED` is the Phase 0
gate outcome for the current AX approach, not a measured accuracy claim.

The specification does not define a numerical needs-user reliability threshold
or a single formula for transition accuracy. The helper reports precision,
recall and a conservative combined event accuracy; needs-user false-alarm
acceptability remains an explicit review item. The automated quantitative check
requires zero unmatched finishes, which is stricter than the provisional wording
about no repeated premature finishes. Neither choice relaxes the gate.

## Required user work and Phase 1 handoff

No further idle/working calibration command is required from the user for this
client build. Do not start the 30-run matrix with empty or guessed rules. A future
client version may be recalibrated if its Accessibility provider changes.

Phase 1 must wait. There is no validated production detector to extract and no
completion/latency accuracy to measure. Any later feasibility work should follow
the technical spike's fallback order and investigate supported local Codex events
before considering screen capture. That would be additional Phase 0 work and
requires separate authorization.

The authorized fallback investigation is now documented in
`phase0_fallback_report.md`. It found no supported passive attachment point for
Desktop's existing App Server session. Supported lifecycle hooks and an
unsupported read-only thread-history projection are the only promising local
candidates; neither yet supplies a validated four-state production detector.

The subsequent supported-hook smoke test validated the simplified MVP event
model against the existing Desktop chat after hook trust and an application
restart: two normal start/stop pairs, an approval signal, and background
operation all produced matching turn-scoped metadata. This is sufficient to
unblock Phase 1 for the explicitly simplified `started`, `stopped`, and
`needs-attention` event model. It does not retroactively satisfy the original
four-state or 30-run acceptance criteria, and Phase 1 has not begun.
