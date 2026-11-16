# Source Connection

Status: Accepted for iterative implementation.

## Outcome

IssueLight provides a native macOS setup journey that connects to a real
monitoring source without exposing credentials or hiding transport failures.
Icinga 2, Thruk, Checkmk, and Nagios Core use the same source lifecycle without
leaking their protocol details into shared UI or persistence.

## Scope

This specification owns source identity, endpoint validation, authentication,
server trust, connection testing, and the boundary between the host app and a
monitoring provider.

The current increment includes Icinga 2, Thruk, Checkmk, and Nagios Core, HTTP
Basic authentication, Thruk and Checkmk API-key authentication, X.509
client-certificate authentication, macOS Keychain storage, and source-specific
TLS policy. It does not own monitoring-state presentation or notifications.

## Decisions

- Icinga 2 is the compatibility baseline. Thruk, Checkmk, and Nagios Core
  validate that the shared model has no Icinga-only state.
- Provider discovery uses one built-in registry. Third-party plug-ins are not a
  current requirement.
- Thruk Basic authentication is read-only. IssueLight exposes Thruk write
  actions only for API-key sources because the REST command API otherwise
  requires browser-session CSRF state.
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
  the authority for passwords, API keys, and client identities.
- A source may store a monitoring-web base URL, source-wide SSH overrides, and
  optional SSH and RDP host actions. These are provider-neutral public
  configuration.
- API and web reachability are evaluated independently. A user-initiated test
  checks the direct route first. Only a reachability failure may start
  non-interactive system OpenSSH. TLS, authentication, authorization, and
  response failures do not. Background work reuses the successful route to
  avoid repeating a 15-second direct timeout every minute.
- One source-owned SOCKS5 session may serve both API and web checks. API
  requests retain their original URL, server name, and trust policy through
  the proxy. Local ports are runtime state and are never persisted.
- Empty SSH overrides use the API host, the user's OpenSSH configuration,
  default user and port selection, and SSH agent. A selected identity file or
  preferred local port overrides only that value.
- Source fields are hints until a provider confirms them. A successful
  user-initiated test replaces the hint with the provider's canonical endpoint
  and fills an empty display name from the discovered instance host.
- Saving and testing are separate operations. Saving never depends on current
  network reachability. An incomplete configuration is persisted as a disabled
  draft and is not used for refresh or operator actions.
- The automatic web default prefers the provider's current web integration
  while retaining an explicit user override. Icinga 2 defaults to Icinga DB
  Web. Classic Monitoring remains an explicit override because API credentials
  do not authenticate Icinga Web and TCP reachability cannot identify a module.
- SSH transport for reaching the monitoring source and optional SSH or RDP
  actions for a monitored host are separate features. Host actions remain
  available but are disabled by default and presented separately.
- External-browser HTTPS deep links are opened only when directly reachable.
  Replacing their hostname with loopback would break certificate identity
  verification. HTTP deep links may use the owned loopback forward.

## Requirements

### Source model

- `SRC-001` A persisted source or draft MUST have a stable identifier, provider
  identifier, enabled state, authentication mode, and server-trust mode.
- `SRC-002` Saving MUST preserve incomplete public configuration as a disabled
  draft. A draft MUST NOT refresh, execute operator actions, or be presented as
  a connected monitoring source until provider validation succeeds.
- `SRC-003` A change to scheme, host, or effective port MUST reset every
  source-specific trust exception to system trust before the source is used
  again.
- `SRC-004` Persisted source configuration MUST NOT contain a password, private
  key, PKCS#12 import password, or exported client identity.
- `SRC-005` A saved draft MUST remain editable after relaunch and MUST retain
  the public field text the person entered, including an endpoint hint that is
  not yet valid. Embedded URL credentials MUST be removed before persistence.

### Provider boundary

- `PRV-001` A provider MUST publish its identifier, display name, supported
  authentication methods, trust options, and optional capabilities.
- `PRV-002` Missing or unsupported capabilities MUST be visible to the host and
  MUST NOT be simulated.
- `PRV-003` Adding a built-in provider SHOULD change only its adapter and the
  single provider registration point.
