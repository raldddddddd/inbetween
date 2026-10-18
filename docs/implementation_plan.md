# Inbetween Repair Implementation Plan

**Status:** Phases 1–7 complete; Phase 8 headless and release checks pass.
On 2026-10-17, an isolated release copy exposed the Dashboard, History, and
Reflection windows at runtime. The menu-bar popover and provider-dependent
Reflection behavior remain unverified; Launch Services `-10827` is
intermittent and its cause is undetermined. Earlier runtime checks and the
real-store integrity discrepancy are documented below.\
**Scope:** Repair the existing Inbetween macOS menu-bar app without
rewriting its architecture or implementing unrelated features.\
**Primary objective:** Make activity classification reviewable and
trustworthy, ensure History and Reflection agree, and keep Reflection
answers readable and grounded in local evidence.

## Working Rules

1.  Read `AGENTS.md` before making changes. Follow the repository's
    current guidance.
2.  Treat this file as the active implementation plan.
    `docs/archive/implementation_plan.md`, if present, is historical
    reference only.
3.  Inspect existing code and tests before editing. Confirm each root
    cause rather than guessing.
4.  Make changes in small, reviewable phases. Do not start a later phase
    until the current phase's tests pass or its blockers are documented.
5.  Preserve the existing local-first architecture and current product
    decisions.
6.  Preserve persisted manual overrides. Do not silently reclassify
    historical records using the current automatic classifier.
7.  Do not weaken evidence validation merely to hide an error.
8.  Do not introduce cloud classification. Featherless remains limited
    to the existing Reflection functionality that uses it.
9.  The obsolete Needs Review screen and navigation are removed. Keep
    manual Productive/Distracted correction in History. Preserve legacy
    Unclassified values, `reviewSuggested`, and handled-review fields when
    decoding and saving historical records.
10. Report the exact tests and build commands run. Never claim
    verification that was not performed.
11. Avoid unrelated refactors, framework changes, or broad rewrites.

## Phase 1 --- Historical Review Eligibility and Aggregate Consistency

**Status:** Complete (2026-10-16)

**Goal:** Make eligible historical Unclassified activity reviewable and
ensure History and Reflection calculate classification durations
consistently.

### Investigate

-   `WaitSession.shouldRequestClassificationReview` in
    `WaitSession.swift`.
-   `pendingReviewItems` and `classificationUnits` in
    `WaitPresentationSupport.swift`.
-   `WaitHistoryInsights.swift` classification duration aggregation.
-   `AIInsights.swift` interval construction and classification
    aggregation.
-   Persistence decoding and defaults for legacy records, especially
    missing `reviewSuggested` fields.
-   How observed slices, uncovered intervals, unobserved gaps, handled
    review items, and manual overrides are represented.

### Implement

-   Define explicit review eligibility for observed activity that is
    Unclassified and not already resolved.
-   Make eligible historical records reviewable even when legacy records
    lack newer review metadata, where this can be done safely.
-   Do not treat unobserved gaps as observed activity. They have no
    captured activity context and should remain clearly distinguished
    from reviewable activity.
-   Preserve handled review decisions and existing manual overrides.
-   Keep Needs Review manual-only: offer Productive and Distracted, not
    Unclassified and not AI suggestions.
-   Establish one consistent rule for classification-duration accounting
    across History and Reflection.
-   For legacy sessions with partial segment coverage, explicitly define
    how covered intervals and uncovered duration are represented; do not
    silently assign the same interval to conflicting categories.
-   Avoid double-counting when a slice is manually reclassified.
-   If persistence schema changes are necessary, implement a safe
    migration and retain backward compatibility.

### Tests

-   Legacy records missing `reviewSuggested`.
-   Unresolved observed Unclassified slices appear in review.
-   Already-handled items do not reappear incorrectly.
-   Unobserved gaps are not presented as captured activity.
-   Manual overrides survive classification refreshes and app restarts.
-   History and Reflection aggregate parity for legacy partial-coverage
    sessions.
-   Aggregate parity after a slice is manually corrected.
-   No double-counting when review state changes.

### Completion criteria

-   [x] Eligible historical Unclassified activity can be reviewed.
-   [x] The UI clearly distinguishes reviewable activity from unobserved
    gaps.
-   [x] Manual decisions persist.
-   [x] History and Reflection follow the same documented
    classification-duration rules.
-   [x] Relevant tests pass.

### Actual results

-   Review eligibility no longer depends on `reviewSuggested`, whose legacy
    decoding default is `false`. Whole-wait legacy Unclassified records are
    reviewable unless a manual override or handled state already resolves them.
-   Sliced review requires an Unclassified, unresolved slice with no manual
    override and a valid observed-segment reference. Missing presence metadata
    remains reviewable and is displayed as “Presence unknown”; unobserved gaps
    and dangling segment references remain out of review.
-   Existing manual override and handled-state persistence is retained; no
    persistence schema migration was needed. Needs Review continues to offer
    only Productive and Distracted decisions.
-   History day/week totals now attribute duration by occurrence-time overlap,
    while session counts remain completion-date based. Lifetime totals remain
    whole-wait totals. Legacy whole-wait classifications apply to the full wait
    interval, including uncovered activity context; explicit unobserved gap
    slices retain their gap provenance. Legacy sliced records with missing
    interval coverage report that time as Not recorded. Reflection uses the
    same rules, and Last 7 Days contributor totals clip to the same period.
-   `swift test --filter 'TimeSlicedPresentationTests|WaitPresentationSupportTests|WaitSessionStoreTests|AutomaticProductivityTests|AIInsightsTests'`:
    passed (71 tests).
-   `./scripts/verify-fast.sh`: passed (20 scenarios, 156 Swift tests in 19
    suites, and 13 Python tests).

### Risks

Broadening eligibility may expose legacy records previously hidden by
missing review flags. Preserve handled decisions and do not manufacture
activity context for unobserved gaps.

------------------------------------------------------------------------

## Phase 2 --- Reflection Interval Clipping and Date Attribution

**Status:** Complete (2026-10-16)

**Goal:** Ensure daily and selected-period metrics assign elapsed time
to the dates and periods in which it actually occurred.

### Investigate

-   `AIInsights.swift`, especially snapshot interval creation and daily
    aggregation.
-   Current Today and Last 7 Days range boundaries.
-   Time-zone and local-calendar handling.
-   Session counts versus interval duration attribution.
-   Evidence IDs and navigation links derived from daily summaries.

### Implement

-   Define consistent local-calendar boundaries for Today and Last 7
    Days.
-   Clip intervals to the selected analysis window before aggregating
    durations.
-   Attribute cross-midnight duration to the correct local-calendar day
    rather than assigning an entire interval to its start day.
-   Make the definition of a session count explicit. Do not assume that
    duration buckets and session counts must use identical attribution
    when their meanings differ; document and test the intended behavior.
-   Ensure period comparisons use correctly clipped inputs.
-   Handle daylight-saving/time-zone boundaries where relevant to the
    app's supported environment.
-   Keep metric calculations local and authoritative.
-   Ensure daily evidence represents all contributing intervals. If an
    evidence item aggregates multiple sessions, either link to all
    contributing sessions/slices or explicitly define and test a
    different navigation behavior.

### Tests

-   A wait crossing midnight.
-   A wait crossing the start or end of the selected seven-day period.
-   Local-calendar day attribution.
-   Empty days and partial coverage.
-   Consistent daily and weekly totals.
-   Session-count semantics.
-   Evidence links for a daily summary containing multiple waits.

### Completion criteria

-   [x] Duration is counted only within the selected period.
-   [x] Cross-midnight waits are attributed according to the documented
    local-calendar rule.
-   [x] Comparisons use the correct dates and ranges.
-   [x] Daily and period totals reconcile with the underlying intervals.

### Actual results

-   Reflection now clips completed activity intervals to the selected
    local-calendar period before calculating durations, blocks, switches,
    context totals, and evidence.
-   Daily summaries split those clipped intervals at local day boundaries,
    including daylight-saving transitions. Completed-session counts remain
    attributed by completion date; duration is attributed by occurrence time.
-   Aggregated day evidence navigates to the earliest contributing wait and
    highlights only slices from that wait. Its summary duration still includes
    every contributing wait.
-   `swift test --filter AIInsightsTests`: passed (11 tests).
-   `./scripts/verify-fast.sh`: passed (20 scenarios, 150 Swift tests in 19
    suites, and 13 Python tests).

### Risks

Correcting interval attribution may change historical Reflection
comparisons. Treat this as a correction to aggregation semantics, not a
reason to rewrite stored activity or manual decisions.

------------------------------------------------------------------------

## Phase 3 --- Improve Local NLP Classification

**Status:** Complete (2026-10-17; binary fallback and historical reclassification)

**Goal:** Classify all newly classified activity as Productive or
Distracted, identify coding when local evidence supports it, and keep
unobserved time distinct from observed activity.

### Investigate

