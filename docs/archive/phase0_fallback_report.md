# Phase 0 fallback lifecycle feasibility — 2026-09-27

## Outcome

**Updated after supported-hook smoke test:** the simplified MVP lifecycle event
model is unblocked for `UserPromptSubmit` (task started), `Stop` (task stopped),
and `PermissionRequest` (permission boundary/attention signal). Two consecutive
normal Desktop turns produced one start and one stop each with matching session
and turn identifiers. A controlled approval turn produced `UserPromptSubmit`,
`PermissionRequest`, and `Stop` with one turn identifier. Hooks continued to run
after Finder was activated over Codex Desktop. `Interrupt` remains configured
but was not exercised. Phase 1 was not started.

The hook required an application restart before the existing Desktop chat loaded
the newly installed and trusted definition. Trust was persisted through one
separate `codex --no-daemon` session used only for the documented `/hooks`
review flow; no CLI task was submitted and no CLI event was counted.

The already-running Codex Desktop session has no supported, passive read-only
status endpoint that a third-party macOS app can attach to in the tested build
(`com.openai.codex`, app 26.924.22138, bundled Codex 0.158.0-alpha.2.1).

Two mechanisms merit a controlled follow-up experiment:

1. **Codex lifecycle hooks** are supported and run in Codex in the ChatGPT
   desktop app. They can report turn submission, approval requests, stops and
   interruptions with low latency. They are opt-in instrumentation rather than
   passive observation, require hook trust, receive content-bearing input that
   a privacy-safe recorder must discard, and do not document a distinct event
   for a clarification/user-input request.
2. **`thread_history_1.sqlite`** reflects the existing Desktop thread and exposes
   turn start/terminal status and timestamps. It is unsupported internal state,
   has no `needsUser` distinction, and must not become production architecture
   without a separate decision. The read-only prototype labels `inProgress` as
   `activeUnknown`, not `working`, because it cannot distinguish execution from
   a turn blocked on the user.

No Accessibility code or rules were changed. No CLI task, replacement App Server,
or App Server daemon was started. Phase 1 was not started.

## Candidate assessment

| Candidate | Existing Desktop task | States/transitions | Expected latency | Background/minimized | Support and fragility | Privacy and third-party feasibility |
|---|---|---|---|---|---|---|
| Desktop-owned App Server protocol | Yes, internally | Exact thread active/idle/error flags, `waitingOnApproval`, `waitingOnUserInput`, turn start/completion, approval/input requests | Event-stream latency, expected subsecond | Yes; runtime events do not depend on UI visibility | Protocol is documented, but attachment to Desktop's private instance is not exposed | Best data minimization is possible if attached, but no usable third-party endpoint exists in this build |
| Codex lifecycle hooks | Yes | `UserPromptSubmit`, `PermissionRequest`, `Stop`, `Interrupt`; no documented clarification-specific event | Hook dispatch, expected subsecond to a few seconds | Yes; runtime-driven | Supported in local Codex clients, opt-in, definition-specific trust required | A third-party app could ship a trusted plugin/hook that sends only allowed metadata to a local socket; the hook process still receives sensitive fields and must discard them |
| First-party Desktop thread API | Yes | Observed coarse `active`/`idle`; no exposed approval/input flag in the available listing | Near-real-time | Yes | First-party internal tool, no documented third-party interface | Not realistically consumable by a standalone macOS app; responses also contain content metadata that should not be requested |
| `thread_history_1.sqlite` | Yes, confirmed on this thread | `inProgress` versus terminal statuses, start/completion timestamps, duration; completion edge; no needs-user cause | Live row was present during the turn; exact projection latency not yet measured | Yes | Unsupported schema and path, version-fragile | Read-only SQL can select lifecycle columns only. A sandboxed app would need explicit access to `~/.codex`; never select content/error JSON columns |
| `state_5.sqlite` | Yes | Thread inventory but no useful live lifecycle state found | Not applicable | Yes | Unsupported and version-fragile | Contains title, preview and first-message fields; avoid because it adds content risk without solving lifecycle detection |
| `logs_2.sqlite` / rollout files | Yes | Likely detailed events, but lifecycle extraction would require parsing content-bearing internal records | Potentially low | Yes | Unsupported, highly version-fragile | Rejected: logs and rollouts contain prompt/transcript/tool data and violate the minimum-data constraint |
| Desktop `ipc.sock` | Probably | Unknown | Unknown | Probably | Undocumented private IPC; protocol and read-only behavior unknown | Rejected: connecting could mutate state and is not a realistic supported integration |
| Process/CPU/network heuristics | Only the Desktop process, not a reliable task identity | Process existence and resource activity; cannot distinguish idle, waiting, quiet work or completion | Sampling-dependent | Process existence works; CPU/network semantics do not | Standard OS data but semantically weak | Easy to consume, privacy-safe at coarse granularity, and too inaccurate to classify the required states |

