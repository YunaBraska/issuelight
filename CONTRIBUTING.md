# Contributing

IssueLight accepts focused bug fixes, tests, documentation corrections, and
small vertical product improvements.

## Local checks

Run before opening a pull request:

```sh
swift test --package-path Packages/IssueLightCore
xcodebuild build \
  -project IssueLight/IssueLight.xcodeproj \
  -scheme IssueLight \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
git diff --check
```

When `IssueLight/project.yml` changes, run XcodeGen and commit the generated
project changes. Never commit `.env.local`, certificates, private keys,
passwords, monitoring URLs, or production data.

Behavior changes need observable acceptance criteria and regression evidence.
Provider work must keep vendor data out of shared models and register through
the single built-in provider registry.

By submitting a contribution, you agree that it is licensed under Apache-2.0.
See [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) for community expectations.
