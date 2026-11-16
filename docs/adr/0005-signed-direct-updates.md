# ADR 0005: Signed Updates for Direct Releases

Status: Accepted.

Date: 2026-11-13. Updated: 2026-11-16.

## Context

IssueLight has separate direct-download and Mac App Store channels. Direct
downloads need a secure update path without asking people to replace the app
manually. The App Store must remain on Apple's update channel and must not ship
a competing updater.

## Decision

Direct releases use the pinned Sparkle 2.10.0 framework. The app checks the
HTTPS feed automatically, does not download updates without user interaction,
and accepts only updates described by the signed appcast. The appcast points to
the same Developer ID signed, notarized, and stapled DMG published by the
release workflow.

The Ed25519 private update key remains a GitHub Actions secret. Its public key
is a repository variable embedded in direct releases. The release fails when
only one key is configured or when the keys do not match.

The App Store target does not link or embed Sparkle, its license resource, feed
metadata, or update key. Store installations receive updates only through the
Mac App Store.

## Consequences

- Direct installations receive signed update notifications without a manual
  visit to GitHub Releases.
- Installing an update remains a visible user decision.
- Direct builds contact the GitHub-hosted appcast automatically.
- The release contract now owns Sparkle version pinning, feed signing,
  framework embedding, license inclusion, and replacement verification.
- The Store package has a separate target and an executable check proving that
  no direct-release updater is present.
