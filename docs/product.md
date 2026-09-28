# Product

## Purpose

Inbetween helps a person use the short gaps created while Codex works, then
return promptly when the turn is ready. It should reduce attention overhead and
must not become a task-management system that requires regular maintenance.

The guiding principle is: **stop watching the agent work**.

## Current product behavior

Inbetween is a macOS menu-bar app that:

- detects supported Codex turn lifecycle events;
- creates a local wait session while a turn is active;
- shows Listening, Working, May Need Attention, or Ready;
- records limited foreground activity only during an active wait;
- classifies observed intervals as Productive, Distracted, or Unclassified;
- lets the user correct classifications and create personal context rules;
- keeps local history and recent time summaries;
- sends a local notification when a normal Codex turn completes; and
- can launch at login.

The app remains usable when optional monitoring permissions are unavailable.

## Terminology

- **Lifecycle event:** a supported Codex hook event carrying an event name,
  session ID, turn ID, timestamp, and limited event metadata.
- **Wait session:** the interval beginning with `UserPromptSubmit` and ending
  with a matching `Stop` or `Interrupt`.
- **Attention boundary:** a matching `PermissionRequest`. It is recorded without
  ending the wait and does not by itself prove that Codex is blocked.
- **Activity segment:** a locally observed foreground context and presence state
  during part of a wait.
- **Unobserved gap:** time within a wait for which Inbetween has no activity
  observation.
- **Automatic classification:** Inbetween's inspectable local result for an
  observed interval.
- **Classification slice:** one exact interval of a completed wait, linked to
  its source activity segment by UUID or marked as an unobserved gap.
- **Manual correction:** a user choice layered over the automatic result; the
  original result remains retained.
- **Personal context rule:** a local rule that marks matching application,
  window, site, document, project, or path metadata as Productive, Distracted,
  or Context-dependent.

## Product invariants

- `UserPromptSubmit` starts or resumes the matching wait.
- `Stop` completes the matching wait and may produce a Ready notification.
- `Interrupt` ends the matching wait as interrupted and does not count it as a
  completed wait.
- `PermissionRequest` records attention metadata. The UI may show May Need
  Attention only after the boundary persists briefly without a supported
  continuation event; attention notifications are currently disabled.
- Malformed, duplicate, stale, out-of-order, and unrelated-turn events are
  rejected conservatively.
- A wait that was active when the app stopped is recovered as unfinished. No end
  time or duration is invented.
- Activity is collected only during active waits. Sleep, termination, and other
  observation gaps remain explicit rather than being filled with assumed data.
- Idle, away, ambiguous, and unobserved time is Unclassified. Foreground app
  identity alone must not overrule evidence that the user was inactive.
- Active contexts may use explicit obvious-app evidence (including Steam,
  Discord, iPhone Mirroring, and the native Games category), structural work
  metadata, or confidence-gated semantics. Personal rules remain stronger.
- Personal rules take precedence over built-in and local semantic evidence.
- Insights use effective per-interval classifications while preserving automatic
  results and user corrections.
- A mixed wait contributes its exact slice durations to multiple categories.
  Review units combine only equivalent context and presence, and corrections
  affect only the represented slices.
- Pre-slice history retains its stored whole-wait classification or correction;
  it is never silently reclassified under current rules.
- The product emphasizes time and understandable evidence, not a punitive score.

## Privacy and data handling

Processing and persistence are local. Inbetween may retain application identity,
window title, browser URL/domain/title, project/document/path metadata, presence
state, lifecycle identifiers, timestamps, classifications, and personal rules.

Inbetween must not collect or persist prompts, transcripts, source contents,
page bodies, keystrokes, screenshots, or input contents. It does not inspect
browser DOM or network traffic. Local semantic classification uses metadata the
app already holds; embedding vectors are not persisted.

Permissions must be explained clearly and degrade safely:

- Accessibility adds focused-window and document metadata where available.
- Automation can add the active Chrome or Safari tab URL and title.
- Notification and Launch at Login features use their native macOS facilities.

## Durable requirements

- macOS only; Swift and SwiftUI; prefer native frameworks.
- Keep the app lightweight, inspectable, and low-friction.
- Prefer supported lifecycle events and deterministic/user-configured evidence.
- Prefer Unclassified when evidence is insufficient.
- Preserve local history compatibility across schema evolution where practical.
- Monitoring failures must not interfere with Codex or prevent use of the app.

## Non-goals

Inbetween is not a Codex replacement or remote-control client, a project manager,
to-do list, Pomodoro timer, blocker, screen recorder, employee-monitoring tool,
surveillance product, or universal productivity score.

Accounts, backend services, cloud sync, remote analytics, AI API calls, mobile or
cross-device clients, other coding-agent integrations, browser extensions,
subscriptions, and store distribution are outside the current product.
