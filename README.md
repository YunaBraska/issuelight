# IssueLight

[![Snapshot](https://github.com/YunaBraska/issuelight/actions/workflows/build-merge.yml/badge.svg)](https://github.com/YunaBraska/issuelight/actions/workflows/build-merge.yml)
[![Product Pages](https://github.com/YunaBraska/issuelight/actions/workflows/product-pages.yml/badge.svg)](https://github.com/YunaBraska/issuelight/actions/workflows/product-pages.yml)

[Product page](https://yunabraska.github.io/issuelight/) ·
[Documentation](https://yunabraska.github.io/issuelight/documentation.html) ·
[Source](https://github.com/YunaBraska/issuelight)

IssueLight is a native macOS menu bar client for infrastructure monitoring. It
stays quiet when systems are healthy and brings actionable problems forward
when attention is required.

Icinga 2 is the compatibility baseline. Built-in Thruk, Checkmk, and Nagios Core
adapters implement their documented HTTP interfaces. The core keeps
provider-specific transport, authentication, discovery, and response handling
behind one provider boundary so new providers do not leak into shared UI or
storage.

IssueLight supports Icinga 2, Thruk, Checkmk, and Nagios Core through real HTTP
interfaces and containerized compatibility labs. Credentials stay in macOS
Keychain. TLS verification is strict by default, with source-specific CA,
certificate pinning, and explicit bypass options.

The menu-bar panel combines independently refreshed sources, persistent filters,
quiet notifications, web links, and provider-supported quick actions. The direct
edition can use SSH for source access and launch optional SSH or RDP host
actions. Signed direct releases update through Sparkle. The sandboxed App Store
edition uses Apple's update channel and excludes external-tool features.

## Requirements

- macOS 14 or newer
- System-default language or one of 21 built-in languages
- Xcode 16 or newer
- XcodeGen 2.45 or newer when changing `IssueLight/project.yml`
- Docker with Compose for the optional real-system integration labs

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

Run the complete local CI contract with `sh scripts/check.sh`. The real-system
matrices are documented in
[`integration/icinga2/README.md`](integration/icinga2/README.md) and
[`integration/thruk/README.md`](integration/thruk/README.md). The Checkmk lab is
documented in [`integration/checkmk/README.md`](integration/checkmk/README.md),
and the Nagios Core lab in
[`integration/nagioscore/README.md`](integration/nagioscore/README.md).

## Project documentation

- [`docs/spec/source-connection.md`](docs/spec/source-connection.md): accepted source and security behavior
- [`docs/spec/attention-snapshot.md`](docs/spec/attention-snapshot.md): attention and refresh behavior
- [`docs/spec/multiple-sources.md`](docs/spec/multiple-sources.md): multiple-source management and aggregation
- [`docs/spec/release-lifecycle.md`](docs/spec/release-lifecycle.md): supported installation and update behavior
- [`docs/spec/nagbar-parity.md`](docs/spec/nagbar-parity.md): retained NagBar journeys and deliberate simplifications
- [`docs/adr/0007-runtime-language-selection.md`](docs/adr/0007-runtime-language-selection.md): in-app language selection and localization boundary
- [`docs/adr/`](docs/adr/): lasting architecture decisions
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md): build, verification, and remaining manual acceptance
- [`docs/site/`](docs/site/): GitHub Pages product site and reproducible app screenshots
- [`CONTRIBUTING.md`](CONTRIBUTING.md): contributor workflow
- [`SECURITY.md`](SECURITY.md): private vulnerability reporting
- [`PRIVACY.md`](PRIVACY.md): network and local-data behavior

## License

IssueLight is licensed under the Apache License 2.0. See [`LICENSE`](LICENSE)
and [`NOTICE`](NOTICE).

## Acknowledgements

Thank you to [Volen Davidov and the original NagBar project](https://github.com/volendavidov/NagBar)
for the idea and inspiration behind a native macOS monitoring client.
