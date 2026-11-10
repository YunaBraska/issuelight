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
| Private CA trust | PEM/DER import, Keychain persistent reference, source-specific Apple trust evaluation, hostname checks, accepted lab CA, rejected unrelated CA, and ownership-aware cleanup after the final source reference | Verified in package, app-model, and live tests |
| Connection classification | Tests for success, cancellation, authentication, authorization, TLS, reachability, and incompatible responses | Verified |
| Monitoring snapshots | Provider-neutral host and service issues, severity, acknowledgement, downtime, and deterministic ordering | Verified in package tests |
| Snapshot transport | Shared connection and refresh transport, same-origin redirects, Basic auth, mTLS, and explicit failures | Verified in package and live tests |
| Refresh lifecycle | Initial and manual refresh per enabled source, isolated replacement cancellation, stale retention, and source removal | Verified in app-model tests |
| Multiple-source runtime | Independent credentials, refresh tasks, failure state, disable behavior, snapshots, and aggregate issue ordering | Verified in app-model tests through persisted sources and real Keychain scopes |
| Source persistence permissions | Atomic JSON writes containing no secrets, restricted to the local user with mode `0600` | Verified in package and app-model tests |
| Privacy boundary | Direct source connections, no telemetry SDK, ephemeral network sessions, in-memory snapshots, documented local storage and deletion behavior | Verified in source and `PRIVACY.md` |
| Source setup UI | Native sidebar supports add, select, edit, disable, test, remove, private-CA import, and explicit insecure trust with unsaved-change protection | Real success, validation failure, insecure warning, private-CA import, unrelated-CA TLS failure, saved-source, and persistent action-feedback states inspected locally |
| Attention UI | Native menu and status window for setup, loading, healthy, problem, failure, and stale states | Empty setup and real six-problem Icinga states inspected locally; remaining states need running-product inspection |
| Real Icinga 2 integration | Pinned official container lab covers Basic auth, permission denial, private CA, mTLS, real host/service problem payloads, and two persisted app-model sources | Verified locally |
| OSS repository controls | Apache-2.0, provenance notice, contributor/security/privacy policies, private vulnerability reporting, secret scanning with push protection, SHA-pinned Actions, and protected `main` | Verified in the public repository |

The local package suite currently executes 41 tests. Five live Icinga tests
are skipped unless the integration environment is configured. The app suite
executes eleven deterministic model tests and one live integration test, skipped
outside the lab. It exercises multiple-source management and refresh isolation
through persisted source, real Keychain, and real Icinga 2 boundaries. The full
live matrix passed locally on 2026-11-10.

LLVM source coverage for `IssueLightCore` is currently 74.3% of lines and 65.6%
of regions. Swift does not report branch totals in this configuration. Coverage
is evidence, not a release gate yet, and remains below the project goals.

## Release blockers

- Certificate pinning and reviewed rotation are specified but not implemented.
- Keychain denial and revocation need installed-app evidence.
- Multiple-source navigation, complete keyboard and accessibility behavior,
  localization, dark mode, failure/stale UI, large-data behavior, and energy
  use need running-product verification.
- Core coverage remains below the stated 95% line and 90% branch goals.
- Packaging, update behavior, Developer ID signing, notarization, stapling,
  checksums, a release-artifact SBOM, and clean-account installation are not
  implemented or proven.
- No release has completed the real GitHub distribution workflow.

Do not describe IssueLight as production-ready until these blockers are closed
or explicitly removed from the supported scope.
