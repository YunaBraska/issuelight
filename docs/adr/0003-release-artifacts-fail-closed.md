# ADR 0003: Release Artifacts Fail Closed

Status: Accepted.

Date: 2026-11-10.

## Context

A successful Xcode build is not a distributable macOS release. A published app
must have the expected identity and architectures, survive archive extraction,
carry a Developer ID signature, contain a stapled notarization ticket, pass
Gatekeeper assessment, and ship with independently verifiable provenance.

CI cannot prove the final security boundary without access to release signing
and notarization credentials. Treating an ad-hoc or unsigned build as a release
would make a green pipeline misleading.

## Decision

One packaging entrypoint consumes an already built `IssueLight.app`. It checks
the bundle identifier, marketing version, build number, `arm64` and `x86_64`
executable, release layout, and secret-bearing file types before creating a ZIP
archive, SPDX 2.3 SBOM, and SHA-256 manifest.

The default mode requires Developer ID Application from the configured Apple
team, hardened runtime, a secure signature timestamp, no `get-task-allow`
entitlement, strict code-signature verification, a valid stapled notarization
ticket, and successful Gatekeeper assessment. An explicit `--allow-unsigned`
mode exists only to test packaging mechanics in CI and local development. Its
ZIP and SBOM names are visibly marked `UNSIGNED`, and its output is never a
publishable release.

Developer ID signing and notarization stay outside the packaging script. The
credential-bound `scripts/build_release.sh` entrypoint owns that workflow. It
requires a clean checkout at the declared revision, builds a universal app
with the configured Developer ID identity, rejects `get-task-allow`, submits a
ZIP through `notarytool`, retrieves the completed log, and accepts only an
`Accepted` submission with no reported issues. It then staples the app, runs
Gatekeeper assessment, and hands the same app to the packaging entrypoint.

Notarization credentials are referenced only by a Keychain profile name. The
script does not accept an Apple ID password or API private key on its command
line and does not write credentials into the repository or release output.

## Consequences

- CI can test the real archive, checksum, and SBOM path without pretending to
  have release authority.
- The publishable path fails rather than silently accepting an unsigned or
  unstapled app.
- The credentialed release workflow has one entrypoint and one final artifact
  boundary to sign, notarize, package, and verify.
