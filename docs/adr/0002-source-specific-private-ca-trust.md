# ADR 0002: Private CA Trust Is Source-Specific

Status: Accepted.

Date: 2026-11-10.

## Context

Private Icinga installations commonly use an internal certificate authority.
Disabling TLS verification makes such a source work, but removes identity,
hostname, chain, and validity protection. Adding the CA to macOS system trust
would affect unrelated applications and exceed IssueLight's authority.

## Decision

IssueLight imports one PEM or DER public CA certificate into macOS Keychain and
stores only its persistent reference in the source record. The host resolves
that reference before crossing the provider boundary.

The Icinga adapter applies the certificate as an additional anchor only to the
current source's `SecTrust` object. It sets Apple's SSL server policy with the
configured hostname, keeps system anchors available, evaluates the resulting
trust, and rejects failure as a TLS error. IssueLight never changes macOS trust
settings.

Changing the source authority resets custom trust to system trust. A newly
added certificate receives an IssueLight ownership marker only when IssueLight
created the Keychain item. The marker is scoped to the app profile. If another
IssueLight profile imports the same Keychain certificate, the item becomes
shared and automatic deletion stops for both profiles. After loading, saving,
or removing sources, IssueLight deletes its exclusively owned certificates only
when no persisted source still references them. Pre-existing, shared, and
externally managed certificates remain untouched. Exact leaf-certificate
pinning is a separate trust mode owned by ADR 0004.

## Consequences

- Private-CA systems work without disabling verification.
- Hostname, validity, key-usage, and chain checks remain owned by Apple's trust
  engine.
- The provider port receives resolved public trust material and stays free of
  Keychain lookup behavior.
- IssueLight cleans only certificate items it can prove it created. This may
  retain an old or externally managed public certificate, but cannot delete a
  user's unrelated Keychain item.
