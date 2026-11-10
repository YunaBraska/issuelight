# Dependencies

IssueLight currently has no third-party runtime library dependencies.

| Component | Purpose | Distribution impact |
| --- | --- | --- |
| Swift and SwiftUI | Application and interface | Apple SDK/toolchain |
| Foundation and Security | Networking, persistence, and Keychain | Apple SDK/toolchain |
| XcodeGen | Generates the checked-in Xcode project from `project.yml` | Development only, not shipped |
| Official Icinga 2 container image | External-system compatibility tests | Development only, not shipped |

The exact Icinga image is pinned in `integration/icinga2/compose.yaml`. Any new
runtime dependency requires a purpose, license review, provenance record, and
removal plan before it is added.
