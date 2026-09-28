# AGENTS.md

Inbetween is a lightweight, native macOS utility that helps people use Codex
wait time intentionally. It is built with Swift and SwiftUI and is local-first.

## Working rules

- Inspect the relevant implementation and tests before changing behavior.
- Consult current documentation only when the task needs product, architecture,
  status, or release context. `docs/archive/` is historical evidence, not normal
  required reading.
- If current docs, code, and tests disagree, report the conflict instead of
  silently redefining behavior.
- Make the smallest change that satisfies the request; avoid unrelated refactors
  and speculative future work.
- Prefer native macOS frameworks and deterministic, inspectable behavior.
- Preserve privacy and local-first operation. Collect the minimum metadata
  needed; do not add screen capture, prompt/source/page-body storage, remote
  analytics, cloud services, accounts, or AI API calls without an explicit
  requirement.
- Fail safely when permissions or monitoring are unavailable. Keep ambiguous
  activity unclassified rather than guessing.
- Do not change application behavior while doing documentation-only work unless
  a trivial reference fix is required.

## Verification

- Run focused tests while iterating when useful.
- Run `./scripts/verify-fast.sh` for ordinary code changes. It is the canonical
  headless check and must not touch real user data.
- Run `./scripts/verify-full.sh` for release-complete builds and changes to
  packaging, signing, entitlements, or release scripts.

## Completion report

Report only the files changed, tests and results, and unresolved issues.
