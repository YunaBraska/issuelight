# ADR 0001: Sources Use a Provider Boundary

Status: Accepted.

Date: 2026-11-10.

## Context

IssueLight must support Icinga 2 first without making the application an Icinga
front end forever. Provider-specific credentials, transport, parsing, and
actions would otherwise leak into shared persistence and UI state.

Icinga 2 is the first required backend, while Nagios-compatible and other tools
must remain possible. There is no current requirement for third-party binary
plug-ins.

## Decision

Build the new implementation behind a small provider-neutral source model and a
single registry of built-in providers.

Shared code owns source lifecycle, persistence semantics, refresh policy,
connection results, and presentation state. Providers own endpoint constraints,
transport details, authentication challenges, response decoding, and optional
capabilities.

The core is a local Swift package. Complete user journeys cross the provider
boundary through public, provider-neutral values.

Dynamic plug-in loading is excluded until a real third-party extension
requirement exists.

## Consequences

- Icinga 2 can be implemented and tested without making it the shared data
  model.
- A second provider changes one adapter and one registration point.
- Secrets and TLS behavior have one modern boundary instead of inheriting the
  existing global connection manager.
- Provider-specific behavior stays testable without a running UI.
