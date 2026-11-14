# Multiple source management

Status: Accepted for iterative implementation.

## Outcome

A person can monitor independent systems from one menu-bar app, manage each
source without affecting unrelated credentials or refresh work, and recognize
partial failure instead of seeing a misleading global healthy state.

The current implementation keeps one shared refresh interval. Per-source
intervals, folders, and provider discovery outside the built-in registry remain
outside its scope. Operator actions use the same source-specific provider,
credentials, and trust policy as refresh.

## Requirements

### Source management

- `SRC-001` The sources window MUST show every persisted source and MUST edit
  one selected source at a time.
- `SRC-002` Adding a source MUST create a new draft without changing persisted
  sources until the person saves it.
- `SRC-003` Switching sources or starting another draft MUST NOT silently
  discard unsaved form or password changes.
- `SRC-004` Saving an existing source MUST preserve its stable identifier and
  its position in the source list.
- `SRC-005` Removing a source MUST remove only that source and its Basic
  password. Client identities and credentials for other sources MUST remain.
- `SRC-006` Disabling a source MUST persist the choice, stop its refresh work,
  and exclude its last snapshot from the active status without deleting its
  configuration or credentials.

### Refresh isolation

- `MSR-001` IssueLight MUST refresh every enabled source at startup, every 60
  seconds, and on explicit refresh.
- `MSR-002` At most one refresh MAY run for each source. Replacing one source's
  refresh MUST NOT cancel refreshes for other sources.
- `MSR-003` Failure, cancellation, credential loss, or removal of one source
  MUST NOT stop refresh or erase the last successful snapshot of another.
- `MSR-004` A failed source with a prior snapshot MUST retain that snapshot as
  stale. A failed source without prior data MUST remain distinguishable from a
  healthy empty source.

### Aggregate status

- `AGG-001` Menu-bar severity and counts MUST be derived from all enabled
  sources and MUST exclude disabled sources.
- `AGG-002` Issue rows MUST identify their source whenever more than one source
  is configured.
- `AGG-003` If any enabled source fails, the status surface MUST disclose the
  partial failure even when another source is healthy or has actionable issues.
- `AGG-004` When every configured source is disabled, IssueLight MUST say that
  no source is active rather than reporting a healthy system.

## Acceptance evidence

| Requirement | Public boundary | Current evidence |
| --- | --- | --- |
| SRC-001..006 | sources window and persisted source store | App-model tests cover draft, selection, append, disable, removal, isolation, and real Keychain scopes; running inspection covers two persisted sources, keyboard selection, long accessible labels, unsaved-change protection, and disabled-source presentation |
| MSR-001..004 | app refresh model through provider registry | Concurrent app-model tests cover every enabled source, per-source replacement, partial failure, stale retention, disable, and removal; the live lab refreshes two persisted sources through the built-in Icinga 2 provider; an installed signed app retained a successful snapshot after exact Keychain-password revocation and failed explicitly without stale data after relaunch |
| AGG-001..004 | menu bar and menu panel | App-model tests cover aggregation and all-disabled behavior; running all-disabled inspection passes; multi-source normal, stale, and partial-failure combinations remain open |
