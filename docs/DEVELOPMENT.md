# Development

## Repository layout

- `IssueLight/`: native macOS app and XcodeGen specification
- `Packages/IssueLightCore/`: provider-neutral domain and Icinga 2 adapter
- `integration/icinga2/`: real external-system test lab
- `docs/spec/`: accepted observable behavior
- `docs/adr/`: lasting architecture decisions

## Normal workflow

Run package tests first, then the app build. Live integration is separate so
ordinary unit work does not start Docker or modify Keychain identities.

```sh
swift test --package-path Packages/IssueLightCore
xcodebuild test -project IssueLight/IssueLight.xcodeproj \
  -scheme IssueLight -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild build -project IssueLight/IssueLight.xcodeproj \
  -scheme IssueLight -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Use a stable Apple Development identity and the fixed bundle identifier
`io.github.yunabraska.issuelight` for permission-sensitive installed-app tests.
Keep team identifiers and certificate fingerprints outside Git in ignored local
configuration.

See [`../integration/icinga2/README.md`](../integration/icinga2/README.md) for
the real Icinga compatibility matrix.

## Release-candidate packaging

The packaging entrypoint accepts an already built app. It verifies the bundle
identifier, marketing version, positive build number, universal `arm64` and
`x86_64` executable, release layout, and forbidden secret-bearing file types.
It writes a ZIP archive, an SPDX 2.3 SBOM, and verified SHA-256 checksums
without changing the app bundle.

For a local unsigned pipeline check, use an isolated output directory:

```sh
issuelight_derived_data=$(mktemp -d /tmp/issuelight-derived.XXXXXX)
issuelight_release_output=$(mktemp -d /tmp/issuelight-release.XXXXXX)
issuelight_revision=$(git rev-parse HEAD)
xcodebuild build \
  -project IssueLight/IssueLight.xcodeproj \
  -scheme IssueLight \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$issuelight_derived_data" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO
issuelight_app="$issuelight_derived_data/Build/Products/Release/IssueLight.app"
issuelight_version=$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleShortVersionString' \
  "$issuelight_app/Contents/Info.plist")
scripts/package_release.sh \
  "$issuelight_app" \
  "$issuelight_release_output" \
  "$issuelight_version" \
  "$issuelight_revision" \
  --allow-unsigned
```

The `--allow-unsigned` mode is only a packaging test, marks its ZIP and SBOM
filenames with `UNSIGNED`, and cannot produce a publishable release. Without
that flag, packaging requires Developer ID
Application from the `APPLE_TEAM_ID` configured in ignored local settings,
hardened runtime, strict signature verification, a stapled notarization ticket,
and successful Gatekeeper assessment. Developer ID signing and notarization
remain a separate release step and require the ignored local variables
described above.
