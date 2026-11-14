# Project status

IssueLight is a release candidate, not a published production release.

## Implemented

- Native macOS menu-bar status with severity counters and issue rows.
- Multiple independently refreshed Icinga 2 sources.
- Basic authentication and mTLS identities from macOS Keychain.
- System trust, source-specific private CA trust, exact certificate pinning,
  and an explicit per-source certificate-verification bypass.
- Recheck, acknowledgement, and fixed downtime through the Icinga 2 action
  API. Acknowledgement and downtime require an author and comment.
- System Default plus 21 selectable app languages, including Swedish and
  right-to-left layout for Arabic and Urdu.
- Universal ZIP and DMG packaging, SPDX SBOM, checksums, signing, notarization,
  and GitHub release automation that fails closed when credentials are absent.

## Evidence

- `sh scripts/check.sh` runs package, app, localization, screenshot, coverage,
  packaging, and repository checks.
- `sh scripts/icinga2_lab.sh verify` runs the real containerized Icinga 2 matrix
  for Basic authentication, mTLS, private CA trust, certificate pinning, and
  expected failures.
- Screenshot tests render the production SwiftUI views used by the product
  page.

## Remaining release gates

- Run the installed-app protected-private-key case described in
  `docs/DEVELOPMENT.md`. Background refresh must fail without authentication UI
  and retain the previous snapshot.
- Add the repository signing and notarization secrets, run the release
  workflow, then verify stapling, Gatekeeper assessment, and installation on a
  clean macOS account.

Web deep links, native notifications, and providers other than Icinga 2 are not
part of this release.
