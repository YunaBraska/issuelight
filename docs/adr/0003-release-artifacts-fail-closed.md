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

The lower-level packaging entrypoint consumes an already built
`IssueLight.app`. It checks the bundle identifier, marketing version, build
number, `arm64` and `x86_64` executable, release layout, and secret-bearing file
types before creating a ZIP archive, SPDX 2.3 SBOM, and SHA-256 manifest.

The default mode requires Developer ID Application from the configured Apple
team, hardened runtime, a secure signature timestamp, no `get-task-allow`
entitlement, strict code-signature verification, a valid stapled notarization
ticket, and successful Gatekeeper assessment. An explicit `--allow-unsigned`
mode exists only to test packaging mechanics in CI and local development. Its
ZIP and SBOM names are visibly marked `UNSIGNED`, and its output is never a
publishable release.

`scripts/package.sh VERSION` is the canonical release orchestrator for local and
GitHub builds. It builds a universal app, signs it when a Developer ID identity
is supplied, rejects `get-task-allow`, notarizes and staples the app, hands that
same bundle to the lower-level packaging entrypoint, creates a DMG, and then
notarizes, staples, and assesses the DMG. The legacy local
`scripts/build_release.sh` command remains a thin compatibility wrapper that
enforces a clean declared revision and maps its Keychain profile inputs to the
canonical entrypoint.

The repository's release workflow delegates to a commit-pinned reusable macOS
workflow. That workflow imports release credentials into an ephemeral Keychain
and invokes the same `scripts/package.sh` entrypoint used locally. An unsigned
run exercises mechanics only and can never be published as a signed release.

Notarization credentials are referenced only by a Keychain profile name. The
script does not accept an Apple ID password or API private key on its command
line and does not write credentials into the repository or release output.

## Consequences

- CI can test the real archive, checksum, and SBOM path without pretending to
  have release authority.
- The publishable path fails rather than silently accepting an unsigned or
  unstapled app.
- Local and hosted release workflows share one credentialed implementation.
- ZIP and DMG artifacts come from the same verified app bundle and revision.
