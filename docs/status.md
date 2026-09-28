# Status

Current release baseline: **0.3.0 (build 3)**.

## Established

- Native macOS menu-bar app with supported, privacy-filtered Codex lifecycle
  hook ingestion.
- Persistent wait sessions, conservative restart recovery, Ready notifications,
  Launch at Login, and sleep/wake handling.
- Foreground application and presence tracking during active waits, with
  optional focused-window and Chrome/Safari tab enrichment.
- Local interval classification, personal context rules, manual corrections,
  history, contributor summaries, and seven-day insights.
- Presence-aware slice review, mixed-wait duration aggregation, and scoped local
  corrected-history exports while retaining pre-slice JSON compatibility.
- Headless scenario fixtures, Swift/Python tests, bundle validation, and an
  isolated clean-install check.

## Current development area

The time-sliced classification upgrade is complete. The model preserves exact
per-interval durations, separates observed activity from gaps, groups equivalent
review contexts without losing presence or source identity, and keeps automatic
results underneath user corrections. Future classifier experiments should use
local hand-authored or explicitly exported scoped evaluation data.

## Important current semantics

- Hook events, not Accessibility UI inference, are lifecycle truth.
- A permission request is an attention boundary, not proof that Codex is blocked.
  After eight seconds it may change the UI; it does not currently send an
  attention notification.
- Only a matching normal `Stop` completes a wait and sends Ready. Interruptions
  are retained separately.
- Idle, away, ambiguous, and unobserved intervals remain Unclassified.
- Personal rules outrank built-in and semantic evidence; manual corrections
  override presentation without erasing automatic results.

## Intentionally not started

Accounts, backend or cloud sync, remote analytics, cloud AI, screen capture,
other agent integrations, mobile/cross-device clients, distraction blocking,
subscriptions, and automated store distribution remain out of scope. Developer
ID distribution and notarization are documented but require the owner's release
credentials and actions.
