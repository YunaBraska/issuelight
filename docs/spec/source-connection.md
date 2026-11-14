# Source Connection

Status: Accepted for iterative implementation.

## Outcome

IssueLight provides a native macOS setup journey that connects to a real monitoring
source without exposing credentials or hiding transport failures. Icinga 2 is
the first provider. Additional providers use the same source lifecycle without
leaking their protocol details into shared UI or persistence.

## Scope

This specification owns source identity, endpoint validation, authentication,
server trust, connection testing, and the boundary between the host app and a
monitoring provider.

The first increment includes Icinga 2, HTTP Basic authentication, X.509 client
certificate authentication, macOS Keychain storage, and source-specific TLS
policy. It does not yet own monitoring-state presentation, notifications, or
notifications.

## Decisions

- Icinga 2 is the first built-in provider, not a special case in shared models.
- Provider discovery uses one built-in registry. Third-party plug-ins are not a
  current requirement.
- Source records contain references and public configuration only. Passwords
  and private keys never enter source JSON, logs, diagnostics, or fixtures.
- Server certificate verification is enabled by default. A user may disable it
  for one source under advanced settings.
- A private CA is imported as a public certificate into macOS Keychain. Source
  JSON stores only its persistent reference. IssueLight applies it only to that
  source's trust evaluation and does not change system trust settings.
- An exact server-certificate pin stores only the normalized SHA-256 fingerprint
  of a user-selected leaf. A changed leaf fails closed until the user explicitly
  selects and saves its replacement. Connection testing is recommended through
  the normal setup journey, not required for persistence.
- Changing a source's scheme, host, or port resets every source-specific trust
  exception to system trust.
- The app stores only public source configuration. Its Keychain items remain
  the authority for passwords and client identities.
- A source may additionally store a monitoring-web base URL and optional SSH
  and RDP launch settings. These are provider-neutral public configuration.
- An automatic web tunnel tries the direct route first and then runs system
  OpenSSH with non-interactive authentication. It binds only to `127.0.0.1`,
  stops with the app, and supports HTTP web targets only. HTTPS tunneling fails
  closed because replacing the browser hostname would break certificate
  identity verification.

## Requirements

### Source model

- `SRC-001` A source MUST have a stable identifier, display name, provider
  identifier, endpoint, enabled state, authentication mode, and server-trust
  mode.
- `SRC-002` A source MUST reject an empty name, a non-HTTP endpoint, an endpoint
  without a host, embedded user information, a query, or a fragment.
- `SRC-003` A change to scheme, host, or effective port MUST reset every
  source-specific trust exception to system trust before the source is used
  again.
- `SRC-004` Persisted source configuration MUST NOT contain a password, private
  key, PKCS#12 import password, or exported client identity.

### Provider boundary

- `PRV-001` A provider MUST publish its identifier, display name, supported
  authentication methods, trust options, and optional capabilities.
- `PRV-002` Missing or unsupported capabilities MUST be visible to the host and
  MUST NOT be simulated.
- `PRV-003` Adding a built-in provider SHOULD change only its adapter and the
  single provider registration point.
- `PRV-004` The Icinga 2 provider MUST require HTTPS and MUST accept only the
  API root or `/v1` as its configured endpoint path.

### Credentials

- `AUTH-001` Basic-auth passwords MUST be stored as macOS Keychain internet
  passwords scoped by source identifier, host, effective port, protocol, and
  account.
- `AUTH-002` Client-certificate authentication MUST resolve a `SecIdentity`
  from the macOS Keychain. Source configuration stores only a stable reference.
- `AUTH-003` Cancelling or denying Keychain access MUST stop the operation and
  return an explicit failure without falling back to another credential.
- `AUTH-004` A PKCS#12 import password MUST be used only for that import and
  MUST NOT be persisted.
- `AUTH-005` Background credential discovery MUST inspect only non-secret
  Keychain metadata. An item that matches a source scope but is not owned by
  IssueLight MUST fail without requesting or reading its secret.
- `AUTH-006` Background refresh and operator actions MUST fail rather than show
  Keychain authentication UI. A user-initiated connection test MAY request
  access to a protected client-identity private key.

### Server trust

- `TLS-001` New sources MUST use system server trust by default.
- `TLS-002` A source MAY use a source-specific CA or explicitly pinned server
  certificate while retaining hostname and validity checks.
