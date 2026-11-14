# Roadmap

Status: Active.

| Milestone | Outcome | Exit evidence | Status |
| --- | --- | --- | --- |
| M0 | Independent OSS repository with stable product identity | Public repository, license, provenance, contributor docs, package tests, app build, CI | Complete |
| M1 | Secure Icinga 2 source setup | Real Keychain, strict TLS default, explicit insecure mode, Basic and mTLS lab matrix | Complete |
| M2 | Attention-first monitoring snapshot | Real Icinga host/service data, deterministic severity, refresh/cancellation, menu bar normal/empty/failure/stale states | Complete |
| M3 | Multiple source management | Add, edit, disable, test, and remove sources without losing unrelated credentials | Complete |
| M4 | Supported operator actions | Acknowledge and downtime through explicit provider capabilities with safe retry behavior | Planned |
| M5 | Native notification policy | Actionable, deduplicated notifications with quiet defaults and recovery behavior | Planned |
| M6 | Release candidate | Accessibility, 21-language catalog with runtime selection and RTL evidence, performance, privacy, packaging, signing, notarization, SBOM, clean-account smoke | In progress |

Work proceeds in complete journeys. A second provider is added only after M2
proves the shared read path, and it must change one adapter plus the built-in
registration point rather than shared persistence or presentation semantics.
