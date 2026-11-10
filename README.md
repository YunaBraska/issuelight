# IssueLight

IssueLight is a native macOS menu bar client for infrastructure monitoring. It
stays quiet when systems are healthy and brings actionable problems forward
when attention is required.

Icinga 2 is the first supported provider. The core keeps provider-specific
transport, authentication, and response handling behind a small built-in
provider boundary so future providers do not leak into shared UI or storage.

IssueLight is under active development. Source setup, macOS Keychain-backed
credentials, strict-by-default TLS, source-specific private CAs, optional
per-source certificate bypass, and a real containerized Icinga 2 compatibility
lab are implemented. The first attention-first host and service view now
aggregates independently refreshed, enabled sources. Notifications, Developer
ID signing, notarization, and end-user distribution are not yet release-ready.

## Requirements

- macOS 14 or newer
- Xcode 16 or newer
- XcodeGen 2.45 or newer when changing `IssueLight/project.yml`
- Docker with Compose for the optional real Icinga 2 integration matrix

## Build and test

```sh
swift test --package-path Packages/IssueLightCore
xcodebuild test \
  -project IssueLight/IssueLight.xcodeproj \
  -scheme IssueLight \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild build \
  -project IssueLight/IssueLight.xcodeproj \
  -scheme IssueLight \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Regenerate the Xcode project after changing `IssueLight/project.yml`:

```sh
xcodegen generate --spec IssueLight/project.yml
```

The real Icinga 2 matrix is documented in
[`integration/icinga2/README.md`](integration/icinga2/README.md).

## Project documentation

- [`docs/PROJECT_STATUS.md`](docs/PROJECT_STATUS.md): implemented behavior and current release blockers
- [`docs/roadmap.md`](docs/roadmap.md): vertical delivery order
- [`docs/spec/source-connection.md`](docs/spec/source-connection.md): accepted source and security behavior
- [`docs/spec/attention-snapshot.md`](docs/spec/attention-snapshot.md): attention and refresh behavior
- [`docs/spec/multiple-sources.md`](docs/spec/multiple-sources.md): multiple-source management and aggregation
- [`docs/adr/`](docs/adr/): lasting architecture decisions
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md): local build and release-candidate verification
- [`CONTRIBUTING.md`](CONTRIBUTING.md): contributor workflow
- [`SECURITY.md`](SECURITY.md): private vulnerability reporting
- [`PRIVACY.md`](PRIVACY.md): network and local-data behavior

## License

IssueLight is licensed under the Apache License 2.0. See [`LICENSE`](LICENSE)
and [`NOTICE`](NOTICE).
