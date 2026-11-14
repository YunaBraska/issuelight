# Attention-first monitoring snapshot

Status: Accepted for iterative implementation.

## Outcome

From the menu bar, a person can tell whether any monitored object currently
needs attention, inspect the small set of actionable problems, and distinguish
a healthy source from a failed or stale refresh.

This specification owns read state and refresh behavior. Operator actions are
separate commands on a selected issue and must refresh that source after the
provider confirms the command.

## Requirements

### Provider data

- `SNAP-001` A monitoring issue MUST identify its source, object kind, host,
  optional service, provider-native object name, severity, summary,
  acknowledgement state, and downtime state.
- `SNAP-002` Provider-native payloads MUST be decoded at the adapter boundary.
  Shared UI and persistence MUST NOT depend on Icinga attribute names.
- `SNAP-003` A snapshot MUST include its observation time and all current
  non-healthy host and service results returned by the provider.
- `SNAP-004` An issue MUST require attention only while it is neither
  acknowledged nor in downtime.
- `SNAP-005` The menu-bar severity MUST be the highest severity among issues
  requiring attention. An empty attention set MUST appear calm even when
  acknowledged or downtime-covered issues remain inspectable.

### Refresh lifecycle

- `REF-001` Refresh MUST use the same endpoint, authentication, server-trust
  policy, redirect restrictions, and provider adapter as connection testing.
- `REF-002` IssueLight MUST run at most one refresh per source. Starting an
  explicit refresh MUST cancel and replace an older refresh.
- `REF-003` A configured source SHOULD refresh every 60 seconds. This default
  limits idle API traffic to one host query and one service query per minute
  while keeping a menu-bar signal operationally useful.
- `REF-004` A manual refresh MUST start immediately rather than wait for the
  passive interval.
- `REF-005` A failed refresh MUST remain distinguishable from a healthy empty
  snapshot. If a previous snapshot exists, the UI MUST retain it as stale and
  show the failure.
- `REF-006` Removing or disabling a source MUST cancel its refresh work.

### Menu-bar journey

- `MENU-001` Without a configured source, the menu MUST explain that setup is
  required. Its single Settings button opens source setup.
- `MENU-002` During the first refresh, the menu MUST expose progress without
  presenting the source as healthy.
- `MENU-003` A successful empty snapshot MUST state that no issue needs
  attention and show when the source was last checked.
- `MENU-004` A problem snapshot MUST group actionable issues before
  acknowledged or downtime-covered issues and MUST expose host/service context
  without relying on color alone.
- `MENU-005` A refresh failure MUST expose a short cause and a retry action.
- `MENU-006` When the issue list is large, the menu panel MUST let a person
  find an issue by its host, service, summary, or source without performing
  network or storage work.

## Acceptance evidence

| Requirement | Public boundary | Current evidence |
| --- | --- | --- |
| SNAP-001..005 | `MonitoringSnapshot` | Core tests cover realistic host and service payloads, acknowledgement, downtime, mixed severity, and ordering |
| REF-001 | Icinga snapshot loader | Shared transport tests and a real Icinga 2 Basic-auth query both pass; a 5,000-problem synthetic Icinga response traverses request handling, decoding, provider-neutral mapping, and sorting under a five-second regression limit |
| REF-002..006 | app refresh model | App-model tests cover initial and manual refresh, replacement cancellation, stale retention, and source removal with persisted source and Keychain boundaries; an installed signed app retained its last successful Icinga snapshot after exact password revocation and exposed the missing credential after relaunch |
| MENU-001..006 | running menu-bar app | Empty setup, loading, deterministic two-problem, failure with stale data, recovery, and all-paused states pass automated rendering; an installed review app connects to the real Icinga lab; the searchable 5,000-row menu panel renders lazily within five seconds |