-   `SemanticActivityUnderstanding.swift`.
-   `WaitSessionClassification.swift`.
-   Existing automatic productivity classification tests.
-   The actual metadata captured for browser, LeetCode, editor, project,
    workspace, and terminal activities.
-   Semantic similarity thresholds, runner-up margins, candidate
    prototypes, and embedding-unavailable behavior.
-   Rule precedence and any path that can overwrite a manual override.

### Implement

-   Use real metadata shapes already collected by the app to design
    representative classification tests.
-   Improve normalization and semantic candidate descriptions only where
    the evidence shows a weakness.
-   Add or improve coding-practice context recognition when the captured
    title/domain/path or other available context supports it.
-   Do not assume every browser activity or every LeetCode page is
    Productive. Coding-task evidence must support that decision; explicit
    entertainment context can still take precedence.
-   Use a deterministic Distracted fallback when local evidence is sparse,
    embeddings are unavailable, or confidence is insufficient. Preserve
    an `Unclassified` decoding path for historical compatibility only.
-   Keep nil-source gap slices visibly unobserved even when assigning their
    deterministic fallback classification. Report time absent from stored
    slices as Not recorded rather than inventing an activity slice.
-   Keep results deterministic for identical inputs and configuration.
-   Preserve manual Productive and Distracted overrides. On the explicitly
    authorized historical pass, replace manual Unclassified decisions with
    the deterministic automatic result.
-   Add diagnostics sufficient to explain deterministic fallback results,
    while avoiding unnecessary sensitive-content logging.
-   Do not replace Apple's NaturalLanguage baseline or introduce another
    model solely on speculation. Any model change must be supported by
    comparative tests and an explicit cost/benefit justification.

### Tests

-   Representative LeetCode domain/title/path inputs actually supported
    by the collector.
-   Programming activity with strong context.
-   Learning activity with sufficient context.
-   Ambiguous browser activity and missing metadata use the same
    deterministic fallback for identical inputs.
-   Similarity threshold and runner-up-margin boundaries.
-   Embedding unavailable or invalid input.
-   Rule precedence.
-   Manual-override preservation.

### Completion criteria

-   Classification behavior is covered by tests and can be diagnosed.
-   Clearly contextualized programming-practice activity is classified
    as intended when supported by evidence.
-   New classification results are Productive or Distracted; legacy
    Unclassified values remain decodable.
-   Explicit coding evidence takes priority over generic personal/app rules
    and semantic similarity; clear entertainment still takes priority.
-   Manual Productive/Distracted decisions remain intact.
-   Relevant tests pass.

### Risks

The deterministic fallback necessarily makes a category decision when
evidence is weak. Its reason code and explanation identify fallback cases;
unobserved gap provenance remains explicit so the category is not mistaken
for direct observation.

### Phase 3 implementation and verification results (2026-10-17)

-   An explicit personal Productive decision remains authoritative; clear
    entertainment context then takes precedence over coding evidence, which
    overrides other personal rules, generic app rules, and semantic
    predictions. Thus coding is Productive across apps, while an unrelated
    gameplay title in a development tool remains Distracted.
-   Ambiguous, inactive, context-dependent, and weak/unavailable semantic
    cases use deterministic Distracted fallback with local reason codes.
    New classifier output no longer emits Unclassified. Explicit generated
    gaps receive the same fallback while retaining a nil source segment and
    `.unobservedGap`; missing slice coverage is counted as Not recorded.
-   Needs Review and History correction controls offer Productive and
    Distracted. Legacy Unclassified values still decode. Existing manual
    Productive/Distracted overrides and handled-review flags are preserved.
-   Added/updated regression tests for coding across applications,
    LeetCode/programming context, entertainment in development tools,
    personal-rule precedence, weak/absent semantic evidence, deterministic
    fallback, explicit gap provenance, manual override preservation, and
    persistence/reload of historical changes.
-   A read-only preview found 47 sessions (42 completed), 34 Unclassified
    summaries, 345 Unclassified slices including 34 gap slices, and one
    manual Unclassified override. The confirmed pass changed 34 summaries,
    345 automatic slice results, and that one manual Unclassified override.
    It preserved all 47 identities, all timestamps, durations, session
    states, activity segments, slice identities/intervals/source references,
    review flags, and the 155 Productive/Distracted manual overrides. The
    34 gap records remain explicitly unobserved. Reloaded result: 11
    Productive and 31 Distracted completed-session summaries; 224 Productive
    slices (9,987.47 seconds) and 267 Distracted slices (7,670.61 seconds); zero
    Unclassified summaries or slices. Five noncompleted sessions (one
    active, two unfinished, two interrupted) were left unchanged.
-   Fresh verified pre-write backup:
    `/Users/gerald/Library/Application Support/Inbetween/wait-sessions.backup-20261016-163218-522.json`.
    The reclassifier reloaded and compared the persisted store after saving.
    An independent read-only comparison against the backup confirmed the
    47 identities and every non-classification field remained unchanged.
-   `./scripts/verify-fast.sh`: passed (20 scenarios, 174 Swift tests in 20
    suites, and 13 Python tests). `git diff --check`: passed.

------------------------------------------------------------------------

## Phase 4 --- Reflection Answer Validation and Duration Formatting

**Goal:** Make Reflection answers numerically trustworthy and readable.

### Investigate

-   `ReflectionChat.swift`, especially
    `FeatherlessReflectionChatProvider.validate`.
-   Reflection prompt construction and response schema.
-   Answer rendering in `InbetweenApp.swift`.
-   Existing duration formatting utilities such as
    `DisplayFormat.duration`.
-   How claims, numerical values, and evidence IDs are represented.

### Implement

-   Keep all authoritative metrics calculated locally.
-   Do not rely on prompt instructions alone to prevent invented
    numerical claims.
-   Define an enforceable response contract for numeric statements.
    Prefer structured references to supplied metrics where feasible, and
    reject or safely handle unsupported numerical claims.
-   Do not pretend that a simple text scan can reliably validate every
    natural-language numeric claim. If complete validation cannot be
    guaranteed with the current response shape, use a safer constrained
    response format or explain the limitation.
-   Format durations consistently with the app's shared formatter. For
    example, 354 seconds should display as `5m 54s`, not `354 seconds`,
    when the value represents a duration.
-   Keep evidence IDs constrained to the current snapshot.
-   Handle malformed responses, missing evidence, invalid IDs, API
    failures, and timeouts without crashing or corrupting chat state.
-   Do not weaken evidence validation to suppress the existing warning.
-   Keep API keys and sensitive activity details out of logs.

### Tests

-   Valid response with valid evidence IDs.
-   Unknown or missing evidence ID.
-   Malformed response.
-   Unsupported numeric claim.
-   Locally supplied metrics represented in a response.
-   Duration formatting for seconds, minutes, and hours.
-   Multiple evidence references.
-   API failure and timeout behavior.
-   Sanitization and privacy regressions.

### Completion criteria

-   Reflection cannot silently present unsupported numeric claims as
    established local facts.
-   Duration wording is readable and consistent.
-   Invalid evidence references are rejected safely.
-   Error messages are understandable and do not expose implementation
    internals.

### Risks

Free-form language makes perfect claim verification difficult. Prefer
structured metrics and clear limitations over a brittle validator that
gives false confidence.

### Phase 4 result (2026-10-16)

-   Completed. Reflection now requires a structured response containing
    qualitative answer text, current-snapshot evidence IDs, and metric IDs.
    The request includes a deterministic catalog of available metric IDs
    and labels. Metric IDs are resolved to values from the local snapshot
    and rendered with the shared duration formatter; unknown metrics and
    evidence are rejected. Numeric-looking prose is rejected as a
    defense-in-depth guard, while numeric values are presented through
    local metric references rather than model-authored values.
-   Added regression coverage for valid and multiple evidence/metric
    references, unknown and missing evidence, unknown metrics, malformed
    responses, numeric claims, sanitization, timeout, and HTTP failure.
    Shared duration formatting covers seconds, minutes, and hours,
    including 354 seconds as `5m 54s`.
-   Verification: `swift test --filter 'ReflectionChatTests|WaitPresentationSupportTests'`
    passed (26 tests); `./scripts/verify-fast.sh` passed (20 scenarios,
    159 Swift tests in 19 suites, and 13 Python tests).
-   Limitation: the lexical prose guard is not a general natural-language
    truth validator. The response contract instead reserves numeric facts
    for snapshot-backed metric IDs whose displayed values are produced
    locally.

------------------------------------------------------------------------

## Phase 5 --- Clarify Reflection Evidence Controls and Navigation

**Goal:** Make it clear what evidence supports an answer and ensure each
evidence control opens the right activity.

### Investigate

-   `ReflectionChatSection`, `insightCard`, and `evidenceLabel` in
    `InbetweenApp.swift`.
-   Snapshot evidence construction in `AIInsights.swift`.
-   `showReflectionEvidence` and the mapping between evidence IDs and
    stored sessions/slices.

### Implement

