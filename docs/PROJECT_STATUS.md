# Project status

Status: Release-candidate engineering. Not publicly production-ready.

Snapshot date: 2026-11-14.

## Verified behavior

| Area | Evidence | Status |
| --- | --- | --- |
| Provider-neutral source records | Swift package tests for validation, encoding, and authority changes | Verified |
| Provider runtime boundary | Registry dispatches validation, credential and trust resolution, connection testing, and snapshot loading without provider logic in app views | Verified in package and live tests |
| Icinga 2 endpoint rules | Provider and URL construction tests | Verified |
| Basic credentials | Real temporary macOS Keychain item lifecycle with cleanup; ownership is identified through non-secret metadata; a foreign legacy item with an incompatible application partition is rejected before its secret is read; an installed Developer-ID-signed app stored and read a scoped password, detected its exact external revocation on manual refresh, retained the prior snapshot as stale, and failed explicitly after relaunch | Verified locally without reading or modifying the user's login-Keychain passwords |
| Non-interactive background credentials | Password availability reads only metadata; password and exact client-identity reads use `LAContext.interactionNotAllowed`; broad identity searches skip protected items instead of opening authentication UI; automated password tests use an isolated temporary Keychain and identity tests skip when the login Keychain is locked | Partial. Normal and locked-Keychain lookup behavior is verified without an authentication dialog. Protected-private-key signing still needs deterministic installed-app denial evidence |
| Client identities | Generated PKCS#12 import, real Keychain listing, persistent-reference resolution, exact cleanup, and malformed-import rejection | Verified locally |
| Private CA trust | PEM/DER import, Keychain persistent reference, source-specific Apple trust evaluation, hostname checks, accepted lab CA, rejected unrelated CA, and ownership-aware cleanup after the final source reference | Verified in package, app-model, and live tests |
| Exact server-certificate pinning | PEM/DER leaf selection, normalized SHA-256 persistence, source-specific Apple trust evaluation, authority-change reset, accepted exact lab leaf, rejected mismatched leaf, and rejected hostname mismatch | Verified in package, app-model, and live tests |
| Connection classification | Tests for success, cancellation, authentication, authorization, TLS, reachability, non-HTTP responses, and incompatible responses | Verified |
| Monitoring snapshots | Provider-neutral host and service issues, severity, acknowledgement, downtime, stable identity, deterministic ordering, and explicit rejection of unsupported provider objects and states | Verified in package tests |
| Snapshot transport | Shared connection and refresh transport, same-origin redirects, Basic auth, mTLS, and explicit failures | Verified in package and live tests |
| Large provider payload | 5,000 synthetic Icinga service problems traverse request handling, JSON decoding, provider-neutral mapping, deterministic sorting, search, and a native production-view window under five-second regression limits | Verified at the Core adapter and native SwiftUI boundaries; the lazy production view rendered in 0.584 seconds on the local reference machine without the former `NSTableView` reentrancy warning, and repeated full-list searches completed below 100 ms including test overhead |
| Refresh lifecycle | Initial and manual refresh per enabled source, isolated replacement cancellation, stale retention, and source removal | Verified in app-model tests |
| Multiple-source runtime | Independent credentials, refresh tasks, failure state, disable behavior, snapshots, and aggregate issue ordering | Verified in app-model tests through persisted sources and real Keychain scopes |
| Source persistence | Atomic JSON writes containing no secrets, restricted to the local user with mode `0600`; malformed and duplicate source records fail explicitly | Verified in package and app-model tests |
| Privacy boundary | Direct source connections, no telemetry SDK, ephemeral network sessions, in-memory snapshots, documented local storage and deletion behavior | Verified in source and `PRIVACY.md` |
| Source setup UI | Native sidebar supports add, select, edit, disable, test, remove, private-CA import, exact server-certificate pinning, and explicit insecure trust with unsaved-change protection | Real success, validation failure, insecure warning, private-CA import, accepted exact pin, rejected mismatched pin, unrelated-CA TLS failure, saved-source, two-source keyboard navigation, long accessible labels, unsaved-change protection, persistent action-feedback states, and the installed dark-mode surface inspected locally |
| Attention UI | Native menu and status window for setup, loading, healthy, problem, failure, stale, and all-paused states, with direct setup recovery and local issue search | Empty setup with its direct action, deterministic two-problem Icinga status, failure with retained stale data, explicit installed-app password-revocation and relaunch failures, accessible source error, recovery, and all-paused status inspected locally; an installed release build connected to the real lab, displayed two live issues, filtered them by keyboard search, and completed manual refresh |
| Visible-status idle cost | Native production status window with 5,000 synthetic issues plus an installed release build connected to the real Icinga lab | Verified locally. The large view reported 0.0% CPU, 0.0 `top` power score, and 37 MB resident memory across five samples. The installed app reported 0.0% CPU, 0.0 power score, and 62 MB resident memory after live refresh and search activity |
| Runtime localization | System Default plus 21 explicit languages in one String Catalog, persistent in-app selection, immediate locale changes, native language names, and right-to-left layout for Arabic and Urdu | Catalog completeness, placeholders, protected product terms, runtime English/Swedish/Arabic resolution, persistence, RTL selection, six native screenshots, and the 390-pixel landing-page layout are verified. Initial copy is marked machine-translated and still requires native-speaker review |
| Release identity and manual update journey | Own asset-catalog icon, German bundle region, native About panel, installed version/build, and explicit link to the official release channel without an automatic network check | Universal bundle metadata, icon renditions, running menu, About panel, and isolated first-run source window inspected locally |
| Real Icinga 2 integration | Isolated pinned official container lab covers HTTP rejection, missing and invalid authentication, permission denial, Basic auth, private CA, mTLS, exact pinning, rejected trust, real host/service problem payloads, stable initial checks, and two persisted app-model sources | Full live Core and installed-app matrix verified locally on 2026-11-14 |
| OSS repository controls | Apache-2.0, provenance notice, contributor/security/privacy policies, private vulnerability reporting, secret scanning with push protection, SHA-pinned Actions, required CI and Swift CodeQL, and protected `main` | Verified in the public repository; the first 27-rule Swift scan completed with zero results and zero open alerts |
| Release-candidate artifacts | Universal Developer ID build, hardened runtime, timestamp, fail-closed notarization, ZIP, DMG, SPDX 2.3 SBOM, verified SHA-256 manifest, and a release configuration without coverage instrumentation | The canonical unsigned ZIP/DMG/SBOM/checksum path is verified locally; signing and notarization fail closed in the current implementation; the commit-pinned reusable GitHub release workflow is wired, but its IssueLight credentials and first accepted run remain open |

