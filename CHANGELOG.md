# Release Notes

## 0.3.0 (build 3)

- Adds local browser URL/domain/title enrichment for Chrome and Safari, plus
  inexpensive project, document, folder, terminal, and presence context.
- Adds personal context rules with specific-site/project precedence and richer
  conservative whole-wait classification, including away-aware Move evidence.
- Groups repeated-looking history rows for display while preserving raw observed
  intervals and unobserved gaps.
- Delays uncertain permission attention for eight seconds and emits at most one
  notification per persistent permission boundary.
- Keeps the window-style menu-bar interface reusable after dismissing it.

## 0.2.0 (build 2)

Personal-release baseline.

- Adds reliable Launch at Login, sleep/wake recovery, and graceful handling of
  missing or revoked optional Accessibility permission.
- Presents the active wait, intention choices, History & Insights, privacy and
  status information in a compact accessible menu-bar experience.
- Records only supported, privacy-filtered Codex lifecycle events locally.
- Adds release-bundle verification and a clean-install bundle check.

## Release-note practice

Add a dated entry for every release. Describe user-visible changes, known
limitations, and any manual installation or permission action. Do not include
private prompts, source code, or activity metadata.
