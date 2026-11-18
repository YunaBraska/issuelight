# Project status

IssueLight has signed direct-release and App Store package evidence. Remaining
validation focuses on installed-app behavior and protected-key recovery.

## Implemented

- Native macOS menu-bar status with severity counters and issue rows.
- Multiple independently refreshed Icinga 2, Thruk, Checkmk, and Nagios Core
  sources.
- Basic authentication, Thruk and Checkmk API keys, and mTLS identities from macOS
  Keychain. Passwords and API keys have separate source-scoped entries.
- System trust, source-specific private CA trust, exact certificate pinning,
  and an explicit per-source certificate-verification bypass.
- Provider-owned actions through the Icinga 2, Thruk, Checkmk, and Nagios Core
  interfaces. Checkmk exposes acknowledgement and fixed downtime. The other
  providers also expose recheck. Acknowledgement and downtime require an author
  and comment.
- Compact single-line issue rows with source names, persistent source/severity/
  coverage filters, direct quick actions, and Icinga Web row navigation.
- Optional SSH and RDP host actions plus direct-first, source-wide SSH fallback
  for API and web reachability with app-owned cleanup.
- System Default plus 21 selectable app languages, including Swedish and
  right-to-left layout for Arabic and Urdu.
- Quiet native notifications with explicit per-source severity policies,
  first-snapshot suppression, escalation detection, stable source summaries,
  recovery cleanup, and detail-free banner content. Notification clicks reuse
  the issue row's direct-first web and SSH-tunnel path.
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
- `sh scripts/thruk_lab.sh test` runs the built-in Thruk provider against the
  pinned official OMD Labs image. It covers Basic and API-key authentication,
  strict and disabled trust, snapshots, recheck, acknowledgement, downtime,
  and the API-key requirement for write actions.
- `sh scripts/checkmk_lab.sh test` runs the built-in Checkmk provider against
  the pinned official Checkmk Community image. It covers discovery, snapshots,
  acknowledgement, downtime, API-key authentication, and rejected credentials.
- `sh scripts/nagioscore_lab.sh test` builds the pinned official Nagios Core
  4.5.14 source release and verifies discovery, Basic authentication, snapshots,
  recheck, acknowledgement, downtime, and command-CGI CSRF handling.
- Screenshot tests render the production SwiftUI views used by the product
  page.
- Keychain tests import both protected and trusted private keys into isolated
  temporary Keychains. Background access proves fail-closed behavior without
  authentication UI before a provider starts TLS.

## Remaining product validation

- Run the final approve, deny, and recovery sequence for a protected private
  key in the stable signed app as described in `docs/DEVELOPMENT.md`. The
  background no-prompt path already has deterministic regression coverage.
- Repeat direct and App Store installation on clean macOS accounts after a
  runtime or packaging change. CI already verifies direct notarization,
  Gatekeeper assessment, Store-package upload and the signed Sparkle appcast.