The local package suite currently executes 91 tests. Eighty-three deterministic
tests pass, while eight live Icinga tests are skipped unless the integration
environment is configured. The app suite executes twenty-six deterministic tests
and one live integration test, skipped outside the lab. It exercises
multiple-source management and refresh isolation through persisted source,
real Keychain, real Icinga 2, runtime localization, native screenshot, and
catalog-integrity boundaries. The full live matrix passed locally on 2026-11-14
without opening a Keychain authentication dialog.

Source-only LLVM coverage for `IssueLightCore` is currently 86.8% of lines and
79.9% of regions locally. CI enforces floors of 86.0% and 79.0% respectively so
the verified baseline cannot silently regress. Swift does not report branch
totals in this configuration. Coverage remains below the project goals. The
goals are not an automatic release gate, but uncovered reachable behavior
remains a quality risk and must not include an accepted security or lifecycle
requirement.

## Release blockers

- A protected client-identity private key still needs deterministic installed-
  app evidence that background signing fails without authentication UI. Normal
  mTLS and locked-Keychain lookup behavior pass without prompting.
- Accepted notarization, stapling, Gatekeeper assessment, and clean-account
  installation are not proven for a published artifact. The IssueLight GitHub
  repository does not currently contain the signing and notarization secrets
  required by the shared release workflow.
- No IssueLight release has completed the credentialed GitHub distribution
  workflow. The first run must be reviewed before the pipeline can be treated
  as operational evidence.
- The 21-language catalog is structurally complete and marked as machine
  translated. Native-speaker review, including plural behavior and terminology,
  remains required before the localized copy can be called release-reviewed.

Do not describe IssueLight as production-ready until these blockers are closed
or explicitly removed from the supported scope.