- `PRV-004` The Icinga 2 provider MUST require HTTPS and MUST accept only the
  API root or `/v1` as its configured endpoint path.
- `PRV-005` A provider MUST own candidate generation and canonicalization for
  its endpoint hints. Shared setup code MUST NOT contain Icinga-specific ports,
  paths, or response rules.
- `PRV-006` The Thruk provider MUST accept only REST roots ending in `/thruk/r`
  or `/thruk/r/v1`. It MUST own Thruk authentication headers, Livestatus
  fields, commands, and classic-web object URLs.
- `PRV-007` The Checkmk provider MUST accept only REST roots ending in
  `/check_mk/api/v1` or `/check_mk/api/1.0`. It MUST own Checkmk Bearer
  authentication, status queries, actions, and web object URLs.
- `PRV-008` The Nagios Core provider MUST own Basic authentication, JSON status
  queries, command-CGI CSRF state, actions, and classic-web object URLs. It MUST
  reject successful-looking HTML and JSON responses that are not the expected
  Nagios CGI contract.

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
- `AUTH-007` Thruk API keys MUST be stored in source-scoped Keychain entries
  distinct from Basic passwords. Source JSON MAY contain the optional public
  user context but MUST NOT contain the key.
- `AUTH-008` Thruk Basic authentication MUST NOT advertise or submit write
  actions. A Thruk API-key source MAY expose the provider's supported commands.
- `AUTH-009` A Checkmk API key MUST be stored in a source-scoped Keychain entry
  distinct from Basic passwords. The public automation username MAY be stored;
  the secret MUST NOT enter source JSON.

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
- `CONN-004` A user-initiated test MUST report API and web reachability
  independently as direct, SSH, or failed.
- `CONN-005` A user-initiated test MUST try direct access first and MUST attempt
  SSH only after a reachability failure. It MUST NOT hide TLS, authentication,
  authorization, server, or incompatible-response failures behind SSH retries.
- `CONN-006` Background refresh and monitoring actions MUST reuse the route
  selected by the user-initiated connection test. They MUST retry route
  selection when that route becomes unreachable.
- `CONN-007` Icinga 2 discovery MUST accept a hostname, IP address, API URL, or
  pasted monitoring-web URL. It MUST discard path, query, and fragment data,
  require HTTPS for the real API request, and confirm every candidate through
  the Icinga API. API-shaped hints try their stated port before `5665`.
  Web-shaped hints try `5665` before their stated HTTPS port so a pasted web
  address does not turn a web authentication response into a false API match.
- `CONN-008` Only a successful provider API request MAY replace the endpoint
  hint with a canonical endpoint. An open port, TLS handshake, HTTP response,
  or failed authentication alone is not discovery success.
- `CONN-009` A connection test MUST expose the attempted endpoint and route for
  each API and web result without including a password, token, private-key
  path, or Keychain value.
- `CONN-010` Thruk discovery MUST accept a hostname, REST URL, or pasted Thruk
  web URL, preserve a deployment prefix, and confirm the instance plus readable
  host and service endpoints before canonicalizing it to `/thruk/r/v1`. A hint
  without a scheme MUST try HTTPS only. Plain HTTP requires an explicit scheme
  so discovery never silently downgrades credentials.
- `CONN-011` Checkmk discovery MUST accept a hostname, site URL, REST URL, or
  pasted Checkmk web URL and confirm version, host, and service endpoints before
  canonicalizing it. Plain HTTP requires an explicit scheme.
- `CONN-012` Nagios Core discovery MUST accept a hostname, web URL, or pasted
  CGI URL and confirm program, host, and service JSON responses before
  canonicalizing it to `statusjson.cgi`. A hint without a scheme MUST try HTTPS
  only, except loopback development hosts. Plain HTTP otherwise requires an
  explicit scheme.

### Navigation

- `NAV-001` The provider MUST build web object URLs from its own object model.
  An explicit source-owned base URL overrides the automatic default. Icinga 2
  MUST default to Icinga DB Web. It MUST NOT claim to discover a web module from
  TCP reachability alone.
