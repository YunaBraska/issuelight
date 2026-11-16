# ADR 0009: Use quiet source-scoped notifications

Status: Accepted

## Context

IssueLight runs continuously in the menu bar. Repeating every unhealthy object
would reproduce the alert noise the product is intended to remove. Notification
content can also become visible on a locked or shared screen, so monitoring
names, provider output, and navigation URLs do not belong in the system banner.

The notification path must still preserve source-specific severity choices,
survive ordinary relaunches, and open an issue through the same provider and SSH
access behavior as the menu panel.

## Decision

Notifications are disabled by default and configured per source. Selecting the
first non-disabled policy is the only action that requests macOS authorization.
The available policies are critical only, warning and critical, or all
attention states.

The first successful snapshot in each app session establishes a baseline.
After that baseline, a new eligible issue or a severity escalation replaces one
stable source notification. Unchanged issues do not repeat. Full recovery,
source or policy disablement, and source removal delete the delivered summary.
IssueLight clears old delivered summaries when a new app session starts.

Banner content contains only an aggregate count and a prompt to inspect
IssueLight. It contains no source, host, service, provider output, credential,
or URL. Critical summaries use the active interruption level. Other summaries
are passive. No notification requests a sound.

Navigation targets remain in memory for the current session. A notification
response resolves the current source and passes through the same direct-first
web and automatic SSH-tunnel coordinator as a panel row. No infrastructure URL
is stored in notification metadata.

Only the per-source policy map is persisted in macOS preferences. The map is
reconciled after source storage has finished loading, never against the initial
empty publisher value.

## Consequences

An issue already present when IssueLight starts does not create a banner. Its
menu-bar count remains the authoritative current signal. Restarting the app
clears older IssueLight summaries and establishes a fresh baseline instead of
replaying existing failures.

Notification policy does not duplicate monitoring state. Deduplication and
navigation state are intentionally session-local, which avoids persisting
object identities or infrastructure URLs.

The settings surface must expose macOS authorization separately from each
source policy and explain the quiet, detail-free behavior in one short note.
