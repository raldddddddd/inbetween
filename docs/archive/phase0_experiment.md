# Running the Phase 0 experiment

This is a command-line Accessibility probe, not the productivity app. The shipped
rules are empty. Calibration against the current Codex Desktop build found no
privacy-safe, Codex-specific Accessibility signal that distinguishes idle from
working, so every observed client state remains `unknown`.

## Build and permissions

From the repository root:

```sh
swift build
swift test
python3 -m unittest discover -s tools -p 'test_*.py' -v
swift run codex-ax-probe --request-permission --once
```

Enable the requesting executable or its launching terminal (as identified by
macOS) in **System Settings → Privacy & Security → Accessibility**, then restart
the probe. A denial prints instructions and JSON health/sample records, with
state `unknown`, and does not crash. No other permission is requested. Use a
stable executable path while testing; permission identity may change after
rebuilding or changing the launching host. `--request-permission` is explicit;
ordinary runs only check permission.

On this sandboxed development host, use writable module caches:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/inbetween-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/inbetween-swift-cache swift test --scratch-path /tmp/inbetween-phase0-build --disable-sandbox
/tmp/inbetween-phase0-build/out/Products/Debug/codex-ax-probe --once
```

`--disable-sandbox` disables SwiftPM's build subprocess sandbox, not macOS
Accessibility consent. No packages or build plugins are used.

## Discover controls and calibrate

1. Open Codex Desktop with a Codex conversation. The default target bundle ID is
   `com.openai.codex`. This was observed on the current installation in Computer
   Use's application inventory, the running macOS application registry, and
   `/Applications/ChatGPT.app/Contents/Info.plist` (app version 26.924.22138,
   build 11645). Use `--bundle-id` only if a later installation differs, and
   record that difference with the test results.
2. Take short inspections in known idle, working, approval, and clarification
   states:

   ```sh
   swift run codex-ax-probe --inspect --once
   ```

3. If multiple windows are open, select the zero-based AX window index using
   `--window 0` (or the appropriate index). Without selection, multiple windows
   produce `unknown`. Window order is not a persistent conversation identifier.
4. Inspect output contains paths, roles, and SHA-256 fingerprints of identifiers,
   button/window/progress titles and descriptions. It never prints raw strings,
   input values, document text, or large raw trees. Paths are debugging aids;
   detection does not use positions or paths. Prefer a stable `AXIdentifier`
   attached to a Codex-specific control. A hashed window title is a weaker scope
   signal, and usually unsuitable if it changes between tasks.
5. Copy an observed role, attribute name, and fingerprint into
   `experiments/rules.json`. For example, the shape of one rule is:

   ```json
   {"role":"AXButton","attribute":"AXIdentifier","sha256":"64-character observed hash"}
   ```

   `scope` must identify Codex rather than an ordinary ChatGPT conversation.
   Each of `idle`, `working`, and `needsUser` holds alternative positive signals
   for that state. All arrays initially have zero rules. No absence of a Stop
   button is treated as evidence of idle. A known exact control label can be
   fingerprinted with `python3 tools/experiment.py hash 'exact control label'`.
   Do not hash prompts/source code into rules. Hashes minimize disclosure but
   are not encryption; short control labels can be guessed.
6. Record candidate signals and their client version, locale, roles, and
   behavior in `phase0_report.md`. If working and idle controls coexist, or a
   generic control appears in normal chat, do not use those rules. Conflicting
   states produce `unknown`. These rules intentionally cannot infer state from
   free-form transcript text. If needed evidence is exposed only there, record
   this limitation before broadening collection.
7. Freeze rules before the measured runs. Separate calibration observations
   from evaluation. Rerun the measured suite after rule changes.

### Automation assessment and completed calibration

Idle/working calibration was automated without using Computer Use to inspect
Codex. A trusted Terminal launched the external `codex-ax-probe`, which sampled
`com.openai.codex` continuously while this Codex task supplied controlled working
periods and scheduled continuations supplied conservative post-turn idle periods.
The task/heartbeat boundary was the independent state label; probe output was not
used as ground truth. The observer recorded its own timestamps throughout.

Two working and two idle intervals were compared, with 48 and 128 complete
foreground working snapshots and 104 and 33 complete idle snapshots. The
diagnostic read roles/subroles, supported attributes/actions, enabled/focused and
safe Boolean state, hashed control labels and identifiers, and structural child
relationships. It did not read values, prompt/transcript/document text, source
code, screenshots, OCR, or vision output.

The renderer-facing group chain exposed no identifiers, progress controls, or
busy-state change; every exposed `AXElementBusy` value was false. The only
apparent title-fingerprint change was below the native full-screen window button.
Its enabled state alternated between consecutive samples, and the second working
interval contained both supposed working and idle fingerprints at once. It is a
window-menu artifact and is not Codex state evidence. No rule was configured.

Reliable end-to-end measured-evaluation automation is still unavailable on the
current installation:

- Computer Use independently reports the installed/running app and bundle ID,
  but its safety boundary refuses access to `com.openai.codex`. It therefore
  cannot submit controlled tasks, observe Codex controls, or timestamp task
  transitions.
- The installed Codex CLI 0.158.0-alpha.2.1 publishes an experimental app-server
  schema with `turn/started`, `turn/completed`, thread active status, and
  `waitingOnApproval`/`waitingOnUserInput` flags. Those would be suitable as an
  independent ground-truth stream because they do not use this probe's AX
  classification. The running Desktop session does not expose the documented
  control socket, however: `codex app-server proxy` reports that
  `~/.codex/app-server-control/app-server-control.sock` does not exist. Starting
  a separate daemon would create CLI/app-server tasks that are not the Desktop
  window observed by this probe, so those events cannot validate Desktop AX
  detection.
- The Codex app thread API can show a coarse current status such as `active` or
  `idle`, but it is not callable by a standalone local harness and does not
  supply the complete independently timestamped approval, input, cancellation,
  failure, sleep/wake, window, and visibility sequence required by the matrix.
- macOS process state only proves that the app and helper processes exist. During
  active work, the relevant processes may be sleeping between events; process
  state cannot distinguish idle, working, or needs-user states.
- Expanded repeated idle/working AX inspection exposes no stable positive
  Codex-specific state signal. The native window-menu differences are unrelated
  to task state and cannot be used to calibrate rules.

The existing probe and analysis tool still automate safe mechanical work:
detector timestamps/samples/transitions, structured JSONL capture, metric
matching, latency calculations, coverage accounting, and conservative exclusion
of incomplete runs. They do not establish ground truth. No new automated truth
harness is included because it would either reuse the detector, target a
different Codex runtime, or infer ambiguous state.

| Experiment work | Automated now | Independent human confirmation |
|---|---:|---:|
| Confirm installed bundle ID and process/window presence | Yes | Review only |
| Capture AX snapshots and detector transitions with timestamps | Yes | Label the actual state |
| Calculate matches, misses, false positives, accuracy and latency | Yes | Review ambiguous/extra events |
| Verify the required run count and scenario-key coverage | Yes | Perform and validate every scenario |
| Establish idle/working ground truth for this calibration | Yes | Review only |
| Establish full needs-user/finished evaluation ground truth | No | Required |
| Submit tasks, answer approvals/input, cancel, switch or relaunch | No | Required |
| Control foreground/background, minimize, sleep/wake and concurrency | No | Required |

No one of the 20 required measured scenarios was started. Each would still need
an independent state label and scenario-condition confirmation, and there are no
calibrated AX rules to evaluate.

If a future Desktop version exposes its own supported app-server control socket,
reassess a read-only event recorder. It must bind event thread/turn IDs to the
same Desktop conversation selected for AX inspection, record only event metadata
and timestamps, preserve the full 30-run/20-scenario plan, and mark gaps or
conflicts inconclusive. Do not use that event stream as the production detector
without a separate architecture decision.

### Calibration stop condition reached

Repeated real captures found no stable positive Codex state signal. Leave
`experiments/rules.json` unchanged and stop this Accessibility calibration. Do
not begin the 30-run measured matrix with empty or guessed rules. No further
idle/working capture command is required from the user for this build. A later
Codex Desktop version may be recalibrated from scratch if its AX provider changes.

The probe polls once per second after each snapshot, with AX window notifications
also waking it. Snapshot work adds latency. It caps traversal at 2,000 elements,
40 levels, and a two-second deadline; failed/truncated snapshots give `unknown`.
It uses a two-second idle confirmation before `finished`. Persistent state then
returns to `idle`. Evidence loss, changed window identity, or a sampling gap over
five seconds invalidates completion history. This can miss completions across
sleep or switching, and must be measured, not hidden.

## Record ground truth independently

The calibration orchestration above established only idle/working intervals for
this task. If a future measured matrix becomes possible, use a separate terminal
and a human observer for its full ground truth. Do not use the probe's state as
ground truth. Each run needs a unique ID and a baseline before submission. Run
the detector before marking the baseline:

```sh
swift run codex-ax-probe --run r01 --log experiments/detector.jsonl
```

In the second terminal, record each actual event (example run):

```sh
python3 tools/experiment.py mark --truth experiments/truth.jsonl --run r01 --scenario text --event idle
python3 tools/experiment.py mark --truth experiments/truth.jsonl --run r01 --scenario text --event submitted
python3 tools/experiment.py mark --truth experiments/truth.jsonl --run r01 --scenario text --event working
python3 tools/experiment.py mark --truth experiments/truth.jsonl --run r01 --scenario text --event finished --outcome completed
python3 tools/experiment.py mark --truth experiments/truth.jsonl --run r01 --scenario text --event end
```

Mark `needsUser` when approval/input is actually requested, `userInput` when the
user answers, and `working` again when work actually resumes. Mark the terminal
event `finished` at actual completion, failure, or cancellation with the matching
`--outcome completed|failed|cancelled`. Keep the probe running for at least five
seconds after the terminal event, then mark `end` and stop with Ctrl-C.

`--time UNIX_SECONDS` allows the independently recorded actual event time to be
entered later. Human reaction and typing delay affect apparent latency; note
ground-truth uncertainty. Do not record task contents. Record unknown/lost
visibility as `unknown`; never invent a state you could not observe. For sleep,
background and minimized scenarios, use independently known task execution or a
second observer; a scenario without credible ground truth is inconclusive.

For immediate follow-up tasks and concurrent/switch scenarios, keep one probe
running with the same run ID; add each submitted, working, needsUser and terminal
event in chronological order. Do not restart between tasks or hide extra
transitions. If concurrent work cannot be separately attributed, record that
limitation. Do not count a synthetic event sequence as a real controlled run.

## Required run matrix

Minimum allocation: **30 controlled runs**, all 20 scenarios, with repeats.
Counts below are a starting plan; repeat further when results are inconsistent.

| Scenario key | Scenario | Runs |
|---|---|---:|
| text | Simple text response within Codex | 2 |
| small-edit | Small file edit | 2 |
| multi-edit | Multi-file edit | 1 |
| shell | Long shell command | 1 |
| build | Build operation | 1 |
| tests | Test suite operation | 2 |
| approval | Approval request | 2 |
| clarification | Clarification/user input request | 2 |
| resume | Work resumes after approval | 2 |
| failure | Task failure | 1 |
| cancellation | User cancellation | 2 |
| compaction | Context compaction | 1 |
| switch | Switch Codex conversations during work | 2 |
| background | ChatGPT in background | 2 |
| minimized | ChatGPT minimized | 2 |
| sleep-wake | Sleep and wake | 1 |
| relaunch | ChatGPT quit/relaunch | 1 |
| back-to-back | Task immediately followed by another | 1 |
| quiet-long-task | Long task with little visible change | 1 |
| concurrent | Multiple active conversations, if permitted | 1 |

Also check denied/revoked permission, absent process, multiple windows, locale
changes and ordinary ChatGPT responses as negative controls. If the client does
not permit concurrency, explicitly record that fact; the analyzer intentionally
does not waive scenario coverage automatically.

## Calculate and review

```sh
python3 tools/experiment.py analyze --truth experiments/truth.jsonl --detector experiments/detector.jsonl --output experiments/controlled-metrics.json
```

The analyzer matches each actual working start/resumption, needs-user request,
and terminal event to the earliest detector transition in the corresponding
ground-truth state interval. Each detector transition can match once. Unmatched
actual events are misses; unmatched detector events are false positives. All
unmatched finishes are conservatively counted as premature or extra finishes;
per-run details support manual differentiation. Exact event boundaries use a
half-open interval. Ground-truth timestamps must use the same Mac clock.

For each event type it reports precision, recall, and strict event accuracy
`TP / (TP + misses + false positives)`. Latency is measured for matched events
only; misses remain explicitly counted. Unknown frequency is the fraction of
unknown observation samples, not elapsed-time weighting. Runs lacking baseline,
submission, start, terminal outcome or end are excluded and listed. Metrics on
zero real runs are unavailable, never 100%. Keep logs local; JSONL is opt-in and
not rotated, so stop runs when done.

The quantitative gate requires 30 valid runs, all scenarios, at least 95% working
and finish event accuracy, median latency at most three seconds and zero extra
finishes. This is stricter than allowing isolated extra finishes. `needsUser`
has no numerical threshold in the specification: review its precision/recall and
false alarms explicitly. The script always leaves the recommendation at
`DO_NOT_PROCEED` pending human review of stable signals and the qualitative
criteria. It does not automatically authorize Phase 1. Update the written report
with the real evidence and a justified `PROCEED`, `PROCEED_WITH_LIMITATIONS`, or
`DO_NOT_PROCEED` decision.