- `TLS-003` A user MAY disable server-certificate verification for one source.
  The UI MUST identify the affected source as insecure while that mode remains
  active.
- `TLS-004` An insecure source MUST NOT forward credentials or client identity
  across an origin-changing redirect.
- `TLS-005` A changed pinned certificate MUST block the connection until the
  user explicitly reviews and replaces the trust decision.
- `TLS-006` IssueLight MUST delete an imported CA only when IssueLight created
  the Keychain item and no persisted source references it. Shared and
  externally managed certificates MUST remain untouched.

### Connection result

- `CONN-001` Testing a source MUST use the same provider, credentials, trust
  policy, and network path used by background refresh.
- `CONN-002` A connection test MUST distinguish invalid configuration, DNS or
  reachability failure, TLS failure, authentication failure, authorization
  failure, incompatible response, server failure, and cancellation.
- `CONN-003` Icinga 2 success MUST be established through a successful real API
  request. A local canned response is not production success.

### Navigation

- `NAV-001` The provider MUST build web object URLs from its own object model
  and a source-owned web base URL. Icinga Web's monitoring module is the
  default; a base ending in `/icingadb` selects Icinga DB Web routes.
- `NAV-002` A row click MUST open the web object directly unless an enabled
  tunnel is needed because the target host and port are unreachable.
- `NAV-003` An automatic tunnel MUST use `/usr/bin/ssh`, non-interactive
  authentication, loopback binding, a configured preferred port or a free
  fallback, and the user's OpenSSH configuration and agent unless an identity
  file was explicitly selected.
- `NAV-004` IssueLight MUST terminate owned tunnels when the direct route
  recovers, their source is disabled, removed, or reconfigured, and when the
  app terminates.
- `NAV-005` SSH and RDP actions MUST use escaped URLs handed to the registered
  system application. A missing handler MUST produce an explicit failure.

## First journey

1. The user adds an Icinga 2 source and enters its API endpoint.
2. IssueLight validates the source without contacting the server.
3. The user selects Basic authentication or a Keychain client identity.
4. IssueLight stores a Basic password in Keychain or retains the identity reference.
5. The user tests the connection.
6. IssueLight reports a concrete success or failure and saves the source without
   copying any secret into source persistence.

## Acceptance evidence

| Requirement | Public boundary | Evidence |
| --- | --- | --- |
| SRC-001..004 | `MonitoringSource` | Package tests for validation, encoding, and authority changes |
| PRV-001..004 | provider registry and Icinga 2 adapter | Package tests cover discovery, capabilities, endpoint rules, and provider-neutral snapshot dispatch; the live matrix crosses the same registry boundary |
| AUTH-001 | `KeychainPasswordVault` | Integration test against a temporary real Keychain item with cleanup |
| AUTH-002, AUTH-004 | Keychain identity catalog and connection test | Real PKCS#12 import, persistent-reference resolution, accepted and rejected live Icinga mTLS, and exact cleanup |
| AUTH-003, AUTH-005 | source setup journey | Password availability uses only non-secret ownership metadata; a real foreign legacy Keychain item is rejected without reading its secret; background password and exact-identity reads use a non-interactive authentication context; broad identity searches silently skip protected items; missing identities fail explicitly; installed protected-private-key denial still needs running-app evidence |
| TLS-001..006 | connection test and source lifecycle | Default, source-specific private CA, exact leaf pinning, and unchecked trust implemented; the live matrix accepts the configured CA and exact leaf, rejects an unrelated CA, mismatched leaf, and exact leaf under the wrong hostname; Apple trust evaluation preserves certificate validity policy; authority changes reset custom trust; real Keychain tests cover ownership-aware CA cleanup after the final source reference; pin replacement remains an explicit user action |
| CONN-001..003 | connection test | Real containerized Icinga 2 Basic and mTLS success, distinct 401 and 403 failures, plus unit and running-UI cancellation evidence |
| NAV-001..005 | issue row and source settings | Core tests cover classic and Icinga DB Web host/service links plus escaped SSH/RDP URLs; app tests cover persisted navigation settings, direct opening without a probe, row clicks, and source-owned cleanup; a real OpenSSH integration test verifies the forwarded HTTP response and closes the owned port |
