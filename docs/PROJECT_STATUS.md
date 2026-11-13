# Project status

Status: Release-candidate engineering. Not publicly production-ready.

Snapshot date: 2026-11-13.

## Verified behavior

| Area | Evidence | Status |
| --- | --- | --- |
| Provider-neutral source records | Swift package tests for validation, encoding, and authority changes | Verified |
| Provider runtime boundary | Registry dispatches validation, credential and trust resolution, connection testing, and snapshot loading without provider logic in app views | Verified in package and live tests |
| Icinga 2 endpoint rules | Provider and URL construction tests | Verified |
| Basic credentials | Real temporary macOS Keychain item lifecycle with cleanup; ownership is identified through non-secret metadata; a foreign legacy item with an incompatible application partition is rejected before its secret is read; an installed Developer-ID-signed app stored and read a scoped password, detected its exact external revocation on manual refresh, retained the prior snapshot as stale, and failed explicitly after relaunch | Verified locally |
| Non-interactive background credentials | Password availability reads only metadata; password and exact client-identity reads use `LAContext.interactionNotAllowed`; broad identity searches skip protected items instead of opening authentication UI | Partial. Password and identity lookup behavior is verified. Protected-private-key signing remains blocked because the available Apple Development key requires an unknown login-Keychain approval; experimental approaches were rejected after they opened the system authentication dialog |
| Client identities | Generated PKCS#12 import, real Keychain listing, persistent-reference resolution, exact cleanup, and malformed-import rejection | Verified locally |
| Private CA trust | PEM/DER import, Keychain persistent reference, source-specific Apple trust evaluation, hostname checks, accepted lab CA, rejected unrelated CA, and ownership-aware cleanup after the final source reference | Verified in package, app-model, and live tests |
| Exact server-certificate pinning | PEM/DER leaf selection, normalized SHA-256 persistence, source-specific Apple trust evaluation, authority-change reset, accepted exact lab leaf, rejected mismatched leaf, and rejected hostname mismatch | Verified in package, app-model, and live tests |
| Connection classification | Tests for success, cancellation, authentication, authorization, TLS, reachability, non-HTTP responses, and incompatible responses | Verified |
| Monitoring snapshots | Provider-neutral host and service issues, severity, acknowledgement, downtime, stable identity, deterministic ordering, and explicit rejection of unsupported provider objects and states | Verified in package tests |
| Snapshot transport | Shared connection and refresh transport, same-origin redirects, Basic auth, mTLS, and explicit failures | Verified in package and live tests |
| Large provider payload | 5,000 synthetic Icinga service problems traverse request handling, JSON decoding, provider-neutral mapping, deterministic sorting, search, and a native production-view window under five-second regression limits | Verified at the Core adapter and native SwiftUI boundaries; the inspected 760×560 window rendered without visible layout defects, and repeated full-list searches completed below 100 ms including test overhead |
| Refresh lifecycle | Initial and manual refresh per enabled source, isolated replacement cancellation, stale retention, and source removal | Verified in app-model tests |
| Multiple-source runtime | Independent credentials, refresh tasks, failure state, disable behavior, snapshots, and aggregate issue ordering | Verified in app-model tests through persisted sources and real Keychain scopes |
| Source persistence | Atomic JSON writes containing no secrets, restricted to the local user with mode `0600`; malformed and duplicate source records fail explicitly | Verified in package and app-model tests |
| Privacy boundary | Direct source connections, no telemetry SDK, ephemeral network sessions, in-memory snapshots, documented local storage and deletion behavior | Verified in source and `PRIVACY.md` |
| Source setup UI | Native sidebar supports add, select, edit, disable, test, remove, private-CA import, exact server-certificate pinning, and explicit insecure trust with unsaved-change protection | Real success, validation failure, insecure warning, private-CA import, accepted exact pin, rejected mismatched pin, unrelated-CA TLS failure, saved-source, two-source keyboard navigation, long accessible labels, unsaved-change protection, persistent action-feedback states, and the installed dark-mode surface inspected locally |
| Attention UI | Native menu and status window for setup, loading, healthy, problem, failure, stale, and all-paused states, with direct setup recovery and local issue search | Empty setup with its direct action, deterministic two-problem Icinga status, failure with retained stale data, explicit installed-app password-revocation and relaunch failures, accessible source error, recovery, and all-paused status inspected locally; production-view rendering now also covers a 5,000-row multi-source window and search across object and source text |
| Visible-status idle cost | Native production status window held with 5,000 issues | Partial. Five five-second samples after initial rendering reported 0.0% CPU, 0.0 `top` power score, and 37 MB resident memory; the full app refresh loop still needs an installed-app energy trace |
| Release identity and manual update journey | Own asset-catalog icon, German bundle region, native About panel, installed version/build, and explicit link to the official release channel without an automatic network check | Universal bundle metadata, icon renditions, running menu, About panel, and isolated first-run source window inspected locally |
| Real Icinga 2 integration | Isolated pinned official container lab covers Basic auth, permission denial, private CA, mTLS, exact real host/service problem payloads, stable initial checks, and two persisted app-model sources | Verified locally |
| OSS repository controls | Apache-2.0, provenance notice, contributor/security/privacy policies, private vulnerability reporting, secret scanning with push protection, SHA-pinned Actions, required CI and Swift CodeQL, and protected `main` | Verified in the public repository; the first 27-rule Swift scan completed with zero results and zero open alerts |
| Release-candidate artifacts | Universal Developer ID build, hardened runtime, timestamp, fail-closed notarization, ZIP, SPDX 2.3 SBOM, verified SHA-256 manifest, and a release configuration without coverage instrumentation | Unsigned path verified locally and in CI; real universal Developer ID signing passes locally; Gatekeeper and packaging reject the unnotarized app; an accepted notarization remains open |

The local package suite currently executes 91 tests. Eighty-three deterministic
tests pass, while eight live Icinga tests are skipped unless the integration
environment is configured. The app suite executes nineteen deterministic tests
and one live integration test, skipped outside the lab. It exercises
multiple-source management and refresh isolation through persisted source,
real Keychain, and real Icinga 2 boundaries. The full live matrix passed locally
on 2026-11-13 after the Keychain ownership change.

Source-only LLVM coverage for `IssueLightCore` is currently 86.8% of lines and
79.9% of regions locally. CI enforces floors of 86.0% and 79.0% respectively so
the verified baseline cannot silently regress. Swift does not report branch
totals in this configuration. Coverage remains below the project goals. The
goals are not an automatic release gate, but uncovered reachable behavior
remains a quality risk and must not include an accepted security or lifecycle
requirement.

## Release blockers

- A protected client-identity private key still needs installed-app evidence
  that background signing fails without authentication UI. The local Apple
  Development key currently blocks signing behind a login-Keychain dialog whose
  password is unavailable. No dialog-dependent implementation was retained.
- Search and realistic-volume rendering are verified in a running native
  production-view window. Installed-app keyboard interaction and a full refresh-
  loop energy trace remain open because native UI control and the required
  signing-key approval are unavailable in this environment.
- The 5,000-row offscreen test triggers a macOS 27 SwiftUI `List` warning about
  reentrant `NSTableView` delegate work. The view remains correct and the test
  passes, but an installed-app run must establish whether this is limited to the
  XCTest host before a future macOS version turns the warning into an assertion.
- Accepted notarization, stapling, and clean-account installation are not
  proven. The update journey is manual and verified by design.
- No release has completed the real GitHub distribution workflow.

Do not describe IssueLight as production-ready until these blockers are closed
or explicitly removed from the supported scope.
