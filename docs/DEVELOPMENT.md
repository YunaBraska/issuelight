# Development

## Repository layout

- `IssueLight/`: native macOS app and XcodeGen specification
- `Packages/IssueLightCore/`: provider-neutral domain and Icinga 2 adapter
- `integration/icinga2/`: real external-system test lab
- `docs/spec/`: accepted observable behavior
- `docs/adr/`: lasting architecture decisions

## Normal workflow

Run package tests first, then the app build. Live integration is separate so
ordinary unit work does not start Docker or modify Keychain identities.

```sh
swift test --package-path Packages/IssueLightCore
xcodebuild test -project IssueLight/IssueLight.xcodeproj \
  -scheme IssueLight -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild build -project IssueLight/IssueLight.xcodeproj \
  -scheme IssueLight -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Use a stable Apple Development identity and the fixed bundle identifier
`io.github.yunabraska.issuelight` for permission-sensitive installed-app tests.
Keep team identifiers and certificate fingerprints outside Git in ignored local
configuration.

See [`../integration/icinga2/README.md`](../integration/icinga2/README.md) for
the real Icinga compatibility matrix.
