# Release Lifecycle

Status: Accepted for public releases.

## Outcome

A person can identify the installed IssueLight version, find the authoritative
release channel, and distinguish a development build from a publishable,
notarized release.

Public releases support German plus 20 explicitly selectable translations,
including Swedish. Direct releases check a signed Sparkle feed for updates and
install only after user confirmation. The direct release includes optional SSH
tunnels and remote-client launchers. The sandboxed App Store edition uses
Apple's update channel and deliberately excludes Sparkle and external-tool
features.

## Requirements

- `REL-001` The application bundle MUST contain its own recognizable app icon,
  German development language, version, positive build number, category, and
  copyright metadata.
- `REL-002` Settings MUST expose an About tab with the installed version,
  project, support, privacy, and official release links. The menu MUST expose
  Settings without a duplicate About entry.
- `REL-003` A direct release MUST check only the configured HTTPS appcast and
  MUST verify its signature and the downloaded update before replacement.
- `REL-004` A publishable archive MUST contain the universal, Developer-ID-
  signed, notarized, and stapled app accepted by Gatekeeper.
- `REL-005` Every public release MUST include the ZIP app archive, installable
  DMG, SPDX 2.3 SBOM, and verified SHA-256 manifest produced from the same
  revision.
- `REL-006` Release notes MUST identify the supported macOS version plus
  compatibility changes and security fixes relevant to updating users.
- `REL-007` The App Store package MUST use the App Sandbox, only the minimum
  outgoing-network and user-selected-file entitlements, and no executable
  OpenSSH or netcat path.
- `REL-008` The App Store package MUST NOT contain Sparkle, direct-update feed
  metadata, an update key, or the direct edition's updater license resource.

## Acceptance evidence

| Requirement | Public boundary | Evidence |
| --- | --- | --- |
| REL-001 | built application bundle and Finder | Asset-catalog compilation, bundle metadata inspection, and installed-app inspection |
| REL-002..003 | running menu-bar app and direct release | Settings About tab, signed appcast, embedded public key, and Sparkle package checks |
| REL-004..005 | release entrypoint and published GitHub release | Signature, notarization, stapling, Gatekeeper, archive, SBOM, and checksum verification |
| REL-006 | published release notes | Human review against the release diff and supported-platform declaration |
| REL-007..008 | App Store package | Entitlement, binary-path, updater-absence, signature, and installer checks before upload |
