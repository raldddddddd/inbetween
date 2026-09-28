# Phase 1 macOS app foundation — 2026-09-27

## Result

Phase 1 is complete. Inbetween is a native SwiftUI macOS executable with a
menu-bar item and a small developer status window. It receives supported Codex
lifecycle-hook metadata through a local Unix-domain datagram socket and keeps
the current turn state in memory. Phase 2 has not begun.

## Architecture

The trusted project hook invokes the existing
`tools/fallback_lifecycle_probe.py` recorder. The recorder immediately discards
all fields except:

- hook event name;
- session ID;
- turn ID;
- local observation timestamp;
- `permission_mode`;
- `stop_hook_active`.

It serializes that record as one JSON datagram to
`/tmp/inbetween-lifecycle.sock`. The Swift app owns an `AF_UNIX` datagram socket
with mode `0600` and a `DispatchSourceRead`, so delivery is event-driven and has
no polling loop. If the app is absent, delivery errors are ignored and the hook
still returns passive success to Codex. `Stop` returns only the inert `{}` JSON
required by its hook contract.

The app parses the datagram into a typed `LifecycleEvent`, then applies it to an
in-memory `LifecycleStateMachine`. No lifecycle metadata is persisted by the
app. The Unix socket contains no retained event history.

## State transitions

| Event | Accepted condition | Result |
|---|---|---|
| `UserPromptSubmit` | valid, current event | `active`; creates or refreshes the matching active turn |
| `PermissionRequest` | matches active session and turn | `attention`; retains the attention event |
| later same-turn `UserPromptSubmit` | matches active turn | `active`; preserves original start time and clears current attention state |
| `Stop` | matches active session and turn | `ready`; removes the active turn |
| `Interrupt` | matches active session and turn | `ready`; removes the cancelled active turn |

The most recent attention event remains available as metadata after the visual
state changes. A permission event therefore does not create a permanent blocked
classification. Events are ignored conservatively when they are malformed,
duplicates, older than the last accepted event, over five minutes old, more than
30 seconds in the future, or refer to a different active turn.

The initial state is `idle`. Because Phase 1 keeps state only in memory, the app
cannot reconstruct a turn that started while it was not running.

## Developer UI

The window and menu-bar popover show only:

- `idle`, `active`, `attention`, or `ready`;
- whether a turn is active;
- shortened turn ID;
- turn start time and elapsed duration;
- last lifecycle event;
- timestamp of the most recent attention event;
- receiver health and count of conservatively ignored events.

This is an integration surface, not the final product UI.

## Privacy

The app and hook remain local. They do not ingest or persist prompts, messages,
transcripts, source code, tool names, tool inputs, or tool outputs. There is no
backend, network service, account, analytics, AI API, screenshot, OCR, vision,
Accessibility detector, App Server attachment, lifecycle database polling,
private IPC integration, or process heuristic.

## Verification

- `swift build --product Inbetween`: passed.
- `swift test`: passed — 7 Swift Testing state/parser tests, 1 XCTest Unix
  datagram integration test, and 12 existing Phase 0 tests; 0 failures.
- `python3 -m unittest discover -s tools -p 'test_*.py' -v`: passed — 9 tests,
  0 failures.
- Native launch smoke test: the built SwiftUI executable stayed running and
  created `/tmp/inbetween-lifecycle.sock` with mode `0600`.
- Hook-path integration smoke test: synthetic sanitized `UserPromptSubmit`,
  `PermissionRequest`, and `Stop` records were delivered through the production
  Python hook command to the running app without errors.
- Shutdown cleanup was performed after the command-line launch was interrupted;
  a normal application quit uses the receiver cancellation handler.

No external dependency was added or removed.

## Manual Desktop verification

The `.codex/hooks.json` command changed during Phase 1, so Codex will mark its
new hash for review. From the repository root:

1. Build the app:

   ```sh
   swift build --product Inbetween
   ```

2. In a separate Terminal, review and trust the exact current project hook:

   ```sh
   codex --no-daemon -C /Users/gerald/Developer/inbetween --no-alt-screen
   ```

   Enter `/hooks`, review the four definitions, trust them, then enter `/exit`.
   Do not submit a CLI task.

3. Restart ChatGPT Desktop so its existing Codex session loads the newly trusted
   hook hash, then reopen this repository chat.
4. Launch Inbetween in another Terminal:

   ```sh
   cd /Users/gerald/Developer/inbetween
   .build/debug/Inbetween
   ```

   Confirm the window says it is listening at
   `/tmp/inbetween-lifecycle.sock` and begins in `Idle`.
5. Submit a normal Codex Desktop task in this repository. Inbetween should show
   `Active`, the shortened real turn ID, start time, elapsed time, and
   `UserPromptSubmit`.
6. Let the turn stop. Inbetween should show `Ready`, no active turn, and `Stop`.
7. For attention verification, submit a task that requires a shell approval.
   When Codex asks, Inbetween should show `Attention` and
   `PermissionRequest`. Approve it and let the turn stop; Inbetween should end
   at `Ready`.

The app must already be running when `UserPromptSubmit` occurs. If it is not,
the hook safely drops the datagram and Codex continues normally.

## Deferred

Phase 2 may create explicit wait sessions, persistence/history, end/pause rules,
duration records, and notifications. Productivity/activity tracking,
classification, task suggestions, onboarding polish, settings, launch at login,
packaging, cloud services, and final product UI remain deferred to their later
documented phases.