## App Server investigation

Desktop owns a child process with the command shape `codex ... app-server`.
Its transport is inherited anonymous standard-input/output pipes to the Desktop
parent. It has no listening Unix socket or local TCP port. The supported daemon
control path, `~/.codex/app-server-control/app-server-control.sock`, did not
exist, and `codex doctor --json` reported the background server as not running
while separately confirming that the Desktop App Server handshake succeeded.

The bundled schema generator confirms that the protocol itself has exactly the
needed model: `thread/status/changed`, `turn/started`, `turn/completed`, active
flags `waitingOnApproval` and `waitingOnUserInput`, plus approval and
`item/tool/requestUserInput` server requests. That protocol is useful when an
integrating application owns or connects to an App Server. It does not provide
a documented way to join the private stdio session already owned by Desktop.
Starting a daemon, proxy target or second server would observe different tasks
and was intentionally not attempted.

Desktop also opens `~/.codex/ipc/ipc.sock`, but no supported lifecycle protocol
for that socket was found. The probe did not connect to it because its semantics
and read-only safety are unknown.

## Read-only prototype

`tools/fallback_lifecycle_probe.py` contains two narrow experiment modes:

- `sqlite` opens the existing thread-history database with SQLite `mode=ro` and
  selects only `turn_id`, `status`, `started_at`, `completed_at`, and
  `duration_ms`. It never selects item JSON, error JSON, prompts, transcripts,
  messages, source code, tool inputs or tool outputs.
- `hook` accepts official hook JSON on standard input and emits only an event
  name, session/turn identifiers, selected Boolean or enum metadata, and its own
  timestamp. All content-bearing fields are discarded. Phase 1 subsequently
  adapted this same recorder to send the sanitized record to Inbetween's local
  Unix datagram socket; the validated privacy filter was not replaced.

The live SQLite check on this Desktop thread returned an existing turn with
`status=inProgress`, its real turn identifier and start time. It was deliberately
reported as `activeUnknown`. Historical rows show terminal completion timestamps,
but this turn's end-to-end projection latency was not measured in this
investigation. This proves observation of the existing Desktop task, not reliable
four-state classification.

The hook recorder was unit/smoke tested with sentinel content fields and emitted
none of them. It was later enabled, trusted, and validated against Desktop as
recorded below.

## Live supported-hook smoke test

All timestamps below are Unix seconds recorded by the passive handler itself.
Every event used the Desktop session ID
`01a0e209-9665-7a00-8ec1-6fa6c812e06a`.

