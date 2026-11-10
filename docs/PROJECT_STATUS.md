# Project status

Status: Pre-release development. Not production-ready.

Snapshot date: 2026-11-10.

## Verified behavior

| Area | Evidence | Status |
| --- | --- | --- |
| Provider-neutral source records | Swift package tests for validation, encoding, and authority changes | Verified |
| Provider runtime boundary | Registry dispatches validation, connection testing, and snapshot loading without provider logic in app views | Verified in package and live tests |
| Icinga 2 endpoint rules | Provider and URL construction tests | Verified |
| Basic credentials | Real temporary macOS Keychain item lifecycle with cleanup | Verified locally |
| Client identities | PKCS#12 parsing and persistent-reference tests | Verified locally |
| Connection classification | Tests for success, cancellation, authentication, authorization, TLS, reachability, and incompatible responses | Verified |
| Monitoring snapshots | Provider-neutral host and service issues, severity, acknowledgement, downtime, and deterministic ordering | Verified in package tests |
| Snapshot transport | Shared connection and refresh transport, same-origin redirects, Basic auth, mTLS, and explicit failures | Verified in package and live tests |
| Source setup UI | Native SwiftUI app builds for macOS 14+ | Build verified |
| Attention UI | Native menu and status window for setup, loading, healthy, problem, failure, and stale states | Empty setup state inspected locally; remaining states need running-product inspection |
| Real Icinga 2 integration | Pinned official container lab covers Basic auth, permission denial, private CA, mTLS, and real host/service problem payloads | Verified locally |

The local package suite currently executes 31 tests. Three live Icinga tests
are skipped unless the integration environment is configured. The full live
matrix passed locally on 2026-11-10.

LLVM source coverage for `IssueLightCore` is currently 73.1% of lines and 64.5%
of regions. Swift does not report branch totals in this configuration. Coverage
is evidence, not a release gate yet, and remains below the project goals.

## Release blockers

- Refresh cancellation, replacement, stale retention, and source-removal behavior need automated app-level tests.
- Multiple sources are not manageable through the UI.
- Custom CA trust and certificate pinning are specified but not implemented.
- Keychain denial and revocation need installed-app evidence.
- Accessibility, localization, dark mode, failure/stale UI, large-data
  behavior, and energy use need running-product verification.
- Core coverage remains below the stated 95% line and 90% branch goals.
- Packaging, update behavior, Developer ID signing, notarization, stapling,
  checksums, SBOM, and clean-account installation are not implemented or proven.
- No release has completed the real GitHub distribution workflow.

Do not describe IssueLight as production-ready until these blockers are closed
or explicitly removed from the supported scope.
