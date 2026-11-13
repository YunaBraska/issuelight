# Project status

Status: Pre-release development. Not production-ready.

Snapshot date: 2026-11-13.

## Verified behavior

| Area | Evidence | Status |
| --- | --- | --- |
| Provider-neutral source records | Swift package tests for validation, encoding, and authority changes | Verified |
| Provider runtime boundary | Registry dispatches validation, credential and trust resolution, connection testing, and snapshot loading without provider logic in app views | Verified in package and live tests |
| Icinga 2 endpoint rules | Provider and URL construction tests | Verified |
| Basic credentials | Real temporary macOS Keychain item lifecycle with cleanup; an installed Developer-ID-signed app stored and read a scoped password, detected its exact external revocation on manual refresh, retained the prior snapshot as stale, and failed explicitly after relaunch | Verified locally |
| Client identities | PKCS#12 parsing and persistent-reference tests | Verified locally |
| Private CA trust | PEM/DER import, Keychain persistent reference, source-specific Apple trust evaluation, hostname checks, accepted lab CA, rejected unrelated CA, and ownership-aware cleanup after the final source reference | Verified in package, app-model, and live tests |
| Exact server-certificate pinning | PEM/DER leaf selection, normalized SHA-256 persistence, source-specific Apple trust evaluation, authority-change reset, accepted exact lab leaf, rejected mismatched leaf, and rejected hostname mismatch | Verified in package, app-model, and live tests |
| Connection classification | Tests for success, cancellation, authentication, authorization, TLS, reachability, and incompatible responses | Verified |
| Monitoring snapshots | Provider-neutral host and service issues, severity, acknowledgement, downtime, and deterministic ordering | Verified in package tests |
| Snapshot transport | Shared connection and refresh transport, same-origin redirects, Basic auth, mTLS, and explicit failures | Verified in package and live tests |
| Large provider payload | 5,000 synthetic Icinga service problems traverse request handling, JSON decoding, provider-neutral mapping, and deterministic sorting under a five-second regression limit; the local coverage build completed in 52 ms or less | Verified at the Core adapter boundary; running UI volume remains open |
| Refresh lifecycle | Initial and manual refresh per enabled source, isolated replacement cancellation, stale retention, and source removal | Verified in app-model tests |
| Multiple-source runtime | Independent credentials, refresh tasks, failure state, disable behavior, snapshots, and aggregate issue ordering | Verified in app-model tests through persisted sources and real Keychain scopes |
| Source persistence | Atomic JSON writes containing no secrets, restricted to the local user with mode `0600`; malformed and duplicate source records fail explicitly | Verified in package and app-model tests |
| Privacy boundary | Direct source connections, no telemetry SDK, ephemeral network sessions, in-memory snapshots, documented local storage and deletion behavior | Verified in source and `PRIVACY.md` |
| Source setup UI | Native sidebar supports add, select, edit, disable, test, remove, private-CA import, exact server-certificate pinning, and explicit insecure trust with unsaved-change protection | Real success, validation failure, insecure warning, private-CA import, accepted exact pin, rejected mismatched pin, unrelated-CA TLS failure, saved-source, two-source keyboard navigation, long accessible labels, unsaved-change protection, persistent action-feedback states, and the installed dark-mode surface inspected locally |
| Attention UI | Native menu and status window for setup, loading, healthy, problem, failure, stale, and all-paused states | Empty setup, deterministic two-problem Icinga status, failure with retained stale data, explicit installed-app password-revocation and relaunch failures, accessible source error, recovery, and all-paused status inspected locally; German zero, singular, and plural issue counts are regression-tested; the status window was inspected at a larger supported size and in dark mode |
| Real Icinga 2 integration | Isolated pinned official container lab covers Basic auth, permission denial, private CA, mTLS, exact real host/service problem payloads, stable initial checks, and two persisted app-model sources | Verified locally |
| OSS repository controls | Apache-2.0, provenance notice, contributor/security/privacy policies, private vulnerability reporting, secret scanning with push protection, SHA-pinned Actions, required CI and Swift CodeQL, and protected `main` | Verified in the public repository; the first 27-rule Swift scan completed with zero results and zero open alerts |
| Release-candidate artifacts | Universal Developer ID build, hardened runtime, timestamp, fail-closed notarization, ZIP, SPDX 2.3 SBOM, and verified SHA-256 manifest | Unsigned path verified locally and in CI; real universal Developer ID signing passes locally; Gatekeeper and packaging reject the unnotarized app; an accepted notarization remains open |

The local package suite currently executes 67 tests. Fifty-nine deterministic
tests pass, while eight live Icinga tests are skipped unless the integration
environment is configured. The app suite executes sixteen deterministic tests
and one live integration test, skipped outside the lab. It exercises
multiple-source management and refresh isolation through persisted source,
real Keychain, and real Icinga 2 boundaries. The full live matrix passed locally
on 2026-11-10.

Source-only LLVM coverage for `IssueLightCore` is currently 80.1% of lines and
72.7% of regions locally. CI enforces floors of 79.5% and 72% respectively so
the verified baseline cannot silently regress. Swift does not report branch
totals in this configuration. Coverage remains below the project goals.

## Release blockers

- Keychain access denial still needs installed-app evidence. Exact password
  revocation is verified in an installed Developer-ID-signed app.
- Complete keyboard and accessibility behavior, localization, healthy UI,
  large-data UI behavior, and energy use need running-product
  verification.
- Core coverage remains below the stated 95% line and 90% branch goals.
- Update behavior, accepted notarization, stapling, and clean-account
  installation are not proven.
- No release has completed the real GitHub distribution workflow.

Do not describe IssueLight as production-ready until these blockers are closed
or explicitly removed from the supported scope.