| Test | Event | Timestamp | Turn ID |
|---|---|---:|---|
| Normal 1 | `UserPromptSubmit` | 1790505939.894502 | `01a0e278-71b6-7442-8ab7-3e747a07bdb0` |
| Normal 1 | `PermissionRequest` | 1790505967.354951 | `01a0e278-71b6-7442-8ab7-3e747a07bdb0` |
| Normal 1 | `Stop` | 1790505978.303018 | `01a0e278-71b6-7442-8ab7-3e747a07bdb0` |
| Normal 2 | `UserPromptSubmit` | 1790506049.572349 | `01a0e27a-1fbc-76c1-845d-e15c88d4966f` |
| Normal 2 | `Stop` | 1790506070.803541 | `01a0e27a-1fbc-76c1-845d-e15c88d4966f` |
| Approval | `UserPromptSubmit` | 1790506139.554884 | `01a0e27b-7f50-7631-a21c-41ff966d75d1` |
| Approval | `PermissionRequest` | 1790506150.142343 | `01a0e27b-7f50-7631-a21c-41ff966d75d1` |
| Approval | `Stop` | 1790506183.020968 | `01a0e27b-7f50-7631-a21c-41ff966d75d1` |
| Background | `UserPromptSubmit` | 1790506229.548689 | `01a0e27c-dee2-7562-802a-5ed138b42125` |
| Background | `PermissionRequest` | 1790506245.491558 | `01a0e27c-dee2-7562-802a-5ed138b42125` |
| Background | `Stop` | 1790506270.753306 | `01a0e27c-dee2-7562-802a-5ed138b42125` |
| Post-background continuation | `UserPromptSubmit` | 1790506319.553470 | `01a0e27e-3e7a-7f50-be86-36ceb788fb04` |

Normal 1 included a `PermissionRequest` because that turn installed the staged
heartbeat automation after its read-only workload. It is not a start/stop
failure, but it demonstrates that the hook reports every permission boundary,
including one associated with an already-authorized operation. Phase 1 should
clear attention on subsequent progress or `Stop` and should avoid assuming that
every permission request remains unresolved indefinitely.

For the background check, Finder activation succeeded, a harmless local workload
continued, and the same turn later emitted `Stop`. The next scheduled Desktop
turn also emitted `UserPromptSubmit` while Finder remained the activated app.
This supports runtime-driven behavior independent of Codex window visibility.
Minimized behavior was not separately tested.

The active project hook is `.codex/hooks.json` and was left enabled and trusted.
Its recorder retains only event name, timestamp, session ID, turn ID,
`permission_mode`, and `stop_hook_active`. It discards prompt/transcript/message,
source, tool-input, tool-output, tool-name, and reason fields. `Stop` returns only
the inert JSON object `{}` required by its output contract; other handlers emit
nothing. No handler returns a decision or changes Codex behavior.

## Recommendation for later Phase 0 verification

The requested smoke test is sufficient for the simplified MVP event model.
Before making broader reliability claims, later Phase 0 work can add controlled
coverage without blocking Phase 1 implementation:

1. Exercise `Interrupt` once and confirm its turn ID and timestamp.
2. Repeat a full start/stop pair while Desktop begins minimized.
3. Measure hook-to-notification latency in the Phase 1 implementation.
4. Decide how the product clears an attention state when a permission request is
   automatically resolved or pre-authorized.

Clarification-specific detection remains outside the simplified MVP requirement.
No fallback investigation is needed for this event model.

## Verification

- `swift test`: 12 tests passed, 0 failures.
- `python3 -m unittest discover -s tools -p 'test_*.py' -v`: 8 tests passed,
  0 failures (3 metric tests, 5 fallback-probe tests).
- Live read-only SQLite query: passed and observed this Desktop turn as
  `inProgress`/`activeUnknown`.
- Hook privacy smoke test: passed; sentinel prompt, transcript path, assistant
  message, tool input, tool name, and reason were absent from the JSONL record.
- App Server daemon check: background daemon/control socket absent; Desktop
  handshake present.

No dependency was added or removed. The experiment uses only the Python standard
library. The first sandboxed Swift test attempt could not initialize SwiftPM's
nested compiler sandbox; the existing approved `swift test` execution outside
that restriction passed.
