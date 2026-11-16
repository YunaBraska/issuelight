# NagBar compatibility and product scope

Status: Reviewed against `volendavidov/NagBar` and the maintained
`YunaBraska/NagBar` fork on 2026-11-14.

IssueLight is not a visual rewrite of NagBar. It preserves the useful operator
journey while replacing unsafe or noisy behavior. Missing provider and
real-system qualification journeys remain release blockers rather than
deliberate omissions.

## Capability matrix

| Capability | NagBar | IssueLight status | Decision |
| --- | --- | --- | --- |
| Native macOS menu-bar status | Done | Done | Keep the quiet, attention-first IssueLight presentation. |
| Host and service problem state | Done | Done | Provider-neutral model with deterministic severity and ordering. |
| Multiple monitoring sources | Done | Done | Independent credentials, refresh, stale state, and failure reporting. |
| Icinga 2 API | Done | Done | First fully supported provider and current compatibility baseline. |
| Issue row details | Done | Mostly done | Always show source, host, service, state, state duration, check attempt, first output line, acknowledgement, and downtime. Add check age later as a stale-data signal instead of another timestamp column. |
| Nagios Core and Icinga Classic | Done | Partial through Thruk | Thruk-backed installations use its documented REST API. Direct legacy support still needs a complete compatibility slice without reviving the original app's brittle HTML parser. |
| Thruk | Done | Done | The REST adapter owns discovery, Basic and API-key authentication, snapshots, commands, and web links. The pinned official OMD Labs image verifies real Thruk and Naemon behavior. Basic sources are read-only; API-key sources expose commands. |
| Checkmk | Done | Done | The REST adapter owns versioned endpoint discovery, API-key authentication, snapshots, acknowledgement, downtime, and web links. The pinned official Checkmk Community image verifies the real API and monitoring core. |
| Text search | Partial | Done | Keep search in the panel's first row and match display name, host, output, and source. |
| State and property filters | Done | Done | Persist the compact source, severity, and coverage filters. Do not reproduce NagBar's large filter matrix. |
| Acknowledge, recheck, and downtime | Done | Implemented per provider capability | Icinga 2 and Thruk expose all three commands. Checkmk exposes acknowledgement and downtime because its supported REST API has no recheck action. Every confirmed command refreshes its source. |
| Open object in monitoring web UI | Done | Implemented for all built-in providers | A row click opens the provider-built object URL. Each source may override the provider default. |
| SSH and RDP target actions | Done | Done | Keep them optional per source and use the operating system's registered URL handlers. |
| SSH port forwarding | Partial | Done for API and reachability checks, plus HTTP web targets | Try direct first, then reuse one source-owned OpenSSH SOCKS5 session. API TLS keeps its original hostname. External-browser HTTPS remains direct-only because rewriting the hostname would invalidate certificate identity checks. |
| Native notifications | Done | Done | Disabled by default, explicit per-source severity policies, first-snapshot suppression, escalation detection, stable source summaries, recovery cleanup, and private banner content. |
| Audible alarms and status flashing | Done | Dismissed | They create noise and accessibility problems. Native notifications are the replacement. |
| Configurable refresh interval | Done | Partial | IssueLight owns one conservative refresh loop. A small preset choice is reasonable only if measured deployments need it. |
| Keychain credentials | Partial | Done | Passwords, API keys, and identity references remain in macOS Keychain. Public source JSON contains no secrets. |
| TLS verification controls | Partial | Done | System trust by default, private CA, exact leaf pin, and an explicit per-source insecure mode. |
| Protected mTLS private keys | Partial | Partial | Normal mTLS, non-interactive lookup, locked-Keychain skipping, and prompt-free test isolation pass. Deterministic installed-app denial during protected-key signing remains open. |
| Stale and partial failure state | Partial | Done | Keep the last successful snapshot and identify the failing source instead of replacing status with one global error. |
| User-defined status colors | Done | Dismissed | Use semantic system colors and symbols so dark mode, contrast, and accessibility stay coherent. |
| Configurable columns and output length | Done | Dismissed | Keep one scannable row hierarchy and bounded output instead of exposing layout internals as preferences. |
| Dock-icon toggle | Done | Dismissed | IssueLight is a menu-bar utility and remains an `LSUIElement` app. |
| Automatic update check | Done | Done for direct builds | Direct releases use a signed Sparkle feed. App Store builds contain no Sparkle runtime and use Apple's update channel. A published replacement cycle remains a release gate. |

## Current parity conclusion

IssueLight covers NagBar's central Icinga 2 journey and implements the same
provider-neutral journey for Thruk and Checkmk. It improves multiple-source isolation,
failure handling, credential storage, and TLS trust. It is not functionally
equivalent to NagBar today because a direct Nagios Core provider is still absent.

Claiming full parity or production readiness before those capabilities exist
would be inaccurate.

## Recommended delivery order

1. Close the protected-key and signed-app verification gaps without weakening
   background security.
2. Add Nagios Core without introducing a binary plug-in SDK.

The existing visual hierarchy should remain. New actions belong in row context
menus or a small detail surface. Settings should describe sources and policies,
not expose every rendering choice.
