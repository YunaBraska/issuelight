# Project status

IssueLight is pre-production. It is not yet a complete NagBar successor.

## Implemented

- Native macOS menu-bar status with severity counters and issue rows.
- Multiple independently refreshed Icinga 2 sources.
- Basic authentication and mTLS identities from macOS Keychain.
- System trust, source-specific private CA trust, exact certificate pinning,
  and an explicit per-source certificate-verification bypass.
- Recheck, acknowledgement, and fixed downtime through the Icinga 2 action
  API. Acknowledgement and downtime require an author and comment.
- Compact single-line issue rows with source names, persistent source/severity/
  coverage filters, direct quick actions, and Icinga Web row navigation.
- Optional SSH and RDP host actions plus direct-first, source-wide SSH fallback
  for API and web reachability with app-owned cleanup.
- System Default plus 21 selectable app languages, including Swedish and
  right-to-left layout for Arabic and Urdu.
- Universal ZIP and DMG packaging, SPDX SBOM, checksums, signing, notarization,
  and GitHub release automation that fails closed when credentials are absent.
- Signed Sparkle updates for direct releases. The App Store target contains no
  Sparkle framework or direct-update configuration.
- Sandboxed App Store package automation for direct Icinga connections. The
  Store edition deliberately excludes SSH tunnels and remote-client launchers.

## Evidence

- `sh scripts/check.sh` runs package, app, localization, screenshot, coverage,
  packaging, and repository checks.
- `sh scripts/icinga2_lab.sh verify` runs the real containerized Icinga 2 and
  Icinga Web matrix for Basic authentication, mTLS, private CA trust,
  certificate pinning, object deep links, and expected failures.
- Screenshot tests render the production SwiftUI views used by the product
  page.

## Remaining release gates

- Add complete Nagios Core, Thruk, and Checkmk provider journeys. Each provider
  needs discovery, authentication, snapshot loading, web navigation, supported
  actions, diagnostics, and a real-system compatibility test. Thruk is the
  next vertical slice because one adapter covers multiple Nagios-compatible
  monitoring cores without parsing HTML.
- Add quiet native notifications with deduplication, recovery handling, and
  per-source policy.
- Run the installed-app protected-private-key case described in
  `docs/DEVELOPMENT.md`. Background refresh must fail without authentication UI
  and retain the previous snapshot.
- Add the repository signing, notarization, and App Store signing secrets, run
  the release workflow, then verify direct stapling, Gatekeeper assessment,
  Store package upload, and installation on clean macOS accounts.
- Configure the Sparkle private-key secret and matching public-key repository
  variable, then verify one published update and replacement cycle.
