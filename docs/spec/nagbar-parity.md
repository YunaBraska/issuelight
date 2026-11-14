# NagBar compatibility and product scope

Status: Reviewed against `volendavidov/NagBar` and the maintained
`YunaBraska/NagBar` fork on 2026-11-14.

IssueLight is not a visual rewrite of NagBar. It preserves the useful operator
journey, replaces unsafe or noisy behavior, and keeps the first supported
release deliberately smaller.

## Capability matrix

| Capability | NagBar | IssueLight status | Decision |
| --- | --- | --- | --- |
| Native macOS menu-bar status | Done | Done | Keep the quiet, attention-first IssueLight presentation. |
| Host and service problem state | Done | Done | Provider-neutral model with deterministic severity and ordering. |
| Multiple monitoring sources | Done | Done | Independent credentials, refresh, stale state, and failure reporting. |
| Icinga 2 API | Done | Done | First fully supported provider and current compatibility baseline. |
| Issue row details | Done | Mostly done | Always show source, host, service, state, state duration, check attempt, first output line, acknowledgement, and downtime. Add check age later as a stale-data signal instead of another timestamp column. |
| Nagios CGI and Icinga Classic | Done | Planned | Add only after the shared Icinga read journey and provider contract are stable. |
| Thruk and Checkmk | Done | Planned | Same provider rule. No provider-specific state in shared UI or persistence. |
| Text search | Partial | Done | Keep search in the panel's first row and match display name, host, output, and source. |
| State and property filters | Done | Done | Persist the compact source, severity, and coverage filters. Do not reproduce NagBar's large filter matrix. |
| Acknowledge, recheck, and downtime | Done | Done for Icinga 2 | Provider capabilities expose the supported commands. Acknowledgement and downtime require explicit input; every confirmed command refreshes its source. |
| Open object in monitoring web UI | Done | Done for Icinga 2 | A row click opens the provider-built object URL. Each source owns its web base URL. Classic Monitoring and Icinga DB Web routes are supported. |
| SSH and RDP target actions | Done | Done | Keep them optional per source and use the operating system's registered URL handlers. |
| SSH port forwarding | Partial | Done for HTTP web targets | Try the direct route first, then own one loopback-only OpenSSH forward per source. HTTPS targets fail closed because rewriting the browser host would invalidate normal certificate identity checks. |
| Native notifications | Done | Planned | Quiet defaults, per-source severity policy, deduplication, and recovery behavior. |
| Audible alarms and status flashing | Done | Dismissed | They create noise and accessibility problems. Native notifications are the replacement. |
| Configurable refresh interval | Done | Partial | IssueLight owns one conservative refresh loop. A small preset choice is reasonable only if measured deployments need it. |
| Keychain credentials | Partial | Done | Passwords and identity references remain in macOS Keychain. Public source JSON contains no secrets. |
| TLS verification controls | Partial | Done | System trust by default, private CA, exact leaf pin, and an explicit per-source insecure mode. |
| Protected mTLS private keys | Partial | Partial | Normal mTLS, non-interactive lookup, locked-Keychain skipping, and prompt-free test isolation pass. Deterministic installed-app denial during protected-key signing remains open. |
| Stale and partial failure state | Partial | Done | Keep the last successful snapshot and identify the failing source instead of replacing status with one global error. |
| User-defined status colors | Done | Dismissed | Use semantic system colors and symbols so dark mode, contrast, and accessibility stay coherent. |
| Configurable columns and output length | Done | Dismissed | Keep one scannable row hierarchy and bounded output instead of exposing layout internals as preferences. |
| Dock-icon toggle | Done | Dismissed | IssueLight is a menu-bar utility and remains an `LSUIElement` app. |
| Automatic update check | Done | Dismissed for first release | Use the explicit signed release channel until the update mechanism itself can be secured and supported. |

## Current parity conclusion

IssueLight covers NagBar's central Icinga 2 monitoring, navigation, filtering,
remote-login, and operator-action journeys and improves multiple-source
isolation, failure handling, credential storage, and TLS trust. It is not
functionally equivalent to NagBar today because notifications and four legacy
provider families are absent.

That difference is intentional for the first release. Claiming full parity
before those capabilities exist would be inaccurate.

## Recommended delivery order

1. Close the protected-key and signed-app verification gaps without weakening
   background security.
2. Add quiet native notifications with deduplication and recovery semantics.
3. Add the second provider as one complete vertical slice. Use that evidence to
   refine the existing provider boundary instead of introducing a plugin SDK.

The existing visual hierarchy should remain. New actions belong in row context
menus or a small detail surface. Settings should describe sources and policies,
not expose every rendering choice.
