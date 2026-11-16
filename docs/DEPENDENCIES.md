# Dependencies

| Component | Purpose | Distribution impact |
| --- | --- | --- |
| Swift and SwiftUI | Application and interface | Apple SDK/toolchain |
| Foundation and Security | Networking, persistence, and Keychain | Apple SDK/toolchain |
| Sparkle 2.10.0 | Signed updates for direct GitHub releases | Pinned runtime dependency in the direct app only; excluded from the App Store target |
| XcodeGen | Generates the checked-in Xcode project from `project.yml` | Development only, not shipped |
| Official Icinga 2, Icinga DB, and Icinga Web container images | External-system compatibility tests | Development only, not shipped |
| MariaDB and Redis container images | Icinga DB test persistence and transport | Development only, not shipped |
| Nginx container image | Loopback-only authentication gateway for manual Icinga Web review | Development only, not shipped |
| Official OMD Labs Debian image | Real Thruk and Naemon compatibility tests | Development and CI only, not shipped |
| Official Checkmk Community image | Real Checkmk REST API and monitoring-core compatibility tests | Development and CI only, not shipped |

Thruk support uses its HTTP REST API and adds no runtime dependency. A pinned
official OMD Labs fixture qualifies the adapter against Thruk 3.30 and its real
Livestatus and command responses.

The exact integration image versions and digests are pinned in
`integration/icinga2/compose.yaml`, `scripts/thruk_lab.sh`, and
`scripts/checkmk_lab.sh`. Any new runtime dependency requires a
purpose, license review, provenance record, and removal plan before it is added.
Sparkle's complete distribution license is shipped as
`IssueLight/Resources/Sparkle-LICENSE.txt` in direct builds.
