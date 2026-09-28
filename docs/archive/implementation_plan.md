# Implementation Plan

## Overview

Development is intentionally split into a feasibility spike followed by product phases.

Phase 0 is a gate. Do not begin the full product until Codex-state detection is shown to be reliable enough.

---

## Phase 0 — Codex State Detection Spike

### Goal

Prove whether ChatGPT Desktop / Codex activity can be detected reliably using macOS Accessibility APIs.

### Scope

- Create a minimal native Swift probe.
- Detect ChatGPT process and windows.
- Request/check Accessibility permission.
- Inspect relevant Accessibility elements.
- Implement:
  - idle
  - working
  - needsUser
  - finished
  - unknown
- Log state transitions and supporting evidence.
- Run the controlled test plan in `technical_spike.md`.
- Calculate detection metrics.
- Produce a go/no-go report.

### Exclusions

- No polished UI.
- No productivity task system.
- No user-activity classification.
- No screenshots.
- No vision model.
- No backend.
- No accounts.
- No analytics.

### Verification

- Swift build succeeds.
- Probe runs without crashing when ChatGPT is closed.
- Permission-denied behavior is safe.
- Controlled scenarios are tested.
- Metrics and limitations are documented.

### Definition of Done

A written `PROCEED`, `PROCEED_WITH_LIMITATIONS`, or `DO_NOT_PROCEED` decision exists with evidence.

---

## Phase 1 — macOS App Foundation

### Goal

Turn the validated Codex lifecycle hooks into a proper native macOS app
foundation. `docs/archive/phase0_fallback_report.md` is the detection source of truth.

### Scope

- SwiftUI macOS app with a minimal developer-facing window and menu-bar view.
- Event-driven local Unix-domain socket ingestion from the metadata-only Codex
  lifecycle hook.
- Typed events for `UserPromptSubmit`, `Stop`, `PermissionRequest`, and
  `Interrupt`, identified by session and turn IDs.
- In-memory `idle`, `active`, `attention`, and `ready` state.
- Conservative handling of malformed, duplicate, stale, out-of-order, and
  unrelated-turn events.
- Unit tests around event parsing and state transitions.

### Exclusions

- No user-activity classification.
- No productivity scoring.
- No backend.
- No AI classifier.
- No Accessibility detector, App Server attachment, SQLite lifecycle polling,
  private IPC, process heuristics, screenshot/OCR, or vision fallback.
- No production onboarding, settings, history, notifications, or launch at login.

### Definition of Done

The native app launches, receives validated metadata-only hook events locally,
and exposes the current Codex turn state in a minimal verification UI.

---

## Phase 2 — Wait Sessions

### Goal

Represent Codex turns as explicit local wait sessions driven by lifecycle hooks.

### Scope

- Start a wait session on `UserPromptSubmit`.
- Record `PermissionRequest` as an attention event without ending the session.
- Complete the session on `Stop`, recording its duration.
- Complete the session as interrupted/cancelled on `Interrupt`.
- Persist completed and active wait sessions locally so history survives app
  restarts.
- Recover unfinished sessions conservatively after restart; never invent an end
  time when no terminal event was observed.
- Show current duration and basic local session history.
- Notify locally when Codex stops or requests permission.

### Data

A wait session should minimally contain:

- id,
- Codex session ID,
- Codex turn ID,
- start time,
- end time,
- final state,
- duration,
- lifecycle hook source/version,
- attention events,
- optional user intention.

### Definition of Done

Normal Codex use generates accurate local wait sessions from lifecycle events,
including conservative restart recovery, without manual timers. Intent selection
remains deferred to Phase 3.

---

## Phase 3 — Intentional Use

### Goal

Let users quickly choose how they intend to use agent wait time.

### Scope

Provide lightweight optional choices such as:

- Focus — coding, writing, planning, project/admin work
- Learn — documentation, articles, tutorials, or studying
- Move — stretching, walking, water, or another physical break
- Other — optionally with a short custom label

The user should be able to dismiss/ignore this entirely.

### UX Principle

Choosing an intention should require at most one short interaction.

### Exclusions

- No complex task manager.
- No project hierarchy.
- No due dates.
- No productivity gamification.

---

## Phase 4 — Local Activity Context

### Goal

Observe enough local context to understand what the user is doing without screen recording.

### Scope

Investigate and implement only the minimum useful metadata:

- foreground app,
- window title,
- duration,
- browser domain/URL where technically appropriate,
- page title where available.

### Privacy

- Local processing by default.
- No screenshots.
- No full-page text capture by default.
- No source-code capture.
- Clearly document permissions.

### Definition of Done

The app can produce a local activity timeline for an active wait session.

---

## Phase 5 — Productive / Distracted / Unclassified Classification

### Goal

Classify wait-session activity conservatively.

### Inputs

Potentially:

- user intention,
- foreground app,
- title/domain metadata,
- user-defined distracting applications/sites,
- explicit user feedback.

### Rules

- Prefer deterministic/user-configured rules first.
- Use `unclassified` when uncertain.
- Do not label an entire application as productive or distracting when context matters.
- Do not add cloud AI classification in this phase.
- Require at least 60 seconds and half of the completed wait in a small,
  inspectable intentional-app set before using that evidence for `productive`.
- With a Move intention, treat one unchanged foreground context covering at
  least 80% of a wait of two minutes or longer as conservative evidence for
  `productive`; this does not claim input-idle detection.
- Ship no default distracting-app judgments. `distracted` requires a local
  user-marked rule and sustained use meeting the same 60-second/half-wait
  threshold.

### Definition of Done

The classification is understandable, inspectable, and correctable by the user.

---

## Phase 6 — History and Insights

### Goal

Show useful summaries without creating a punitive productivity score.

### Possible Metrics

- total agent wait time,
- productive time,
- distracted time,
- unclassified time,
- number of useful activities completed,
- daily/weekly trend.

### UX

Focus on:

> "What did I get done while my agent worked?"

Avoid:

> "You were only 61% productive."

---

## Phase 7 — Reliability and Product Polish

### Goal

Make the utility dependable enough for daily personal use.

### Scope

- launch at login,
- sleep/wake handling,
- ChatGPT restart handling,
- multiple-window behavior,
- notification polish,
- permission recovery,
- menu-bar UX,
- energy/CPU profiling,
- memory profiling,
- accessibility,
- dark/light appearance,
- error states.

### Definition of Done

The app can stay running during a normal workday without excessive CPU, memory, false notifications, or manual intervention.

---

## Phase 8 — Packaging and Personal Release

### Goal

Package the app for reliable personal installation.

### Scope

- release configuration,
- app identity,
- signing strategy,
- notarization plan if distributing outside the development Mac,
- versioning,
- release notes,
- clean-install test.

### Non-Goal

Mac App Store publication is not required for the initial personal product.

---

## Deferred Product Expansion

Only after the local macOS product proves useful should we consider:

- Claude Code support,
- Cursor support,
- browser extension,
- iPhone companion,
- cross-device status,
- cloud sync,
- account system,
- AI classification,
- social-media blocking,
- integrations with task/calendar/email systems.

---

## Phase Workflow

For every implementation phase:

1. Implement only that phase.
2. Do not begin the next phase.
3. Run the documented verification.
4. Report:
   1. significant files changed,
   2. dependencies added or removed,
   3. verification results,
   4. conflicts/deviations from `product_spec.md`,
   5. anything the next phase needs to know.
5. Commit only after the phase is reviewed and accepted.