- `NAV-002` A row click MUST open the web object directly when reachable. An
  unreachable HTTP target MAY use the source-owned loopback forward. An
  unreachable HTTPS target MUST fail closed until the original browser host can
  be preserved.
- `NAV-003` An automatic tunnel MUST use `/usr/bin/ssh`, non-interactive
  authentication, loopback binding, a configured preferred port or a free
  fallback, and the user's OpenSSH configuration and agent unless an identity
  file was explicitly selected.
- `NAV-004` IssueLight MUST terminate owned tunnels when the direct route
  recovers, their source is disabled, removed, or reconfigured, and when the
  app terminates.
- `NAV-005` SSH and RDP actions MUST use escaped URLs handed to the registered
  system application. A missing handler MUST produce an explicit failure.
- `NAV-006` Source SSH transport and monitored-host SSH or RDP actions MUST be
  labeled and configured separately. Enabling a source tunnel MUST NOT add a
  host action to the issue context menu.

## First journey

1. The user selects a built-in provider and enters a hostname, IP address, or URL
   hint. Every field that can be derived remains optional.
2. When the user saves, IssueLight persists the public fields as a disabled
   draft.
3. The user selects an authentication method supported by that provider.
4. IssueLight stores a Basic password or API key in Keychain, or retains the
   client-identity reference.
5. The user tests the connection. IssueLight tries provider-owned endpoint
   candidates directly and then through configured SSH transport when allowed.
6. A real provider success updates the draft to the canonical endpoint, fills
   derived defaults, reports API and web results independently, and permits the
   source to be enabled without copying any secret into source persistence.

## Acceptance evidence

| Requirement | Public boundary | Evidence |
| --- | --- | --- |
| SRC-001..004 | `MonitoringSource` | Package tests for validation, encoding, and authority changes |
| PRV-001..008 | provider registry and adapters | Package tests cover every adapter's discovery, capabilities, endpoint rules, provider-neutral snapshot dispatch, actions, and web links; the Icinga, Thruk, Checkmk, and Nagios Core live matrices cross the same registry boundary against pinned real systems |
| AUTH-001, AUTH-007..009 | `KeychainPasswordVault` and API-key providers | Temporary real-Keychain tests prove independent Basic-password and API-key storage, replacement, lookup, and cleanup; real Thruk and Checkmk tests prove reads, commands, wrong-secret rejection, and provider-specific action availability |
| AUTH-002, AUTH-004 | Keychain identity catalog and connection test | Real PKCS#12 import, persistent-reference resolution, accepted and rejected live Icinga mTLS, and exact cleanup |
| AUTH-003, AUTH-005..006 | source setup journey | Password availability uses only non-secret ownership metadata; a real foreign legacy Keychain item is rejected without reading its secret; background password and exact-identity reads use a non-interactive authentication context; broad identity searches silently skip protected items; isolated Keychain tests prove prompt-free failure for a protected legacy-ACL private key and success for a trusted key; missing identities fail explicitly; approve, deny, and recovery remain signed-app acceptance checks |
| TLS-001..006 | connection test and source lifecycle | Default, source-specific private CA, exact leaf pinning, and unchecked trust implemented; the live matrix accepts the configured CA and exact leaf, rejects an unrelated CA, mismatched leaf, and exact leaf under the wrong hostname; Apple trust evaluation preserves certificate validity policy; authority changes reset custom trust; real Keychain tests cover ownership-aware CA cleanup after the final source reference; pin replacement remains an explicit user action |
| CONN-001..012 | connection test | Real containerized Icinga 2 Basic and mTLS success, real OMD/Thruk Basic and API-key success, real Checkmk API-key success, source-built Nagios Core Basic-auth and CGI success, distinct authentication, authorization, and trust failures, unit coverage for direct-first routing and independent settings status, plus running-UI cancellation evidence |
| NAV-001..005 | issue row and source settings | Core tests cover classic and Icinga DB Web host/service links plus escaped SSH/RDP URLs; app tests cover source-wide SSH persistence, safe OpenSSH commands, direct opening, row clicks, and source-owned cleanup; real OpenSSH integration tests verify HTTP forwarding and an Icinga API request through SOCKS5 before closing owned ports |
