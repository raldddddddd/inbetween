# Architecture

This document describes the current implementation. Product intent and durable
behavior belong in [product.md](product.md); historical experiments and phase
reports are in [archive/](archive/README.md).

## System shape

Inbetween is a Swift package targeting macOS 13 or newer. The shipped product is
a SwiftUI `MenuBarExtra`; reusable domain logic lives in `InbetweenCore`.

| Area | Current implementation |
|---|---|
| Lifecycle input | Codex project hooks invoke `tools/fallback_lifecycle_probe.py`, which allowlists metadata and sends one Unix datagram. |
| Transport | `UnixDatagramEventReceiver` owns `/tmp/inbetween-lifecycle.sock` as a local `0600` socket. |
| App orchestration | `LifecycleViewModel` validates events, updates lifecycle and wait-session state, persists changes, controls monitoring, and dispatches notifications. |
| Domain model | `InbetweenCore` contains lifecycle, waits, activity contexts, classification, personal rules, presentation, and insight logic. |
| Activity monitoring | `ForegroundActivityMonitor` uses native workspace, idle-time, Accessibility, and selected Apple Events interfaces. |
| Persistence | JSON files under the user's `Application Support/Inbetween` directory store wait sessions and personal context rules. |
| UI | One reusable menu-bar window presents current state, reviews, seven-day insights, history, rules, permissions, and settings. |

There are no runtime package dependencies, network services, accounts, or
backend components.

## Lifecycle data flow

1. The checked-in `.codex/hooks.json` handles `UserPromptSubmit`,
   `PermissionRequest`, `Stop`, and `Interrupt`.
2. The Python bridge discards all fields except the event name, session/turn
   identifiers, permission mode, stop-hook flag, and timing metadata.
3. The bridge sends JSON to the local Unix datagram socket. Send failure is
   ignored so Inbetween cannot block or fail a Codex turn.
4. `LifecycleEventParser` validates identifiers and timestamps.
5. `LifecycleStateMachine` rejects duplicate, stale, out-of-order, and unrelated
   events. `WaitSessionTracker` applies the same accepted event to durable wait
   state.
6. Accepted changes are persisted atomically. A matching `Stop` also requests a
   local Ready notification.

The internal lifecycle states are `idle`, `active`, `attention`, and `ready`.
User-facing status is deliberately more conservative: an active wait remains
Working after a permission event until the separate delayed tracker observes an
eight-second persistent boundary. That promotion changes the UI only; permission
attention notifications are disabled. A continuation or terminal event clears
the boundary.

Only one current wait is tracked. A newly accepted turn makes any other active
session unfinished. On launch, persisted active sessions are also converted to
unfinished; a later matching event can resume or finish them without inventing
missing timestamps.

## Activity observation

Activity monitoring runs only while a wait is active.

- `NSWorkspace` reports foreground application changes.
- Quartz supplies only elapsed time since the last input, producing Active,
  Idle, or Away presence; the input itself is never recorded.
- When Accessibility is already trusted, focused-window title/document metadata
  and window-change notifications are available. App-level monitoring remains
  available without it.
- Chrome and Safari enrichment may query the front tab URL and title through
  their local Apple Events interfaces. Failures fall back to Accessibility or
  app-level context.
- Xcode, Visual Studio Code, Terminal, iTerm, and Finder have small native
  metadata parsers for project, document, terminal, and folder context.

Observations form exact activity segments. Collection is suspended across sleep
and app termination so unavailable time becomes an unobserved gap rather than a
fabricated segment.

## Classification and history

Completed waits are partitioned into non-overlapping classification slices.
Observed segments keep their source UUID; uncovered time becomes an explicit
Unclassified gap.

For an active-presence context, evidence is evaluated in this order:

1. the most-specific matching personal context rule;
2. explicit built-in application/category evidence;
3. supported project, workspace, terminal, or learning metadata;
4. confidence-gated semantic evidence from macOS Natural Language embeddings;
5. Unclassified when evidence is absent, neutral, or ambiguous.

Inactive presence always gates foreground evidence to Unclassified. Semantic
input is a compact representation of already retained metadata; query strings,
fragments, opaque path tokens, page bodies, and vectors are not persisted.

Manual corrections apply to specific review units/slices and do not replace the
automatic result. History and contributor summaries aggregate effective slice
durations. Older whole-wait records retain a compatibility path and are reported
as Not recorded when no classification exists.

Review grouping uses meaningful context identity plus presence, so Active, Idle,
and Away remain independently reviewable even for the same app or page.
Noncontiguous equivalent slices may share a review unit, but unobserved gaps do
not request review. Built-in obvious-app evidence includes canonical Steam and
Steam Helper handling, Discord, iPhone Mirroring, and the native Games category;
it applies only while presence is Active.

## Local files and diagnostics

- `wait-sessions.json` and `context-rules.json` live in
  `Application Support/Inbetween`, with private file permissions.
- `lifecycle-diagnostics.jsonl` is a best-effort local trace containing only
  lifecycle identifiers, timing, and state transitions.
- `/tmp/inbetween-stop-latency.jsonl` is development timing data.

Diagnostics must never affect lifecycle handling or notification delivery.

## Development-only components

- `InbetweenScenarioTools` and `inbetween-scenario-runner` exercise production
  slice classification, review, and duration aggregation in memory without
  reading real user data. Explicit legacy fixtures retain whole-wait coverage.
- `InbetweenSemanticTools`, `inbetween-semantic-eval`, and
  `inbetween-corrected-history-export` support local classifier evaluation. New
  exports label only corrected slices; legacy correction rows declare their
  whole-wait scope.
- `CodexAXProbe` and the experiment analyzer are retained Phase 0 artifacts. The
  shipped app does not depend on the Accessibility state detector or unsupported
  Codex SQLite probing.

`./scripts/verify-fast.sh` runs all scenarios, Swift tests, and Python tests.
`./scripts/verify-full.sh` adds debug/release bundle builds, strict release
validation, and an isolated clean-install check.