-   Avoid rendering multiple identical `View evidence` controls without
    a clear association to the corresponding claim or evidence item.
-   Give each evidence link a clear, useful label.
-   Ensure a daily summary that combines multiple sessions does not
    misleadingly navigate to only the first session.
-   Where practical, allow inspection of all contributing
    sessions/slices; otherwise, define and communicate the actual scope
    of the link.
-   Preserve the ability to inspect useful local evidence.
-   Keep navigation behavior deterministic and safe if a referenced
    record no longer exists.

### Tests

-   One evidence item.
-   Multiple evidence items in one answer.
-   Daily summary aggregating multiple sessions.
-   Missing or deleted target records.
-   Correct association between claims, evidence IDs, and navigation
    targets.

### Completion criteria

-   Evidence controls are not confusingly duplicated.
-   Each link has defined, tested behavior.
-   Multi-session evidence is represented honestly and navigates to the
    appropriate source records.

### Phase 5 result (2026-10-16)

-   Completed. Evidence links now retain all source wait IDs and slices.
    Daily summaries navigate to History, scroll to the earliest surviving
    source, and highlight every contributing wait and slice. Missing source
    records are filtered before navigation; a link with no surviving target
    does nothing safely.
-   Reflection citations and insight evidence controls use per-item labels
    instead of repeated generic “View evidence” controls. Each control
    invokes navigation for its own evidence ID.
-   Added coverage for single-source evidence, two-session daily evidence,
    slice mapping, target filtering when records are missing, and the daily
    evidence label.
-   Verification: `swift test --filter 'AIInsightsTests|ReflectionChatTests'`
    passed (21 tests); `./scripts/verify-fast.sh` passed (20 scenarios,
    159 Swift tests in 19 suites, and 13 Python tests).

------------------------------------------------------------------------

## Phase 6 --- Clean Up Reflection's User Interface

**Goal:** Remove developer-facing implementation copy from the normal
Reflection experience while retaining useful functionality.

### Investigate

-   `ReflectionChatSection` and any active Reflection UI in
    `InbetweenApp.swift`.
-   Debug-only snapshot disclosure and related build-configuration
    behavior.
-   Existing empty, loading, error, and follow-up conversation states.

### Implement

-   Remove or rewrite the subtext: "Local calculations stay
    authoritative. Featherless only interprets the snapshot after you
    ask a question."
-   Replace or remove "Answer grounded in linked local evidence." if it
    does not provide meaningful user-facing information.
-   Keep "Developer · snapshot sent" out of the normal user interface.
    If diagnostics remain useful, make them accessible through an
    explicitly developer-only mechanism.
-   Remove confusing duplicate `View evidence` controls as defined in
    Phase 5.
-   Keep Today and Last 7 Days labels clear and consistent with the
    actual scope.
-   Make comparison dates explicit when a response compares days.
-   Preserve the Reflection question-and-answer workflow and useful
    error states.
-   Maintain the existing compact macOS design; avoid unrelated layout
    or architecture rewrites.

### Tests and verification

-   Relevant UI and snapshot tests.
-   Normal release build does not expose developer-only diagnostics.
-   Debug diagnostics remain available only where intentionally
    designed.
-   Long answers, empty states, evidence links, and API errors remain
    usable.

### Completion criteria

-   Normal users see clear product language rather than implementation
    details.
-   Useful evidence inspection and safeguards remain intact.
-   Reflection's scope and comparison period are understandable.

### Phase 6 result (2026-10-16)

-   Completed. Removed the implementation-focused chat subtitle and the
    redundant success status; loading, unavailable, stale-response, and
    provider-error states remain. Last 7 Days now shows its exact ISO date
    range, and comparison metric labels include both compared dates.
-   Kept the sanitized snapshot disclosure inside `#if DEBUG`; the Release
    app target builds without that developer-only UI. Reworded the unused
    alternate Reflection section's subtitle for product-facing language.
-   Added regression tests for empty and length-limited answers and explicit
    comparison dates; existing tests continue to cover evidence links,
    snapshot ranges, API errors, and sanitization.
-   Verification: `swift test --filter 'ReflectionChatTests|AIInsightsTests'`
    passed (23 tests); `swift build -c release` succeeded; and
    `./scripts/verify-fast.sh` passed (20 scenarios, 161 Swift tests in 19
    suites, and 13 Python tests).

------------------------------------------------------------------------

## Phase 7 --- Activity Provenance, Observability, and Synthetic Steam Demo

**Goal:** Distinguish what Inbetween directly samples, what it derives from
metadata, what is synthetic, and what was not observed. Establish the source
of the History records, distinguish observed/inferred/synthetic provenance,
and replace the confirmed synthetic TV demo activity with synthetic Steam
activity without changing genuine records or manual overrides.

### Investigation findings (2026-10-16)

-   `ForegroundActivityMonitor.swift` collects activity only while a Codex
    wait is active. It reacts to `NSWorkspace.didActivateApplicationNotification`,
    checks `NSWorkspace.frontmostApplication`, and samples every five
    seconds. Apple's API documentation describes the frontmost app as the
    app receiving key events; this collector is therefore a foreground-app
    sampler, not a full inventory of running apps.
-   When Accessibility permission is available, the monitor registers
    focused-window/title notifications and reads the focused window's
    title and document/URL attributes through `AXUIElement`. Unsupported or
    unavailable attributes return no context. Browser enrichment also
    reads the current Safari/Chrome tab through AppleScript (with a
    fifteen-second polling interval); Xcode, VS Code, Finder, Terminal,
    and iTerm metadata are parsed by `ActivityEnrichmentParser`.
-   Application identity/name come from `NSRunningApplication`; the
    application-category identifier is read from the app bundle's
    `LSApplicationCategoryType`. Browser domain and page title, resource
    kind/name, and workspace/document details are combined or derived by
    `ActivityEnrichmentParser` and browser enrichers. `ActivityContext`
    persists the resulting values but does not persist which API or parser
    supplied each field. The current record therefore cannot distinguish
    direct metadata from inferred/derived metadata after collection.
-   Presence is derived from `CGEventSource.secondsSinceLastEventType` and
    local idle/away thresholds. The persisted `.active`, `.idle`, and
    `.away` states are therefore presence estimates based on recent input,
    not direct observations of a person's attention.
-   `ActivityObservation` stores a context and observation timestamp;
    `ActivitySegment` stores that context and its time bounds. It does not
    store a collector/source type. Unobserved intervals are separately
    represented by classification slices with a nil
    `sourceActivitySegmentID` and an `unobservedGap` reason. The five-second
    sampling interval and those known gaps do not establish continuous
    observation of what was displayed or played between samples.
-   The local store was inspected read-only for only TV app identity and
    provenance fields. It contains two matching records; both have bundle
    identifier `com.apple.TV`, `hookSource` `inbetween-demo-seeder`, and
    `syntheticDataSetID` `inbetween-demo-history-2026-09-v1`. No titles,
    dates, or session IDs were emitted. These two TV entries are confirmed
    synthetic records; this conclusion comes from persisted provenance,
    not their display label.
-   The requested demo correction is to replace those two dataset-owned TV
    activities with Steam activities. `com.valvesoftware.steam` is already
    recognized by `WaitSessionClassification.swift` as a distracting
    application identity. The installed Steam app's `Info.plist` confirms
    that bundle identifier; it does not declare
    `LSApplicationCategoryType`, so the replacement must not claim that
    Steam's native app category was observed. Its Distracted result should
    be tied to the existing built-in bundle rule and remain explicitly
    synthetic through the existing dataset marker and seeder hook source.
-   `DemoHistorySeeder.makeSession` writes the `TV` name, `com.apple.TV`
    bundle identifier, entertainment app category, and `Continue Watching`
    title directly into synthetic activity. Apart from the seeder, there
    is no other hardcoded TV label assignment or inference. The runtime
    collector can still persist the dynamic name and bundle ID supplied by
    `NSWorkspace` for any frontmost application. The semantic candidate
    text mentions television as a concept, but that affects classification
    only; it does not generate or rename activity records. History displays
    the stored application name without a TV category remapping.
-   Other seeder-generated activities are Xcode (`Inbetween · Reflection`,
    workspace `Inbetween`), Safari (SwiftUI documentation at
    `developer.apple.com`), and Notes (`Weekend ideas`, idle/away). These are
    all synthetic and explicitly dataset-tagged. Their fields are plausible
    demo contexts but are not evidence of captured user activity. The source
    inspection found no separate provenance or observability defect that
    warrants changing them as part of the Steam replacement.
-   Normal `InbetweenApp` startup loads the existing `WaitSessionStore`;
    it does not call the seeder. The seeder is a separate executable target,
    requires `--confirm` in its CLI, and its core API rejects a call without
    confirmation. Existing seeded records remain visible because normal
    startup loads persisted history.
