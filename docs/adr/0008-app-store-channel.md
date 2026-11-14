# 0008: Build a sandboxed App Store edition

Status: Accepted

## Context

IssueLight needs a Mac App Store channel as well as the direct, notarized
GitHub release. The direct edition can invoke OpenSSH for source-owned tunnels
and launch remote SSH or RDP clients. A sandboxed Store application must not
ship or invoke those external tools.

## Decision

The App Store build compiles with `ISSUELIGHT_APP_STORE`, uses the App Sandbox,
outgoing network access, and read-only user-selected file access. It contains
no OpenSSH or netcat executable path and does not offer SSH tunnels, SSH
actions, or RDP actions. It continues to support direct Icinga HTTPS access,
Keychain credentials, mTLS, private CAs, pinning, issue actions, and web links.

The Store package is built by the shared Swift release workflow and uses the
same bundle identifier and stable marketing version as the direct release. A
stable manual release is therefore the single action that creates the checked
direct artifacts, Store package, App Store Connect upload, and GitHub release.

## Consequences

The Store package has a smaller capability surface than the GitHub download.
Users needing an SSH tunnel or remote-client launcher install the direct
notarized release. This is explicit in the Store setup UI and documentation.

The CI check builds an ad-hoc signed Store-shaped app before release. The
stable workflow repeats the build with the Apple Distribution certificates and
provisioning profile, then checks the signed installer package before upload.
