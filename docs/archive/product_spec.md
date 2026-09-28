# Product Specification

## Working Title

**Agent Wait Companion**

The name is temporary. Product naming and branding are not part of Phase 0.

## 1. Product Summary

Agent Wait Companion is a native macOS productivity utility for people who use AI coding agents such as Codex.

AI agents create short periods in which the user is waiting for delegated work to finish. During those periods, users may drift into social media or other distractions and remain distracted even after the agent is ready.

The product should detect when Codex is actively working, help the user use that time intentionally, and notify the user when attention is needed again.

The product should succeed by getting the user back to their main work quickly.

## 2. Product Principle

> Stop watching the agent work.

The app should not become another system that requires constant maintenance.

Interactions should be short, optional, and low-friction.

## 3. Initial Target

### Platform

- macOS
- Native Swift / SwiftUI

### Agent

Initial support is limited to:

- ChatGPT Desktop
- Codex sessions running through ChatGPT Desktop

Support for Claude Code, Cursor, or other agents may be evaluated later.

## 4. Core User Problem

A typical workflow is:

1. The user delegates a task to Codex.
2. Codex works for several minutes.
3. The user has too little time or motivation to begin another large task.
4. The user opens social media or entertainment.
5. Codex finishes.
6. The user remains distracted longer than the actual wait.

The product should convert that gap into intentional time without requiring the user to supervise Codex.

## 5. Product Model

The product has two independent responsibilities.

### A. Agent State

Determine whether Codex is:

- `idle`
- `working`
- `needsUser`
- `finished`

`finished` is a transition event: a previously working agent returned to a ready/idle state.

### B. User Activity During Agent Work

Eventually classify the user's time as:

- `productive`
- `distracted`
- `unclassified`

The product must not assume an app is productive or distracting solely from its name.

Examples:

- A YouTube programming tutorial may be productive time.
- YouTube Shorts may be distracting.
- Safari may contain documentation, entertainment, or something unrelated.
- Unknown activity should remain unclassified.

## 6. V1 Product Experience

The intended long-term flow is:

1. Codex begins working.
2. Agent Wait Companion detects the transition automatically.
3. The app enters an active wait session.
4. The user may choose an intention such as:
   - Learn
   - Read
   - Admin
   - Move
   - Plan
   - Custom
5. The app observes lightweight local activity context.
6. Codex finishes or needs attention.
7. The app notifies the user.
8. The session ends.
9. The app records a small summary.

The user must be able to ignore the productivity prompt entirely.

## 7. Time Classification

### Agent Wait Time

Total duration from a confirmed `working` transition until `finished`, `needsUser`, cancellation, or another terminal state.

### Productive Time

Time during the agent wait period for which there is sufficient evidence that the user intentionally performed a useful activity.

Evidence may eventually include:

- user-selected intention,
- foreground application,
- window title,
- browser domain or URL,
- page title,
- explicit completion,
- local classification.

### Distracted Time

Time during the agent wait period for which there is strong evidence of activity the user has configured or clearly identified as distracting.

The app should favor user-defined preferences over universal judgments.

### Unclassified Time

Any agent wait time that cannot be confidently categorized.

The system must prefer `unclassified` over making an unsupported judgment.

## 8. Product Metrics

The app should emphasize completed or intentionally used time rather than a generic productivity score.

Potential summaries:

- total agent wait time,
- productive time,
- distracted time,
- unclassified time,
- useful activities completed while agents worked.

Avoid shame-based or punitive scoring.

## 9. Privacy

Privacy is a core product requirement.

Default behavior should:

- process monitoring locally,
- avoid screenshots,
- avoid recording source code or prompts,
- avoid storing full page contents,
- collect only the minimum metadata needed,
- explain macOS permissions clearly.

If browser context is later needed, prefer:

- active domain,
- URL when necessary,
- page title,
- user-selected intent.

Screen capture or cloud AI classification must be opt-in and separately specified if ever introduced.

## 10. Permissions

The product may require macOS Accessibility permission to inspect supported application UI state.

Future features may require additional permissions, but Phase 0 must not request more permissions than necessary.

Failure to grant Accessibility permission should result in a clear explanation, not a crash.

## 11. Local-First Requirement

The initial product does not require:

- user accounts,
- backend services,
- Supabase,
- Firebase,
- cloud synchronization,
- subscription infrastructure,
- remote analytics,
- AI API usage.

Persistent local data may later use SwiftData if needed.

## 12. Non-Goals

The initial product is not:

- a replacement for Codex,
- a remote-control client for Codex,
- a general project-management app,
- a to-do list,
- a Pomodoro timer,
- a social-media blocker,
- a screen recorder,
- an employee-monitoring product,
- a surveillance tool,
- a universal productivity score,
- an AI assistant that reads the user's entire screen.

## 13. Design Direction

The final app should feel native to macOS.

Likely surfaces:

- menu bar status,
- compact popover,
- notifications,
- lightweight history/settings window.

The app should not require a permanently open main window.

## 14. Reliability Requirement

The product depends on trustworthy agent-state detection.

Before building the full experience, the project must complete the Phase 0 technical spike defined in `technical_spike.md`.

If Codex state cannot be detected reliably enough, the product architecture must be reconsidered before substantial UI work begins.

## 15. Future Possibilities

These are explicitly deferred until after the core product works:

- Claude Code support,
- Cursor support,
- browser extension integration,
- automatic user-activity classification,
- optional local language model classification,
- iPhone companion,
- cloud sync,
- cross-device notifications,
- distraction-blocking integrations,
- calendar/task integrations,
- subscription features.
