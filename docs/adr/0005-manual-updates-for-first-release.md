# ADR 0005: First Releases Use Manual Updates

Status: Accepted.

Date: 2026-11-13.

## Context

IssueLight needs a clear update path before its first public release. An
in-app updater would add a privileged download and replacement path, another
release-signing integration, and a third-party runtime dependency. The project
does not yet have evidence that background update checks or automatic
replacement reduce more operator risk than they introduce.

## Decision

The first supported releases use manual updates from the repository's official
GitHub Releases page. The Settings About tab links to that page and shows the
installed version and build.

IssueLight does not contact GitHub automatically, download executable code, or
replace itself. A publishable release contains the notarized universal app
archive, SPDX SBOM, and SHA-256 manifest produced by the release entrypoint.
Release notes identify compatibility changes and security fixes. Users replace
the app explicitly after obtaining a newer release.

Automatic update checks and installation remain outside the first release
scope. Adding them later requires a new decision that owns signature
verification, rollback, interrupted replacement, release-channel selection,
privacy, and failure recovery.

## Consequences

- The first release has an explicit update journey without a hidden network
  request or updater dependency.
- Users decide when to contact GitHub and when to replace the app.
- Security updates require a manual visit to the release page.
- Release documentation must not imply that IssueLight updates itself.
