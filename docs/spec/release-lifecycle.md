# Release Lifecycle

Status: Accepted for the first public release.

## Outcome

A person can identify the installed IssueLight version, find the authoritative
release channel, and distinguish a development build from a publishable,
notarized release.

The first release supports a German user interface and manual updates. It does
not perform automatic update checks or install executable code.

## Requirements

- `REL-001` The application bundle MUST contain its own recognizable app icon,
  German development language, version, positive build number, category, and
  copyright metadata.
- `REL-002` The menu MUST expose the native About panel and a direct link to the
  official IssueLight GitHub Releases page.
- `REL-003` IssueLight MUST NOT claim or simulate automatic updates in the
  first release. Opening the release page MUST be an explicit user action.
- `REL-004` A publishable archive MUST contain the universal, Developer-ID-
  signed, notarized, and stapled app accepted by Gatekeeper.
- `REL-005` Every public release MUST include the ZIP app archive, installable
  DMG, SPDX 2.3 SBOM, and verified SHA-256 manifest produced from the same
  revision.
- `REL-006` Release notes MUST identify the supported macOS version plus
  compatibility changes and security fixes relevant to updating users.

## Acceptance evidence

| Requirement | Public boundary | Evidence |
| --- | --- | --- |
| REL-001 | built application bundle and Finder | Asset-catalog compilation, bundle metadata inspection, and installed-app inspection |
| REL-002..003 | running menu-bar app | Menu, About panel, browser handoff, and network observation |
| REL-004..005 | release entrypoint and published GitHub release | Signature, notarization, stapling, Gatekeeper, archive, SBOM, and checksum verification |
| REL-006 | published release notes | Human review against the release diff and supported-platform declaration |
