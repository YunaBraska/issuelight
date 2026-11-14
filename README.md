# IssueLight

[![CI](https://github.com/YunaBraska/issuelight/actions/workflows/ci.yml/badge.svg)](https://github.com/YunaBraska/issuelight/actions/workflows/ci.yml)
[![Product Pages](https://github.com/YunaBraska/issuelight/actions/workflows/product-pages.yml/badge.svg)](https://github.com/YunaBraska/issuelight/actions/workflows/product-pages.yml)

[Product page](https://yunabraska.github.io/issuelight/) ·
[Documentation](https://yunabraska.github.io/issuelight/documentation.html) ·
[Source](https://github.com/YunaBraska/issuelight)

IssueLight is a native macOS menu bar client for infrastructure monitoring. It
stays quiet when systems are healthy and brings actionable problems forward
when attention is required.

Icinga 2 is the first supported provider. The core keeps provider-specific
transport, authentication, and response handling behind a small built-in
provider boundary so future providers do not leak into shared UI or storage.

IssueLight is under active development. Source setup, macOS Keychain-backed
credentials, strict-by-default TLS, source-specific private CAs, optional
exact server-certificate pinning, optional per-source certificate bypass, and a
real containerized Icinga 2 compatibility lab are implemented. The menu-bar
panel aggregates independently refreshed sources and exposes explicit Icinga 2
recheck, acknowledgement, and fixed-downtime actions per issue. Notifications,
web deep links, and additional providers remain outside the current release.
The universal ZIP/DMG/SBOM workflow is ready for signing credentials.

## Requirements

- macOS 14 or newer
- System-default language or one of 21 built-in languages
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

Run the complete local CI contract with `sh scripts/check.sh`. The real Icinga 2 matrix is documented in
[`integration/icinga2/README.md`](integration/icinga2/README.md).

## Project documentation

- [`docs/PROJECT_STATUS.md`](docs/PROJECT_STATUS.md): implemented behavior and current release blockers
- [`docs/spec/source-connection.md`](docs/spec/source-connection.md): accepted source and security behavior
- [`docs/spec/attention-snapshot.md`](docs/spec/attention-snapshot.md): attention and refresh behavior
- [`docs/spec/multiple-sources.md`](docs/spec/multiple-sources.md): multiple-source management and aggregation
- [`docs/spec/release-lifecycle.md`](docs/spec/release-lifecycle.md): supported installation and update behavior
- [`docs/spec/nagbar-parity.md`](docs/spec/nagbar-parity.md): retained NagBar journeys and deliberate simplifications
- [`docs/adr/0007-runtime-language-selection.md`](docs/adr/0007-runtime-language-selection.md): in-app language selection and localization boundary
- [`docs/adr/`](docs/adr/): lasting architecture decisions
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md): local build and release-candidate verification
- [`docs/site/`](docs/site/): GitHub Pages product site and reproducible app screenshots
- [`CONTRIBUTING.md`](CONTRIBUTING.md): contributor workflow
- [`SECURITY.md`](SECURITY.md): private vulnerability reporting
- [`PRIVACY.md`](PRIVACY.md): network and local-data behavior

## License

IssueLight is licensed under the Apache License 2.0. See [`LICENSE`](LICENSE)
and [`NOTICE`](NOTICE).