-   `WaitSession.syntheticDataSetID` is Codable, but it is session-level
    only. Its nil value currently covers both real and legacy records, so
    nil cannot safely be interpreted as affirmative proof of real capture.
    The model has no per-field observed/inferred source marker. This pass
    did not modify the user's store.
-   The collector does not query media playback state in the TV app;
    content could appear only if the app exposes it through metadata
    Inbetween already reads. This describes Inbetween's current
    implementation, not what macOS APIs could theoretically observe. No
    live TV-app capture was performed.

### Synthetic Steam replacement: implementation and verification (2026-10-16)

-   Updated only the seeder-owned entertainment demo entries to use Steam
    (`com.valvesoftware.steam`) and retain their Distracted classification.
    Preserved the current seeded timeline and durations: 540 seconds on the
    first seeded day and 395 seconds on the second. Fresh seeding creates the
    Steam fixtures with deterministic seeded identities; existing TV rows
    are changed only by the separate migration below. Steam contexts carry
    no fabricated app category or game/window title. Dataset ID and
    `inbetween-demo-seeder` remain intact.
-   Added a separate `migrateSyntheticTVToSteam(confirmed:)` operation and
    `--migrate-synthetic-tv-to-steam --confirm` CLI path. Ordinary seeding
    does not migrate existing TV records. The migration matches only the two
    known deterministic session IDs with this dataset marker and seeder hook.
    It backs up and verifies the backup before writing, verifies the saved
    records and unchanged history after writing, and stops without automatic
    rollback if post-write verification fails. The migration has
    been run as a separate confirmed operation against the user's persisted
    history. It migrated exactly two records; backup verification and
    post-write verification succeeded.
-   Existing matching records retain IDs, timestamps, durations, session and
    slice manual overrides, and review state. Genuine records and other demo
    fixtures are preserved. Migrated records retain synthetic provenance and
    classify as Distracted through the built-in Steam bundle rule.
-   `DemoHistorySeederTests` now cover Steam identity/classification and
    provenance, unchanged count/timeline/per-day durations, migration and
    seeding idempotency, explicit confirmation, genuine-record preservation,
    and session/slice override preservation. The seeded days remain
    2,535, 1,900, and 3,250 seconds across their respective days; no extra
    session is added during migration.
-   Added a regression test that injects a failed post-write verification on a
    disposable fixture store. It verifies the migration reports failure while
    leaving the saved migrated records intact, preserving identities and
    manual decisions, and never restoring the original snapshot.
-   Verification: the focused
    `DemoHistorySeederTests.failedPostWriteMigrationVerificationDoesNotRestoreOriginalSnapshot`
    passed. The latest `./scripts/verify-fast.sh` run passed (20 scenarios,
    167 Swift tests in 19 suites, and 13 Python tests). Verification used a
    dedicated cache under the user-owned temporary directory after the default
    cache location failed; no application or seeder executable was launched,
    and all store fixtures were temporary.

### Phase 7 implementation and verification results (2026-10-16)

-   Added persisted `ActivityRecordOrigin` values for captured, synthetic,
    and legacy-unknown sessions. New lifecycle-created waits are captured;
    seeded waits are synthetic; older tagged rows decode as synthetic and
    untagged rows decode as unknown. No store-wide rewrite or migration was
    run for this work.
-   Added `ActivityContextProvenance` for the source of application identity,
    app category, window title, browser URL/title/domain, resource metadata,
    and presence estimate. The foreground collector marks the frontmost app,
    Accessibility, browser AppleScript, bundle metadata, parser-derived
    fields, and recent-input estimates without copying additional content to
    diagnostics. Legacy contexts without source metadata remain unknown.
-   History labels captured, synthetic, and legacy-unknown records in both
    visible and accessible row descriptions. Expanded sampled-context details
    explain the source of fields and clarify that presence estimates do not
    measure attention. Known nil-source slices are labeled “Unobserved
    interval” with a readable duration; legacy sessions without a gap map do
    not claim complete observed coverage. History also states that sampling
    does not prove continuous visibility between observations.
-   Preserved the existing `syntheticDataSetID` contract. Steam replacement
    and the separately confirmed migration remain limited to the two known
    seeder-owned identities; no other demo or captured record was rewritten.
-   Regression coverage verifies captured and synthetic assignment, legacy
    fallback, context source round-trips, observed versus derived browser
    metadata, synthetic seeder provenance, manual-override preservation,
    explicit unobserved duration, and absence of a gap map for legacy data.
-   Final Phase 7 regression result: included in `./scripts/verify-fast.sh`
    (20 scenarios, 166 Swift tests in 19 suites, and 13 Python tests; all
    passed). `git diff --check` passed.

### Risks and limitations

-   Adding provenance to persisted records requires backward-compatible
    decoding. Legacy untagged records must remain unknown rather than being
    mislabeled as captured.
-   Metadata provenance should describe how a value was obtained without
    broadening the collected content. Browser titles and paths remain
    sensitive and must not be copied to diagnostics merely to explain their
    source.
-   The two synthetic TV records were replaced with Steam in the earlier,
    separately confirmed migration recorded above. This phase did not rerun
    it. The finding does not establish what metadata a real foreground TV
    application would expose; provenance is based only on the collector
    fields actually available at each sample.

### References

