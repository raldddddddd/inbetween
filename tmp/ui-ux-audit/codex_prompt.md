# Codex task: Inbetween UI/UX redesign pass

Use **computer use** to inspect the actual running macOS app before making broad UI changes. Do not rely only on code or the supplied screenshot. Read `issues.md` and `references.md` first.

## Goal

Make Inbetween feel like a polished native macOS menu-bar app for a hackathon demo while preserving the existing classification, Featherless, Reflection, persistence, and timeline behavior.

This is a UI/UX pass, not a new AI feature pass.

## Required process

1. Build and launch the real app using the repository’s existing scripts/workflow.
2. Use computer use to inspect the current menu-bar popover in multiple states listed in `issues.md`.
3. Compare the interaction and information hierarchy against the Apple HIG references in `references.md`.
4. Identify additional high-impact UI/UX problems not already listed.
5. Implement a coherent redesign, not a collection of isolated patches.
6. Re-run computer-use inspection after implementation and fix obvious regressions.
7. Run the existing verification/test suite.

## Non-negotiable fixes

- Remove/rework the two large redundant status blocks at the top; current state and review state must be compact.
- Introduce intentional visual hierarchy so the app is not an undifferentiated gray stack. Use native system materials/label levels plus restrained accent/semantic colors.
- Shrink or collapse Reflection so it no longer dominates the initial viewport.
- Fix the 7-day chart baseline/plot clipping bug.
- Hide summary categories whose value is zero when the category has no current informational/action value.
- Fix Create Rule so pressing it immediately reveals/focuses the editor/action. Prefer an anchored inline editor, sheet, popover, or explicit programmatic scroll; never render the result invisibly offscreen.

## Structural question to resolve using HIG + computer use

The current popover mixes status, review, Reflection, analytics, recent weeks, and detailed History in one long scroll surface. Apple’s popover guidance recommends a small amount of information/functionality.

Evaluate whether the better architecture is:

- **Menu-bar popover:** compact current status, Needs Review summary/action, today/7-day glance, quick navigation.
- **Dedicated window/panel:** History, detailed analytics, Reflection/evidence, rule management/settings.

You may implement this split if it materially improves usability and fits the existing architecture. Do not keep a huge scrolling popover merely to avoid changing presentation structure.

## Interaction requirements

- Maintain fast access to Needs Review and existing Previous/Next/keyboard workflows.
- Preserve all classification semantics and AI boundaries.
- Preserve timeline/evidence navigation.
- Use familiar macOS controls and system button styles.
- Keep frequent information above optional explanations.
- Secondary/debug information must not compete with normal product UI.
- Support long/truncated titles without breaking alignment.
- Ensure focus/hover/pressed/disabled states are visually clear.
- Check light/dark appearance where supported.

## History cleanup

Expanded history is currently too control-dense. Use computer use to find a cleaner presentation. Preserve the ability to manually classify/reset/create a rule, but avoid repeating five equally prominent controls for every slice if a more native compact interaction works.

## Documentation discipline

This audit packet is temporary and should not become durable repo documentation.

- Do not add a UI redesign diary.
- Do not create new Markdown files unless they contain stable project knowledge.
- Update existing product/architecture docs only if the final UI structure introduces a durable invariant (for example, “popover is quick status/actions; detailed history opens in a window”).
- Compress rather than append.

## Testing and final report

At minimum:

- run the existing fast verification suite;
- test the chart with zero/nonzero categories;
- test Create Rule from different scroll positions;
- test empty/no-review states;
- test long titles;
- test Reflection success/error/unconfigured states;
- visually inspect the final app with computer use.

Report only:

- additional UX issues discovered;
- major design decisions made and the HIG reason for them;
- files changed;
- tests run/results;
- remaining visual/demo risks.
