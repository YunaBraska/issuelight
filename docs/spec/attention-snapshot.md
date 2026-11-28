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
  acknowledgement state, and downtime state. State-change time and check
  attempt MUST be preserved when the provider supplies them.
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
- `REF-004` A provider-confirmed operator action MUST refresh its affected
  source immediately rather than wait for the passive interval.
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
  attention without repeating menu-bar counts or refresh controls.
- `MENU-004` A problem snapshot MUST group actionable issues before
  acknowledged or downtime-covered issues and MUST expose host/service context
  without relying on color alone.
- `MENU-005` Each failed source MUST appear as its own compact panel row with
  the source name and a short cause while automatic refresh continues to own
  retry timing. A source failure MUST NOT be counted or presented as a host or
  service problem.
- `MENU-006` The first row of the menu panel MUST let a person find an issue by
  its host, service, summary, or source without performing network or storage
  work.
- `MENU-007` Every issue row MUST remain a compact single line and identify its
  source even when only one source is configured.
- `MENU-008` Recheck, acknowledgement, and downtime MUST be direct row actions
  when the provider supports them. Unsupported or already-covered actions MUST
  be disabled.
- `MENU-009` Clicking the issue body MUST open the provider's web object URL.
  SSH and RDP remain optional secondary actions.
- `MENU-010` Source, severity, and coverage filters MUST survive relaunch and
  MUST discard a selected source when that source no longer exists.
- `MENU-011` A successful quick action MUST stay silent and refresh its source.
  A failed action MUST remain dismissible inside the panel without presenting
  a modal alert or closing the panel.
- `MENU-012` Each saved source MAY exclude hosts and services in active
  downtime or with acknowledgement, independently by object type. It MAY also
  exclude objects by case-sensitive glob matches on their native host and
  service names. A host-only rule also covers that host's services. A
  service-only rule covers services across hosts. When both are present, both
  must match. Empty rules have no effect. Previous sources default to showing
  all issues.
- `MENU-013` Source exclusions MUST apply to both the panel and menu-bar
  counts from the existing snapshot. Saving exclusions MUST preserve
  connectivity, snapshots, and notifications. A source outage remains
  visible. The panel MUST disclose excluded issues and allow temporarily
  including them in the panel and counters.

### Notifications

- `NOTIFY-001` Notifications MUST be disabled by default. IssueLight MUST ask
  macOS for notification access only after a person enables a source policy.
- `NOTIFY-002` The first successful snapshot in an app session MUST establish
  a baseline without notifying. A later newly actionable issue or severity
  escalation MAY notify according to that source's selected policy.
- `NOTIFY-003` IssueLight MUST use one stable notification identifier per
  source, MUST NOT repeat unchanged issues, and MUST remove the delivered
  source summary after full recovery, source removal, source disablement, or
  policy disablement.
- `NOTIFY-004` Banner content MUST NOT contain source names, host names, service
  names, provider output, credentials, or navigation URLs. Critical summaries
  MAY use an active interruption level. Other summaries MUST be passive. No
  IssueLight notification may request a sound.
- `NOTIFY-005` A notification click MUST use the same provider-built web target
  and direct-first SSH-tunnel behavior as an issue-row click. Navigation
  targets MUST remain in memory and MUST NOT be added to notification metadata.
- `NOTIFY-006` Notification policies MUST be source-scoped, survive relaunch,
  and be removed when their source is deleted. An unauthoritative empty source
  list during startup MUST NOT erase stored policy.
- `NOTIFY-007` IssueLight MUST clear its previously delivered summaries at app
  startup before establishing the new baseline. It MUST read existing macOS
  authorization without prompting.

## Acceptance evidence

| Requirement | Public boundary | Current evidence |
| --- | --- | --- |
| SNAP-001..005 | `MonitoringSnapshot` | Core tests cover realistic host and service payloads, acknowledgement, downtime, mixed severity, and ordering |
| REF-001 | Icinga snapshot loader | Shared transport tests and a real Icinga 2 Basic-auth query both pass; a 5,000-problem synthetic Icinga response traverses request handling, decoding, provider-neutral mapping, and sorting under a five-second regression limit |
| REF-002..006 | app refresh model | App-model tests cover initial and manual refresh, replacement cancellation, stale retention, and source removal with persisted source and Keychain boundaries; an installed signed app retained its last successful Icinga snapshot after exact password revocation and exposed the missing credential after relaunch |
| MENU-001..011 | running menu-bar app | Empty setup, loading, deterministic two-problem, compact source-failure row, recovery, and all-paused states pass automated rendering; pointer tests exercise Settings, row opening, all three quick actions, and inline error dismissal; successful actions have a model-level no-modal regression test; filter tests cover persistence and source removal; an installed review app connects to the real Icinga lab; the searchable 5,000-row menu panel renders lazily within five seconds |
| NOTIFY-001..007 | notification coordinator and settings | Coordinator tests cover explicit permission, first-snapshot suppression, new issues, threshold crossings, escalation, deduplication, recovery, disablement, deleted-source policy cleanup, startup lifecycle, private content, and navigation through the shared web-access path; screenshot tests render the production notification settings |
