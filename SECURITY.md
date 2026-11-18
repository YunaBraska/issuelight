# Security policy

## Supported versions

The latest GitHub release and the `main` branch receive security fixes. Older
releases are not supported. Direct installations can update through the signed
in-app update channel. App Store installations use Apple's update channel.

## Report a vulnerability

Do not open a public issue for a suspected vulnerability or exposed secret.
Use GitHub's private vulnerability reporting for this repository. Include the
affected commit or version, reproduction steps, impact, and any suggested
mitigation. Do not include real credentials or private monitoring data.

The project will acknowledge a report, reproduce it where possible, and track
the correction privately until disclosure is safe. No fixed response-time
guarantee is offered.

## Security boundaries

- Source configuration must not contain passwords, private keys, or PKCS#12
  import passwords.
- Passwords, client identities, and source-specific CA references are resolved
  through macOS Keychain.
- Automatic CA cleanup is limited to certificates marked as created by the
  same app profile and no longer referenced by a source. Shared and externally
  managed certificates remain untouched.
- Server certificate verification is enabled by default. Disabling it is a
  source-specific, visible exception.
- Exact server-certificate pinning stores only a public leaf fingerprint,
  applies trust to that source, and retains hostname and validity checks.
- Diagnostics and test fixtures must not contain private hostnames, URLs,
  tokens, private keys, production certificates, or monitoring payloads from
  real systems. Public certificates generated solely for tests are allowed.
