# ADR 0004: Exact Server Certificate Pinning

Status: Accepted.

Date: 2026-11-10.

## Context

Some private Icinga installations cannot use a system-trusted or locally
managed certificate authority. Disabling TLS verification makes those systems
reachable, but also disables server identity checks. Importing a server leaf as
a general CA would represent a broader trust decision than the user intended.

Certificate renewal must not silently replace an explicit identity decision.
IssueLight also must not modify system trust or persist the selected certificate
file when only an exact server identity is required.

## Decision

IssueLight offers exact leaf-certificate pinning as a source-specific trust
mode. The user selects one PEM or DER certificate. IssueLight stores only its
normalized SHA-256 fingerprint in the source record.

For each connection, the Icinga adapter compares the presented leaf
certificate's DER SHA-256 fingerprint with the stored value before accepting
it. It then evaluates that leaf as the only anchor for the current `SecTrust`
object under Apple's SSL server policy for the configured hostname. Apple's
trust engine continues to enforce hostname, validity period, key usage, and
certificate structure. The trust change applies only to that connection and
never modifies macOS trust settings.

Changing the source scheme, host, or effective port resets pinning to system
trust. A changed or renewed leaf fails closed until the user selects and saves
the new certificate. The UI asks the user to test the connection before saving,
but does not make that test a persistence requirement. IssueLight does not
perform automatic pin discovery or rotation.

The pin covers the complete leaf certificate rather than only its public key.
That makes the identity decision explicit and predictable, at the cost of
requiring review for every leaf renewal.

## Consequences

- A self-hosted source can retain hostname and certificate checks without
  relying on a globally trusted CA.
- Persisted pinning data is public configuration, not a secret or Keychain
  item.
- Certificate replacement is deliberately unavailable until an operator
  reviews the new leaf.
- Routine certificate renewal requires a manual IssueLight update.
- Public-key pinning and automatic overlapping-pin rotation remain outside the
  supported scope.
