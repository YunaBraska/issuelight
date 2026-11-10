# Project status

Status: Pre-release development. Not production-ready.

Snapshot date: 2026-11-10.

## Verified behavior

| Area | Evidence | Status |
| --- | --- | --- |
| Provider-neutral source records | Swift package tests for validation, encoding, and authority changes | Verified |
| Icinga 2 endpoint rules | Provider and URL construction tests | Verified |
| Basic credentials | Real temporary macOS Keychain item lifecycle with cleanup | Verified locally |
| Client identities | PKCS#12 parsing and persistent-reference tests | Verified locally |
| Connection classification | Tests for success, cancellation, authentication, authorization, TLS, reachability, and incompatible responses | Verified |
| Source setup UI | Native SwiftUI app builds for macOS 14+ | Build verified |
| Real Icinga 2 integration | Pinned official container lab covers Basic auth, permission denial, private CA, and mTLS | Available, requires Docker and local lab secrets |

The local package suite currently executes 23 tests. Two live Icinga tests are
skipped unless the integration environment is configured.

## Release blockers

- No attention-first monitoring snapshot or background refresh is shipped.
- Multiple sources are not manageable through the UI.
- Custom CA trust and certificate pinning are specified but not implemented.
- Keychain denial and revocation need installed-app evidence.
- Accessibility, localization, dark mode, large-data behavior, energy use, and
  notification journeys need running-product verification.
- Packaging, update behavior, Developer ID signing, notarization, stapling,
  checksums, SBOM, and clean-account installation are not implemented or proven.
- No release has completed the real GitHub distribution workflow.

Do not describe IssueLight as production-ready until these blockers are closed
or explicitly removed from the supported scope.
