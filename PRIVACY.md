# Privacy

IssueLight connects directly from the Mac to monitoring sources configured by
the user. The project does not operate a relay service and the app currently
contains no analytics, advertising, crash-reporting SDK, or telemetry.

## Data sent over the network

IssueLight sends read-only Icinga 2 host and service requests only to a
configured source and to same-origin redirects. Requests may contain the API
username and password or use a selected client identity. The configured TLS
policy applies independently to each source.

Network traffic can still be visible to the configured server and to network
infrastructure such as DNS resolvers, proxies, and VPNs. Disabling certificate
verification removes server-identity protection for that source and is not the
default.

## Data stored on the Mac

- Public source configuration is stored in
  `~/Library/Application Support/io.github.yunabraska.issuelight/sources.json`
  with permissions restricted to the local user. Names and URLs in this file
  can reveal infrastructure details. Exact certificate pinning stores the
  selected server leaf's public SHA-256 fingerprint in this file.
- Passwords and client identities remain in macOS Keychain. Source
  configuration stores references, not secret values or private keys.
- Imported private CA certificates are public certificates stored in Keychain.
  IssueLight removes a certificate automatically only when the same app
  profile created it and no saved source references it.
- Monitoring snapshots are held in memory and are not persisted by IssueLight.

Removing a source removes its saved Basic password. Client identities and
shared or externally managed certificates remain in Keychain because other
applications or sources may use them. They can be reviewed and removed with
Keychain Access.

## Diagnostics and issue reports

IssueLight does not currently upload diagnostics. Before sharing a bug report,
remove credentials, private hostnames, monitoring object names, certificates,
tokens, and payloads. Security reports belong in GitHub private vulnerability
reporting as described in [SECURITY.md](SECURITY.md).
