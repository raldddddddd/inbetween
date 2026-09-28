# Personal Release Guide

Consult this specialized guide only for release, signing, notarization, or
installation work. It supports personal installation first; it does not add an
updater, a store submission, or any network service.

## Release identity and versioning

- App name: `Inbetween`
- Bundle identifier: `com.inbetween.app`
- Minimum macOS version: 13.0
- Menu-bar-only behavior: `LSUIElement=true`
- Version source of truth: `Support/Inbetween-Info.plist`

Before each release, update `CFBundleShortVersionString` for the human-facing
version and increment `CFBundleVersion` for every build. Keep the release notes
under `CHANGELOG.md` in sync. Do not change the bundle identifier: local app
data, notifications, and Launch at Login rely on the established identity.

## Build and verify

For ordinary implementation work, run the fast, headless verification workflow:

```sh
./scripts/verify-fast.sh
```

Before treating a current build as release-complete, or after changing packaging,
signing, entitlements, or release scripts, run the complete workflow:

```sh
./scripts/verify-full.sh
```

It runs all headless scenarios and test suites once, then creates the debug and
release bundles. It verifies release metadata, `LSUIElement`, entitlements, and
the strict code signature before copying the release bundle to an isolated
temporary Applications directory for the clean-install check. Use the
standalone build and verification scripts only when diagnosing an individual
packaging step.

The release bundle is written to `.build/apps/release/Inbetween.app`. The
verification checks the bundle layout, identifier, version fields,
`LSUIElement`, and strict code-signature validity. The clean-install check
copies the finished bundle to a new temporary Applications directory before
running the same verification there; it does not modify the real Applications
folder or user data.

For a final personal smoke test, copy the bundle to `/Applications`, launch it,
and confirm the menu-bar item, lifecycle-hook reception, automatic wait capture,
Ready notification, Launch at Login toggle, and Quit action. For a truly
fresh-user test, use a separate macOS account; do not fabricate past wait
activity.

## Signing strategy

The build script uses an ad-hoc signature when `CODE_SIGN_IDENTITY` is omitted.
That is appropriate for the development Mac but is not a distributable identity.

For another Mac, use a Developer ID Application certificate from the intended
Apple Developer team:

```sh
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  CONFIGURATION=release ./scripts/build-app.sh
./scripts/verify-release.sh
```

The Developer ID path enables the hardened runtime and timestamp. Keep the
private certificate in the macOS keychain; do not put it, a team ID, or an Apple
ID password in this repository. The build also applies the narrowly scoped
Apple Events automation entitlement required for optional browser-tab metadata;
macOS still asks the user before Inbetween may query each supported browser.

## Notarization plan

Notarization is unnecessary when the app stays on its development Mac. Before
sharing a Developer ID-signed build outside that Mac:

1. Archive the verified `Inbetween.app` as a ZIP while preserving its bundle.
2. Submit that archive using `xcrun notarytool` with credentials stored in a
   keychain profile, not in shell history or source control.
3. Wait for an accepted result, staple the notarization ticket to the app, and
   run `spctl --assess --type execute --verbose=4 Inbetween.app`.
4. Repeat the clean-install test using the stapled app on a Mac that has not
   previously run it.

There is intentionally no automated notarization command here: account
credentials and the developer team are personal release inputs, not project
configuration.
