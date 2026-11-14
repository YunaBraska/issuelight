# Development

## Repository layout

- `IssueLight/`: native macOS app and XcodeGen specification
- `Packages/IssueLightCore/`: provider-neutral domain and Icinga 2 adapter
- `integration/icinga2/`: real external-system test lab
- `docs/spec/`: accepted observable behavior
- `docs/adr/`: lasting architecture decisions

## Normal workflow

Run the repository check before publishing a change. It validates shell syntax,
Core behavior and coverage, app behavior, a universal Release build, unsigned
ZIP/DMG/SBOM/checksum packaging, negative release paths, secrets, and whitespace.

```sh
sh scripts/check.sh
```

Live integration remains separate so ordinary checks do not start Docker or
import test client identities. See
[`../integration/icinga2/README.md`](../integration/icinga2/README.md) for the
real Icinga compatibility matrix.

Use a stable Apple Development identity and the fixed bundle identifier
`berlin.yuna.issuelight` for permission-sensitive installed-app tests.
Keep team identifiers and certificate fingerprints outside Git in ignored local
configuration.

## Protected mTLS acceptance

Use a separate macOS review account and the lab identity. In Keychain Access,
open the imported identity's private key and set Access Control to require
confirmation without adding IssueLight to the always-allowed applications.
Install the stable signed app, configure the mTLS source, and run these checks:

1. Start **Test Connection** and approve the macOS prompt. The test must pass.
2. Leave Settings and wait for background refresh. No prompt may appear. The
   previous snapshot must remain visible as stale with an explicit credential
   failure.
3. Start **Test Connection** again and deny the prompt. The test must fail
   explicitly. Approving a subsequent attempt must recover the source.

Do not enter a login-Keychain password into a test command or the repository.
Automated identity and CA tests use isolated temporary Keychains and must not
display authentication UI.

## Product-site screenshots

The landing-page screenshots are rendered from the production SwiftUI views
with deterministic monitoring data. They do not start Icinga, read Keychain,
or write application state.

```sh
scripts/generate_site_screenshots.sh
```

The script builds the screenshot test in an isolated temporary Derived Data
directory and updates `docs/site/assets/screenshots/`. Inspect the normal menu,
German and Swedish panels, and the Arabic right-to-left variants before
committing them.

## Coverage ratchet

CI exports source-only LLVM coverage after the Core tests and requires at least
86.0% line coverage and 79.0% region coverage. Test sources and Swift build output
are excluded. These floors prevent regression from the verified baseline; they
do not replace the project goals of 95% reachable line coverage and 90% branch
coverage.

Run the same check locally after a coverage-enabled test run:

```sh
swift test --package-path Packages/IssueLightCore --enable-code-coverage
coverage_path=$(swift test \
  --package-path Packages/IssueLightCore \
  --show-codecov-path)
coverage_profile="$(dirname "$coverage_path")/default.profdata"
test_binary=$(find Packages/IssueLightCore/.build -type f \
  -path '*/IssueLightCore*Tests.xctest/Contents/MacOS/IssueLightCore*Tests' \
  -print -quit)
coverage_json=$(mktemp /tmp/issuelight-coverage.XXXXXX)
xcrun llvm-cov export "$test_binary" \
  -instr-profile="$coverage_profile" \
  -ignore-filename-regex='Tests/|\.build/' \
  -summary-only >"$coverage_json"
scripts/check_coverage.sh "$coverage_json" 86.0 79.0
rm -f "$coverage_json"
```

## Release-candidate packaging

`scripts/package.sh VERSION` is the canonical local and CI release entrypoint.
It builds a universal app and verifies its bundle identifier, version, positive
build number, architectures, layout, and forbidden secret-bearing file types.
It writes a ZIP, DMG, SPDX 2.3 SBOM, and verified SHA-256 checksums.

For a local unsigned pipeline check, use an isolated output directory:

```sh
issuelight_release_output=$(mktemp -d /tmp/issuelight-release.XXXXXX)
ISSUELIGHT_DIST_DIRECTORY="$issuelight_release_output" \
  scripts/package.sh 0.1.0-SNAPSHOT
```

The unsigned mode is only a packaging test, marks its ZIP, DMG, and SBOM
filenames with `UNSIGNED`, and cannot produce a publishable release. The signed
path requires Developer ID Application, hardened runtime, a secure timestamp,
no `get-task-allow` entitlement, accepted notarization, stapling, and successful
Gatekeeper assessment for both the app and DMG.

Release configuration disables code-coverage instrumentation. Coverage is a
test concern and must not add profiling runtime work to the distributed app.

## Credentialed release

The GitHub `release.yml` workflow reuses the same commit-pinned release workflow
as the maintainer's other macOS products. Configure these IssueLight repository
secrets before dispatching it:

- `MACOS_SIGNING_CERTIFICATE`
- `MACOS_SIGNING_CERTIFICATE_PASSWORD`
- `MACOS_NOTARY_KEY`
- `MACOS_NOTARY_KEY_ID`
- `MACOS_NOTARY_ISSUER_ID`

GitHub secrets are write-only. Values stored in another repository cannot be
copied out by a workflow or maintainer command.

For a local release, store notarization credentials once in the login Keychain
with `xcrun notarytool store-credentials`. Do not put the Apple ID password or
App Store Connect private key in this repository or on a command line. Keep the
selected profile name in ignored local configuration.

The release entrypoint requires these environment variables:

- `APPLE_TEAM_ID`: the 10-character team that owns the release identity
- `APPLE_SIGNING_IDENTITY`: the full Developer ID Application identity name
- `NOTARY_KEYCHAIN_PROFILE`: the profile created by `notarytool`

Run it only from a clean checkout. The revision argument must equal `HEAD`, and
the output directory must be absolute:

```sh
issuelight_revision=$(git rev-parse HEAD)
APPLE_TEAM_ID=YOURTEAMID \
APPLE_SIGNING_IDENTITY='Developer ID Application: Your Name (YOURTEAMID)' \
NOTARY_KEYCHAIN_PROFILE=issuelight-notary \
scripts/build_release.sh /absolute/release/output "$issuelight_revision"
```

The compatibility wrapper delegates to `scripts/package.sh`, which builds and
timestamps a universal Developer ID app with hardened runtime, rejects
`get-task-allow`, submits the app and DMG with `notarytool`, requires accepted
results, staples and validates tickets, runs Gatekeeper assessment, and creates
the final ZIP, DMG, SBOM, and checksums. See
[Apple's notarization workflow](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
for the platform requirements.
