# Inbetween

Inbetween is a native macOS menu-bar utility for people who delegate work to
Codex. It detects supported Codex lifecycle events, records local wait sessions,
observes limited foreground activity while a wait is active, and helps the user
return when the turn is ready.

The app is local-first. It does not use accounts, a backend, remote analytics,
screenshots, page bodies, prompts, source contents, or cloud AI.

## Requirements

- macOS 13 or newer
- Swift 6 toolchain
- A trusted project hook in [`.codex/hooks.json`](.codex/hooks.json) for lifecycle
  monitoring

The checked-in hook uses this checkout's absolute path. If the repository moves,
update that command and review the new hook definition in Codex.

## Build and run

Build the development app bundle from the repository root:

```sh
./scripts/build-app.sh
open .build/apps/debug/Inbetween.app
```

Start Inbetween before submitting a Codex turn. The hook sends a small,
privacy-filtered lifecycle event to `/tmp/inbetween-lifecycle.sock`; if the app
is not running, Codex continues normally.

Optional Accessibility permission adds focused-window metadata. Optional macOS
Automation permission lets Inbetween read the front tab URL and title from
Chrome or Safari. Without either permission, monitoring degrades to the metadata
that remains available.

## Test

For ordinary changes:

```sh
./scripts/verify-fast.sh
```

For a release-complete build or packaging/signing changes:

```sh
./scripts/verify-full.sh
```

Useful focused commands include `swift test` and:

```sh
swift run inbetween-scenario-runner --all --summary
```

Scenario fixtures live in `tools/scenarios/inbetween_scenarios.json`. Current
sessions assert Productive, Distracted, and Unclassified durations plus pending
review units; fixtures whose `classificationMode` starts with `legacy` exercise
the pre-slice compatibility path. Slice corrections use `sliceReviewActions`
with exact activity indexes and an action such as `productive`, `distracted`,
`leaveUnclassified`, or `clear`.

Local manual corrections can be exported for semantic evaluation without
changing app data:

```sh
swift run inbetween-corrected-history-export --summary
swift run inbetween-corrected-history-export \
  --output semantic-evaluation-exports/corrected-contexts.json
swift run inbetween-semantic-eval \
  --json semantic-evaluation-exports/corrected-contexts.json
```

New records export only corrected slices. Pre-slice corrections are marked
`legacyWholeWait` and must not be interpreted as labels for every context in
the wait. The ignored export directory keeps this personal data local.

## Documentation

- [Product](docs/product.md) — current behavior, terminology, invariants, and
  non-goals
- [Architecture](docs/architecture.md) — current implementation structure and
  data flow
- [Status](docs/status.md) — established capabilities and the active development
  area
- [Personal release](docs/personal_release.md) — signing, notarization, and
  release-only procedures
- [Changelog](CHANGELOG.md) — release history
- [Archive](docs/archive/README.md) — obsolete plans, feasibility work, and phase
  reports retained for reference
