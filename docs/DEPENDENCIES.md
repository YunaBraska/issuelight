# Dependencies

IssueLight currently has no third-party runtime library dependencies.

| Component | Purpose | Distribution impact |
| --- | --- | --- |
| Swift and SwiftUI | Application and interface | Apple SDK/toolchain |
| Foundation and Security | Networking, persistence, and Keychain | Apple SDK/toolchain |
| XcodeGen | Generates the checked-in Xcode project from `project.yml` | Development only, not shipped |
| Official Icinga 2, Icinga DB, and Icinga Web container images | External-system compatibility tests | Development only, not shipped |
| MariaDB and Redis container images | Icinga DB test persistence and transport | Development only, not shipped |
| Nginx container image | Loopback-only authentication gateway for manual Icinga Web review | Development only, not shipped |

The exact integration image versions and digests are pinned in
`integration/icinga2/compose.yaml`. Any new runtime dependency requires a
purpose, license review, provenance record, and removal plan before it is added.