-   [NSWorkspace.frontmostApplication](https://developer.apple.com/documentation/appkit/nsworkspace/frontmostapplication)
-   [NSWorkspace.didActivateApplicationNotification](https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification)
-   [AXUIElementCopyAttributeValue](https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue)

------------------------------------------------------------------------

## Phase 8 --- Regression Testing, Build, and Release Verification

**Goal:** Verify the repaired system end to end and document any
remaining limitations.

### Verify end-to-end behavior

1.  Launch Inbetween normally.
2.  Record a new activity with sufficient context.
3.  Confirm a clearly identifiable activity is classified as intended.
4.  Confirm ambiguous activity receives the deterministic
    Productive/Distracted fallback and unobserved intervals remain clearly
    identified.
5.  In History, correct a stored activity to Productive or Distracted.
6.  Restart the app and confirm the manual decision persists.
7.  Confirm automatic classification does not overwrite the manual
    decision.
8.  Confirm History totals reflect the corrected classification without
    double-counting.
9.  Open Reflection and check Today metrics.
10. Compare Today against a specific day and verify the date.
11. Switch to Last 7 Days and verify the range.
12. Check a cross-midnight interval and period-boundary interval.
13. Ask Featherless a question and verify evidence references.
14. Confirm unsupported evidence or numeric claims are rejected or
    handled safely.
15. Confirm duration formatting is readable.
16. Confirm missing API configuration and network failures produce clear
    errors.
17. Confirm normal UI does not expose unnecessary developer diagnostics.
18. Confirm Steam demo provenance and that normal launches do not create or
    migrate demo records; confirm no genuine record or manual override changed.

### Automated verification

-   Run the relevant Swift Testing and XCTest suites.
-   Run relevant Python tests if affected code uses Python.
-   Add regression tests for each confirmed root cause.
-   Run `scripts/build-app.sh` and `scripts/verify-release.sh` if they
    remain the appropriate project scripts.
-   Inspect build output and test results; fix regressions introduced by
    the repair.
-   Do not change unrelated behavior merely to make tests pass.

### Documentation

-   Update this plan to mark completed phases and record any deviations.
-   Update relevant technical documentation for classification
    precedence, review eligibility, aggregation semantics, evidence
    validation, and synthetic-data provenance.
-   Document any manual steps that remain necessary.

### Completion criteria

-   Relevant tests pass.
-   Build and release verification pass, or failures are explicitly
    documented with their causes.
-   History corrections and Reflection agree on classification and
    duration semantics.
-   No existing manual override is silently lost.
-   Remaining limitations are reported honestly.

### UI cleanup follow-up (2026-10-17)

-   Removed the Needs Review destination from `DashboardDestination`, its
    menu-bar card and status badge, its Overview prompt, and the dashboard
    queue screen. Removed app-side review selection, navigation, and
    mark-handled wrappers. History continues to offer Productive and
    Distracted corrections for whole-wait and sliced records.
-   Audited the remaining model dependencies. `WaitSessionClassification`
    still decodes legacy Unclassified values; `WaitSessionClassificationResult`
    still decodes and round-trips `reviewSuggested`; sessions and slices
    still preserve their handled-review flags. These are persisted history
    fields and remain untouched by this UI cleanup. The core pending-review
    projections/navigation helpers remain available to legacy scenario and
    compatibility tests, but the Inbetween app no longer calls them.
    `classificationUnits(for:)` remains in use by History to group slices for
    manual correction. New classifier results remain Productive or Distracted.
-   The normal Reflection status no longer presents the success copy
    “Answer grounded in linked local evidence.”; that copy was already absent
    in the working tree at the start of this change. The debug snapshot
    disclosure remains enclosed by `#if DEBUG`; the release executable does
    not contain its “Developer · snapshot sent” string. Reflection failures
    now use concise user-facing retry guidance rather than exposing provider
    names, HTTP codes, evidence identifiers, or snapshot-validation
    terminology. Unsupported numeric claims say “Reflection couldn’t verify
    a numeric answer. Your local summary is still available.” Typed error
    cases remain available to internal handling.
-   Added four Python source-contract tests for removed review navigation,
    retained History correction controls, retained Reflection metrics and
    evidence navigation, and debug-only snapshot disclosure. Added a Swift
    test for the numeric-response message.
-   `swift test --filter ReflectionChatTests`: passed (11 tests).
    `./scripts/verify-fast.sh`: passed (20 scenarios, 175 Swift tests in 20
    suites, and 17 Python tests). `CONFIGURATION=release
    ./scripts/build-app.sh` built and ad-hoc signed Inbetween 0.3.0 (3).
    `CONFIGURATION=release ./scripts/verify-release.sh` passed bundle,
    signature, and entitlement checks. A `strings` inspection found no
    “Developer · snapshot sent” string in the release executable.
    `git diff --check` passed after the final documentation update.
-   Final runtime UI verification was performed on 2026-10-17 against the
    release app and a disposable store under
    `/private/tmp/inbetween-runtime-ui.cDQpaw`. The test-only Dashboard
    window showed Overview, Reflection, History, and Settings, with no Needs
    Review destination. The legacy Unclassified fixture remained visible in
    History, but there was no review queue; History exposed only the intended
    Productive and Distracted correction controls.
-   Selected Productive for the disposable legacy History record. The fixture
    store persisted `manualClassificationOverride=productive` and
    `classificationReviewHandled=true`. After gracefully quitting and
    relaunching only the release process with the same test-directory
    argument, Overview and History both showed Productive for the two-minute
    record. No real history was used for this correction.
-   The normal Reflection screen rendered in the release process. Its
    accessibility tree and screenshot contained no “Developer · snapshot
    sent,” snapshot-validation terms, or provider error details. The isolated
    store had no Reflection switches, so Send was disabled; no provider/API
    error state or evidence result could be exercised without credentials.
-   The Dashboard window was reachable through the explicit test-only menu
    command. The macOS menu-bar host was inspectable, but automation clicks
    did not expose Inbetween's status-item popover, so the popover itself
    remains unverified. No claim is made that this interaction passed.
-   `./scripts/verify-fast.sh` passed: 20 scenarios, 175 Swift tests in 20
    suites, and 17 Python tests. `./scripts/verify-release.sh` passed bundle,
    signature, and entitlement checks. `git diff --check` passed after this
    update. Release build completed with the dedicated temporary Swift module
    cache; an initial sandboxed build attempt was blocked before the successful
    escalated build.
-   Data-safety discrepancy: during UI-target resolution, a release process
    without the disposable-store argument was briefly running. It was
    gracefully stopped. A read-only stat changed for
    `~/Library/Application Support/Inbetween/wait-sessions.json` from 879,583
    bytes at 00:43:11 to 879,587 bytes at 00:59:07 on 2026-10-17.
    The process and timing overlap, but the exact cause and content difference
    are not established. No store contents were inspected for this check and
    no repair, restore, migration, or further write was attempted. Treat this
    as an unresolved integrity discrepancy requiring a separate authorized
    audit; the request's no-real-history-write constraint was not fully met.

### Final end-to-end verification rerun (2026-10-17)

-   Read `AGENTS.md` and this plan before verification. `./scripts/verify-fast.sh`
    passed: 20 headless scenarios, 176 Swift tests in 20 suites, and 17 Python
    tests. The suite includes coding-context precedence across applications,
    distracting cases, deterministic fallback, manual overrides, persistence
    reload, stale-snapshot rejection, and UI source contracts.
-   `CONFIGURATION=release ./scripts/build-app.sh` passed and produced a valid
    ad-hoc signed Inbetween 0.3.0 (3) bundle. `./scripts/verify-release.sh`
    passed bundle metadata, signature, and entitlement checks. `git diff
    --check` is recorded after this documentation update.
-   Generated 10 demo sessions only under `/private/tmp/inbetween-ui-data`
    through a temporary copy of the core module and its existing seeder API.
    The release app was invoked only with that isolated directory. No real
    store was read or written; no production migration or reclassification
    ran.
-   Runtime GUI verification is **unverified**. `open -n` against the fresh
    build initially returned Launch Services error `-10827`
    (`kLSNoExecutableErr`) even though the bundle executable existed and the
    bundle passed code-signature checks. Directly executing the GUI binary
    exited with `SIGABRT` in AppKit application registration, so direct
    execution is not a valid launch path. Explicitly registering a disposable
    copy with Launch Services made `open` return success, but Computer Use
    could not attach to Inbetween and no running app/window was observable.
    A transient accessibility tree showed a Needs Review row that does not
    exist in the current `DashboardDestination` source; because its process
    identity could not be established, that tree is not treated as evidence
    about this release.
-   Therefore the menu-bar popover, Dashboard navigation, History correction
    controls, app-restart persistence, Reflection normal/loading/error states,
    and evidence navigation were not verified interactively in this rerun.
    Their automated coverage passed. No live provider request was made; actual
    provider loading/error display and remote evidence navigation remain
    unverified at runtime. No code failure was confirmed that justified an
    unrelated UI or packaging change.
-   Limitation: the fresh app bundle's Launch Services registration/launch
    behavior remains unresolved in this verification environment. The build
    and release checks passing do not establish that the app window or menu
    popover works at runtime.

### Phase 8 verification results (2026-10-16)

-   `./scripts/verify-fast.sh` passed: 20 in-memory scenarios, 166 Swift
    tests in 19 suites, and 13 Python tests.
-   `CONFIGURATION=release ./scripts/build-app.sh` built and ad-hoc signed
    the release bundle. `./scripts/verify-release.sh` passed for Inbetween
    0.3.0 (3), including bundle metadata, signature, and entitlement checks.
-   Launched the release app through Launch Services with a disposable store
    under `/private/tmp/inbetween-phase8-ui`. The test-only dashboard command
    opened the dashboard for Accessibility inspection. History visibly
    distinguished Captured locally, Synthetic demo, and Legacy · source
    unknown; expanded context showed foreground/Accessibility provenance,
    while automated tests cover parser-derived metadata. A 15-second
    nil-source interval appeared as “Unobserved interval · 15s ·
    Unclassified.” A second fixture emulated a previously migrated Steam row
    with no per-field provenance; History still presented it as Synthetic
    demo.
-   Needs Review showed an eligible Unclassified item and both Productive and
    Distracted actions. Applying Productive removed it from review and updated
    the local aggregate. After quitting and relaunching, the two-minute
    Productive result remained in Overview and History. The empty Needs Review
    state was also visible.
-   Reflection displayed readable durations (2m, 9m, and 1m 45s) and the
    explicit Last 7 Days range “2026-10-10 through 2026-10-16.” No question
    was sent to Featherless. The send control was disabled in this isolated
    session, so assistant loading/error UI and result evidence buttons could
    not be exercised interactively; provider failure and evidence-navigation
    behavior remain covered by the passing automated tests.
-   The release app’s status item was visible in the macOS menu bar and its
    dashboard was reachable through the isolated UI-test command. Automation
    did not expose the status item’s popover after a click, so the popover
    interaction itself remains unverified. No new foreground activity was
    generated during GUI checks; an already-running debug instance held the
    lifecycle listener.
-   Release source excludes the “Developer · snapshot sent” disclosure under
    `#if DEBUG`; the string is absent from the release executable. The test-
    only command is present only when the explicit test data-directory
    argument is supplied.
-   GUI fixture history, rules, and diagnostics were isolated under
    `/private/tmp/inbetween-phase8-ui`. No migration or demo seeding ran
    against the real store. A plain release process briefly relaunched
    without the isolated argument during UI automation and was stopped. A
    comparison against the existing post-migration backup found all existing
    session identities and manual-decision fields preserved; two newer
    sessions and one normal lifecycle transition were present in the current
    store. Since no prelaunch byte-for-byte snapshot existed, that brief
    relaunch cannot be excluded as a writer, although no existing manual
    decision changed.
-   `git diff --check` passed after the final edits.

### Follow-up: stale whole-store write protection (2026-10-16)

-   Confirmed cause: `WaitSessionStore` read and replaced the entire JSON
    snapshot without checking whether another process had changed it since
    load. The app retained a tracker snapshot in memory, and the explicit
    demo seeder also wrote snapshots loaded earlier.
-   Added a sidecar file lock around compare-and-save and atomic replacement.
    Production app persistence and the seeder now submit their original
    loaded snapshot as the expected base; mismatches fail with a stale-snapshot
    error and preserve the newer on-disk records. The app advances its base
    only after a successful save and refuses to save if initial loading failed.
    Manual classification overrides and review decisions remain ordinary
    session fields and are preserved in the exact snapshot accepted by the
    comparison.
-   Added a disposable two-writer regression: one writer adds a session while
    retaining session and slice manual decisions; the other writer's stale
    whole-store save is rejected, file bytes remain unchanged, and reload
    confirms both identities and review decisions remain present.
-   Verification: `./scripts/verify-fast.sh` passed (20 scenarios, 168 Swift
    tests in 19 suites, and 13 Python tests). `git diff --check` passed.
    The verification ran only isolated tests; Inbetween was not launched and
    no migration or real-history store access was performed.
-   Limitation: the lock coordinates writers that use `WaitSessionStore`'s
    compare-and-save API. A future or external writer that bypasses this API
    is not protected by the coordination protocol.

### Stale-write concurrency regression follow-up (2026-10-17)

-   Rechecked the current persistence flow. The store serializes cooperating
    saves with an exclusive sidecar `flock`, reloads the latest on-disk
    snapshot under that lock, and atomically replaces the JSON only when the
    snapshot equals the caller's expected base. A stale compare therefore
    fails explicitly before writing. The app updates its in-memory base only
    after a successful save. The app, seeder, and history reclassifier all use
    compare-and-save.
-   Added a simultaneous-writer regression using a disposable store. Two
    writers load the same base and race distinct whole-store candidates; one
    commits and the other receives `staleSnapshot`. Reload confirms the
    original identity, timestamps, duration, activity segment, slice,
    synthetic provenance, manual classifications, and handled-review flags
    remain intact alongside exactly one committed new session. The earlier
    sequential stale-snapshot regression remains in place.
-   Marked `WaitSessionStore` as `Sendable` so concurrent callers can use the
    immutable store value safely from Swift concurrency contexts.
-   Verification on 2026-10-17: `./scripts/verify-fast.sh` passed (20
    scenarios, 176 Swift tests in 20 suites, and 17 Python tests);
    `CONFIGURATION=release ./scripts/build-app.sh` passed and produced a valid
    signed bundle; `./scripts/verify-release.sh` passed for Inbetween 0.3.0
    (3); `git diff --check` passed, and the updated plan has no trailing
    whitespace.
    Verification used disposable test stores and temporary compiler caches;
    the production app was not launched and real history was not accessed.
-   Limitation: writers that bypass the shared compare-and-save protocol are
    not coordinated by the sidecar lock. No automatic merge is attempted;
    callers receive a stale-snapshot error and must reload before retrying.

------------------------------------------------------------------------

## Cross-Phase Risks and Safeguards

-   **Historical data:** Do not silently reclassify existing records
    using the current classifier. Preserve manual overrides and use
    explicit, reversible migrations when required.
-   **Whole-store writes:** Production history updates must use the locked
    compare-and-save API with the snapshot they loaded. Unconditional writes
    are reserved for isolated fixtures and new backup files.
-   **Review eligibility:** Broadening review eligibility may expose
    legacy records previously hidden by missing review flags. Do not
    treat unobserved gaps as captured activity.
-   **Metric semantics:** Correcting interval clipping and legacy
    partial-coverage handling may change displayed historical totals.
    Document the intended semantics and test the differences.
-   **NLP:** Broad keyword rules can create false positives. Use real
    captured metadata and conservative fallbacks.
-   **AI validation:** Do not treat prompt instructions as enforcement,
    and do not weaken evidence validation to hide errors.
-   **Privacy:** Avoid unnecessary logging of raw titles, URLs, paths,
    identifiers, or API keys.
-   **Scope control:** Preserve the existing architecture and avoid
    unrelated refactors.
-   **Verification:** Report exactly which tests and build commands were
    executed and their actual results.

## Progress Tracker

-   [ ] Phase 1 --- Historical review eligibility and aggregate
    consistency
-   [ ] Phase 2 --- Reflection interval clipping and date attribution
-   [ ] Phase 3 --- Local NLP classification
-   [x] Phase 4 --- Reflection answer validation and duration formatting
-   [x] Phase 5 --- Evidence controls and navigation
-   [x] Phase 6 --- Reflection UI cleanup
-   [x] Phase 7 --- Activity provenance, observability, and synthetic Steam demo
-   [x] Phase 8 --- Regression testing and release verification

### Release launch investigation follow-up (2026-10-17)

-   Inspected `Support/Inbetween-Info.plist`, the release executable, its
    ad-hoc signature and Apple Events entitlement, and `scripts/build-app.sh`.
    The bundle contains an arm64 executable at the declared path, valid
    `Info.plist` metadata, and a valid signature. `PkgInfo` is not emitted by
    the build script; a disposable copy with the same layout and no `PkgInfo`
    launched successfully, so adding that file was not justified.
-   Reproduced direct-executable `SIGABRT` and inspected its crash report. The
    abort occurs in AppKit `___RegisterApplication_block_invoke` /
    `_RegisterApplication` during process registration. It is specific to
    directly executing a GUI binary outside Launch Services; no crash report
    was produced for Launch Services-started copies. The initial
    `open` `-10827` result was reproduced on a disposable copy, but its cause
    was not established as a bundle defect. A fresh unique-ID copy matching
    the release bundle structure later launched through `open` with exit 0;
    repeated launches of another copied bundle still showed inconsistent
    Launch Services results.
-   Captured a live sample of a Launch Services-started disposable app that
    had not finished launching. Its main thread was blocked in
    `SecItemCopyMatching`, called synchronously by
    `LifecycleViewModel.init` -> `refreshAIConfiguration` while SwiftUI was
    registering the menu-bar scene. A screenshot showed macOS waiting for
    authorization to access the Featherless Keychain item because the
    disposable app copy had a different ad-hoc code signature. This explains
    the absent inspectable UI: startup waited on a Keychain authorization
    dialog instead of completing. No password was entered and no access was
    approved.
-   Moved the Keychain read off the main actor and guarded asynchronous results
    with a refresh identifier so an older response cannot replace newer AI
    settings. Isolated UI-test launches now use an empty in-memory credential
    store by default; they do not query the user's Keychain. Added a source
    contract regression for this test-mode isolation and background read.
-   Runtime verification on disposable stores: after the fix, a fresh copied
    release bundle launched via `open`; `NSWorkspace` reported the app had
    finished launching with accessory activation policy. A separately
    activated UI-inspection copy exposed an Accessibility tree and rendered
    Overview, Reflection, History, and Settings, with no Needs Review
    destination. History showed two explicitly Synthetic demo records. A
    manual Productive-to-Distracted correction persisted on the classification
    slice with its review-handled flag; after terminating and restarting that
    disposable app, History still showed Distracted. Reflection rendered the
    Today scope, local metrics, and readable `4m` duration. Its question
    control was disabled because no provider model was configured. No live API
    request was made; answer evidence navigation was therefore not exercised.
-   The menu-bar popover was captured and showed the expected status, recent
    summary, Open, Reflection, History, and Quit controls without developer
    diagnostics. Several same-icon Inbetween processes were present during
    this check, so the popover screenshot could not be unambiguously matched
    to the fresh bundle identifier. One unmapped popover displayed a `4h 54m`
    aggregate; no session rows, titles, or activity context were opened. Its
    source cannot be established, so it may have belonged to a pre-existing
    instance. Treat exact per-process popover attribution as a limitation;
    the UI itself rendered.
-   One attempted demo-seeder invocation with a temporary `HOME` failed with
    `Operation not permitted`: the seeder constructs the default store rather
    than accepting a store path. It was abandoned, and the UI fixture was
    generated directly into `/private/tmp/inbetween-window-qa-data`. No
    successful seeder write or migration occurred. Because the failed seeder
    may have attempted its default-store lookup before the denial, I cannot
    establish whether it attempted a read; it returned no record data and no
    history file outside `/private/tmp` was intentionally changed.
-   Verification after the implementation: `./scripts/verify-fast.sh` passed
    (20 scenarios, 176 Swift tests in 20 suites, and 18 Python tests);
    `CONFIGURATION=release ./scripts/build-app.sh` passed and produced a valid
    ad-hoc signed bundle; `./scripts/verify-release.sh` passed for Inbetween
    0.3.0 (3); `git diff --check` passed before this plan update and is rerun
    after it.
-   Remaining limitation: `open` on copied bundles returned `-10827`
    inconsistently even with a valid executable and signature; the first
    fresh unique-ID release-layout copy after the fix launched successfully.
    The initial `-10827` has no captured Launch Services diagnostic tying it
    to an app defect, so it is not attributed to Keychain blocking. The
    direct-execution abort is explained by AppKit registration context and is
    not the supported launch route.

### Final GUI isolation and release-layout follow-up (2026-10-17)

-   Multiple running processes had identical `Inbetween` names and status
    symbols, making coordinate-only menu-bar selection ambiguous. Added a
    disposable-test-only `Inbetween UI Test` title and `testtube.2` status
    symbol when an isolated test data directory is supplied. The test-only
    command menu now opens Overview, History, and Reflection deterministically.
    Normal launches retain the existing name, icon, and navigation.
-   Ran a copied release bundle with a unique bundle identifier and a copied
    two-record fixture under `/private/tmp`. Its unique status item was
    accessible as “Two Test Tubes”; the test command opened an inspectable
    Dashboard window. The window-inspection copy had `LSUIElement=false` so
    macOS exposed its normal app window to accessibility. No real store or
    seeder was used, and no unrelated Inbetween process was stopped.
-   Runtime Dashboard showed Overview, Reflection, History, and Settings, with
    no Needs Review destination. History showed the synthetic Xcode and Steam
    rows and their synthetic-demo provenance. A Productive correction to the
    Xcode row was visible in History, persisted as a Productive manual slice
    override, and remained visible after quitting and relaunching that test
    copy from the same isolated store.
-   Reflection rendered its local `4m` Productive metric and Today scope. With
    no provider configured, the question control stayed disabled and showed
    “Set up Reflection in Settings to ask questions.” No developer snapshot
    disclosure or internal validation text appeared. No live provider request
    was made. Provider response/loading/error behavior and evidence navigation
    remain unverified at runtime because no provider was configured.
-   The test-only unique status item was found and pressed through
    process-scoped Accessibility, but repeated attempts did not yield a
    visible menu-bar popover. The popover behavior therefore remains
    unverified; `open` success and the visible Dashboard are not counted as a
    popover pass.
-   Compared existing successful and unsuccessful disposable release-layout
    bundles. The inspected copies differed in bundle identifier, executable
    build/hash, `PkgInfo` presence, and signing-directory contents; each
    inspected signature and declared executable path was valid. These were
    not controlled copies differing in only one packaging property, and no
    Launch Services diagnostic tied `-10827` to one of those differences.
    The cause of intermittent `-10827` remains undetermined, so no packaging
    change was made.
-   A read-only 24-hour unified-log search did find `-10827/kLSNoExecutableErr`
    for bundle identifier `com.inbetween.launchprobe`; CoreServicesUIAgent
    logged that this bundle had no inode. Its path was privacy-redacted. The
    same query found no `-10827` failure attributed to `com.inbetween.app`,
    only launch-start records. This explains that logged LaunchProbe failure,
    but does not establish that it caused the separately reported Inbetween
    release-copy failure.
-   Final verification after the changes: `./scripts/verify-fast.sh` passed
    (20 scenarios, 176 Swift tests in 20 suites, 21 Python tests),
    `CONFIGURATION=release ./scripts/build-app.sh` passed,
    `./scripts/verify-release.sh` passed for Inbetween 0.3.0 (3), and
    `git diff --check` passed. Swift caches were redirected to writable
    directories under `/private/tmp` after the default module cache was denied
    by the sandbox; no unrelated permissions were changed.

### Menu-bar and packaging investigation follow-up (2026-10-17)

-   Read-only source inspection confirmed the status UI is a native
    `MenuBarExtra` with `.window` style. The test-only menu opens the Dashboard
    as a separate `Window`; that path does not exercise the status-item
    popover.
-   Reproduced Launch Services `-10827` with a newly copied release bundle at
    `/private/tmp/inbetween-menu-verify-20261017/InbetweenMenuVerify.app`,
    using the disposable data directory
    `/private/tmp/inbetween-menu-verify-20261017/data` and unique identifier
    `com.inbetween.menuverify20261017`. Its declared `Contents/MacOS/Inbetween`
    executable existed, was executable arm64 Mach-O, and its ad-hoc signature
    verified. Launch Services nevertheless rejected it before an app process
    or inspectable UI appeared.
-   On that same disposable copy, changed only `LSUIElement` from true to false,
    re-signed, and retried: the result remained `-10827`. Then added a valid
    `Contents/PkgInfo` (`APPL????`), re-signed, and retried: the result again
    remained `-10827`. A second uniquely identified copy under `.build/apps`
    also returned `-10827`. These observations do not identify the cause; no
    packaging fix is justified. The existing log evidence still attributes
    the captured `kLSNoExecutableErr` to `com.inbetween.launchprobe`, not
    `com.inbetween.app`; no matching error was found for the newly tested ID.
-   The test copies did not reach runtime, so this run could not observe a
    visible status popover, dismissal, popover navigation, or Reflection’s
    Settings button. Earlier process-scoped AX presses also had no visible
    popover result. Together these establish neither a genuine popover defect
    nor an accessibility-only limitation. Popover runtime behavior remains
    unverified, and no source or packaging behavior was changed.
-   The earlier disposable runtime run documented the unconfigured Reflection
    message and local metrics, with no provider configured. This follow-up did
    not launch the app, so Settings navigation remains unverified; provider
    loading, provider errors, and evidence navigation remain unverified. No
    live provider request was made.
-   Verification in this follow-up: `./scripts/verify-fast.sh` passed after
    running outside the command sandbox so Unix-domain socket tests could
    bind (20 headless scenarios, 176 Swift tests in 20 suites, and 21 Python
    tests); `CONFIGURATION=release ./scripts/build-app.sh` passed;
    `./scripts/verify-release.sh` passed for Inbetween 0.3.0 (3); and
    `git diff --check` passed. No real history, seeder, or unrelated running
    app was accessed or stopped.

### Native MenuBarExtra runtime verification retry (2026-10-17)

-   Re-inspected `InbetweenApp.body`, `MenuBarStatusView`, and lifecycle
    actions. The status scene uses `.menuBarExtraStyle(.window)`; its buttons
    open Overview, History, Reflection, or Settings in the separate Dashboard
    window, while Quit calls the normal termination path. The status view
    refreshes reliability status on appearance. The existing test command
    opens only the Dashboard window and does not activate the MenuBarExtra.
-   The desktop inventory contained no running uniquely identified disposable
    Inbetween process; only the unrelated `com.inbetween.launchprobe` process
    was listed. I did not target or stop it.
-   After rebuilding Release, made a full `ditto` copy of the built app at
    `/private/tmp/inbetween-popover-verify-20261017/Inbetween.app`, changed
    only the bundle identifier to
    `com.inbetween.popoververify20261017`, ad-hoc signed it, verified the
    signature, and supplied a separate disposable data directory. Launch
    Services again returned `-10827/kLSNoExecutableErr` before the app became
    a running process. The test status item therefore could not be exposed to
    Accessibility or inspected on screen.
-   No additional test-only popover activation hook was added: there was no
    running isolated MenuBarExtra to target, and a hook that merely opens a
    separate Dashboard window would repeat the existing non-proving path.
    The app code provides no supported programmatic presentation control for
    this native scene. No evidence establishes a runtime popover defect or an
    accessibility-only limitation. Opening, visible rendering, dismissal,
    and navigation through the actual popover remain unverified; there is no
    pass claim based on the dashboard command or accessibility press.
-   Verification for this retry: `./scripts/verify-fast.sh` passed (20
    scenarios, 176 Swift tests in 20 suites, 21 Python tests);
    `CONFIGURATION=release ./scripts/build-app.sh` passed;
    `./scripts/verify-release.sh` passed for Inbetween 0.3.0 (3); and
    `git diff --check` passed after this plan update.

### Existing-process MenuBarExtra verification assessment (2026-10-17)

-   Re-read `AGENTS.md` and this plan, then inspected the current
    `MenuBarExtra` scene and status content. The actual menu is present only
    while the app process is running. Its visible controls navigate to a
    separate Dashboard window, and the test-only commands also open that
    window; neither is a way to present or verify the native menu itself.
-   The current desktop app inventory contains no Inbetween process and no
    uniquely identified disposable status item. The only listed Inbetween-like
    process is `com.inbetween.launchprobe`, which is unrelated and was not
    targeted. Previously attempted status-item accessibility presses did not
    yield visible popover content.
-   In this run, I did not launch another bundle, interact with a normal
    Inbetween process, or inspect real history. There is therefore no safe
    live status item for the harness to inspect. The in-app source exposes no
    supported `MenuBarExtra` presentation binding; adding a Dashboard command
    or a mock would not exercise the actual popover. I made no production UI
    change or test hook that could not be validated against a running native
    status item.
-   Result: the actual MenuBarExtra cannot be reliably verified at runtime
    under the current process and launch constraints. Its open, render,
    dismiss, and navigation behavior remains **unverified**. This does not
    establish a popover defect or an accessibility-only limitation. A future
    runtime check requires an already-running disposable build whose status
    item can be identified and observed visibly; the ordinary app or the
    unrelated LaunchProbe is not a safe substitute.
-   No code changed in this assessment, so the prescribed code verification
    scripts were not rerun. `git diff --check` was run after this documentation
    update and passed. The immediately preceding retry records passing fast
    tests, release build, and release verification.

### Reflection request and suggestion repair (2026-10-17)

-   Traced the Reflection suggestion and typed-question paths through
    `ReflectionChatSection`, `LifecycleViewModel.sendReflectionQuestion`,
    `ReflectionConversationCoordinator`, and the HTTP provider. The confirmed
    request bug was in the suggestion button: it assigned the selected prompt
    to SwiftUI `@State` and synchronously called `submit()`, which read the old
    state value before the update became visible. It could submit an empty or
    stale question. Typed Send did not have that state-update race.
-   Suggestion buttons now pass their selected text directly to the shared
    submission helper. Suggestions are generated from snapshot evidence for
    observed focus, distraction, and context. Empty periods and periods with
    only unobserved time show a plain explanation instead. Prompts remain
    scoped to Today or This Week. No cross-day comparison suggestion is
    offered because this snapshot does not carry a sufficiently reliable
    observed-day mapping for that suggestion.
-   Updated the provider instructions to answer directly and concisely,
    distinguish recorded evidence from interpretation, acknowledge missing
    evidence, and never treat unobserved time as distraction or invent a goal,
    reason, activity, or comparison. Local metrics, evidence IDs, and session
    conversation handling remain in place.
-   No live provider request was made: no API key was configured in the
    available Keychain/environment. Consequently, live provider availability,
    error responses, and evidence navigation were not runtime-verified. The
    request construction, parsing, retry/error handling, local evidence and
    metric validation, and user-facing error copy were exercised through
    deterministic transport fixtures. No real history or app store was
    accessed or modified.
-   Verification: `swift test --filter ReflectionChatTests` passed (16 tests);
    `./scripts/verify-fast.sh` passed (20 headless scenarios, 181 Swift tests
    in 20 suites, and 23 Python tests); `CONFIGURATION=release
    ./scripts/build-app.sh` passed; `./scripts/verify-release.sh` passed for
    Inbetween 0.3.0 (3); and `git diff --check` passed. These checks establish
    build and automated contract behavior, not live provider or GUI behavior.

### Configured Featherless credential runtime check (2026-10-17)

-   Corrected the previous test-environment diagnosis: isolated UI mode
    intentionally injects `InMemoryAICredentialStore`, so its “Not configured”
    state did not establish that the user's Keychain item was absent. The new
    explicit `--inbetween-test-use-configured-keychain` argument opts an
    isolated run into the existing Keychain store. Its read uses
    `LAContext.interactionNotAllowed = true`; it does not write or delete the
    credential and cannot present an authentication prompt.
-   Built and launched `.build/apps/release/Inbetween.app` with its normal
    `com.inbetween.app` bundle identifier, the disposable store at
    `/private/tmp/inbetween-reflection-keychain-vSvIOe`, and the explicit
    noninteractive Keychain test flag. The test-only
    `--inbetween-test-open-reflection` argument opens the actual Dashboard
    Reflection view in a uniquely titled native window; Accessibility
    inspection visibly confirmed the Reflection window and its Settings
    navigation.
-   Settings remained at “Checking AI settings…” and showed “Not configured.”
    A short stack sample of only that disposable process showed its background
    task blocked inside `SecItemCopyMatching`, in Security's keychain item
    decrypt path and waiting for a `mach_msg` reply. The API returned no
    `OSStatus`, so this run cannot establish an absent item or a denied access
    result. The app binary reports identifier `com.inbetween.app`, an ad-hoc
    signature, no TeamIdentifier, and only the Apple Events automation
    entitlement. This does not establish that the existing item's access
    control rejects that signature; the failure was still pending inside the
    Keychain call. No credential content was logged, copied, or displayed, and
    no Keychain prompt was approved.
-   The saved model preference is `Qwen/Qwen2.5-7B-Instruct`. No
    `INBETWEEN_FEATHERLESS_BASE_URL` override was present in the launch
    environment; code resolves the endpoint to
    `https://api.featherless.ai/v1`. The app did not finish loading either
    value into its live Reflection configuration because the credential read
    did not return.
-   No provider request was sent. Therefore provider success and an answer
    displayed in Reflection remain unverified. The single authorized request
    was not attempted without a credential returned by the app. Real history
    was not accessed; only the one synthetic Xcode session in the disposable
    test store was available to the UI.
-   Verification: `./scripts/verify-fast.sh` passed (20 scenarios, 181 Swift
    tests in 20 suites, 25 Python tests); `CONFIGURATION=release
    ./scripts/build-app.sh` passed; `CONFIGURATION=release
    ./scripts/verify-release.sh` passed for Inbetween 0.3.0 (3); and
    `git diff --check` passed. SwiftPM was directed to a dedicated writable
    temporary module cache after its default `~/.cache/clang/ModuleCache`
    location was inaccessible.

### Keychain stall and live Reflection follow-up (2026-10-17)

-   The indefinite Settings state came from calling synchronous
    `SecItemCopyMatching` inside `Task.detached` without a deadline. Moving the
    call off the main actor prevented a frozen window but did not guarantee the
    Security call returned, so no success/error state was applied.
-   Read-only inspection of the `com.inbetween.app.featherless` generic-password
    item's ACL showed per-application code requirements and no explicit access
    group. At the time of the first comparison, the current ad-hoc debug and
    release signatures did not match the stored CDHash requirements, while
    older app copies were listed as trusted. This is consistent with an
    authorization handshake on rebuilt app binaries; it is not attributed to
    Keychain synchronization. A later read by the current release test process
    did succeed without a prompt, so the stale-signature observation alone does
    not explain every delay or establish a persistent denial.
-   Keychain reads now request noninteractive failure and race the synchronous
    Security operation against an eight-second deadline. A delayed result is
    discarded. Settings leaves “Checking AI settings…” and explains that the
    saved key was not changed and its Keychain access should be reviewed. The
    key-saving and removal paths were not invoked. A regression test verifies
    that a deliberately blocked credential provider returns the timeout
    without leaking its late value.
-   The isolated release app later visibly reported “Saved in Keychain” and
    loaded `Qwen/Qwen2.5-7B-Instruct`; the endpoint remained the Featherless
    default. Exactly one live request was sent with the disposable five-minute
    synthetic Xcode snapshot. Featherless returned a response, but it contained
    a numeric claim and the existing local validator correctly rejected it.
    Reflection displayed “Reflection couldn’t verify a numeric answer. Your
    local summary is still available.” No answer appeared. The provider response
    and credential were not logged or captured.
-   The system instructions now state explicitly that answer text must contain
    no digits, number words, dates, durations, counts, percentages, or numeric
    claims; numeric values remain local metrics. Evidence and numeric validation
    were not weakened. This prompt change has not yet been verified against the
    live provider. No second provider request was sent without approval.
-   Verification: `swift test --filter ReflectionChatTests` passed (17 tests,
    including the blocked-read timeout regression); `./scripts/verify-fast.sh`
    passed (20 scenarios, 182 Swift tests in 20 suites, 25 Python tests);
    `CONFIGURATION=release ./scripts/build-app.sh` and
    `CONFIGURATION=release ./scripts/verify-release.sh` passed for Inbetween
    0.3.0 (3). The combined command's first `git diff --check` found an extra
    blank line at EOF in `AICredentialStore.swift`; it was removed. A subsequent
    `git diff --check` passed, as did the final `./scripts/verify-release.sh`.

-   With the user's authorization for one additional request, the uniquely
    identified release test app was launched using the same disposable store
    and explicit configured-Keychain mode. Settings visibly confirmed “Saved in
    Keychain” and model `Qwen/Qwen2.5-7B-Instruct`; no credential value was
    exposed. One qualitative question was sent with the same synthetic Xcode
    snapshot. Reflection visibly rendered the answer “The activity was
    productive, focusing on work in Xcode.” The local Productive five-minute
    metric and a linked evidence control were also visible. This verifies
    credential retrieval, provider response, and answer display for this
    isolated end-to-end run. No further provider request was sent, and real
    history was not accessed.
-   The prompt constraint against numeric answer text resolved the specific
    numeric-validation failure observed in the prior live response. Verification
    commands were not rerun after this runtime-only check and documentation
    update; the code and release bundle were unchanged from the successful
    verification recorded above. `git diff --check` was rerun after this plan
    update and passed.

### Reflection numeric-answer recovery (2026-10-17)

-   A later user screenshot confirmed the numeric-answer warning still appeared
    for a subsequent response. The cause was the all-or-nothing response
    validator: it discarded the entire answer when any sentence contained a
    number, including otherwise useful qualitative sentences.
-   Validation now removes sentences containing unverified numeric claims,
    keeps any remaining qualitative sentences, and displays a brief note that
    the local summary contains the recorded figures. If no qualitative sentence
    remains, the note itself fills the answer slot. Numeric values continue to
    come only from locally calculated metrics, and evidence/metric validation
    is unchanged. No live provider request was sent for this fix.
-   `swift test --filter ReflectionChatTests` passed (17 tests), including
    numeric-only, mixed qualitative/numeric, and local metric-authority cases.
    `./scripts/verify-fast.sh` passed (20 scenarios, 182 Swift tests in 20
    suites, 25 Python tests). These checks used a dedicated temporary Swift
    module cache; the first sandboxed full-suite attempt could not bind its
    local Unix socket tests, which passed on the authorized rerun. Release
    packaging was not changed or rebuilt for this core response-handling fix.
