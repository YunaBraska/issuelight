# 0006: Use one stable application identity before public release

Status: Accepted

Date: 2026-11-13

## Context

IssueLight uses its bundle identifier for macOS application identity, the
Application Support directory, Keychain ownership metadata, release-package
validation, and permission-sensitive installed-app tests. Changing it after a
public release would split local state and could invalidate Keychain and macOS
permission attribution.

The earlier development identifier, `io.github.yunabraska.issuelight`, did not
follow the current application naming used by the owner's macOS projects.
IssueLight has not shipped a public release, so no supported migration contract
exists for that development identity.

## Decision

The stable IssueLight application bundle identifier and Keychain ownership
scope are `berlin.yuna.issuelight`.

Test bundles and isolated test ownership scopes append a descriptive suffix to
that identifier. Release packaging must reject any other application bundle
identifier. Permission-sensitive local tests must keep this application
identity and use a stable signing identity.

The earlier development identifier is not supported as a data-migration source.
Development builds created before this decision must be reconfigured. Their old
Application Support directory can be removed, while certificates imported by
the old app profile remain visible for manual review in Keychain Access.

## Consequences

- App metadata, local storage, Keychain ownership, tests, privacy documentation,
  SBOM generation, and release validation share one source identity.
- A future identity change requires an explicit migration and release decision.
- The repository name remains lowercase `issuelight`; the product name remains
  `IssueLight`.
