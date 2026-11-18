#!/usr/bin/env swift

import Foundation

guard CommandLine.arguments.count == 6 else {
    FileHandle.standardError.write(
        Data("Usage: generate_spdx_sbom.swift VERSION BUILD_NUMBER REVISION SPARKLE_VERSION OUTPUT\n".utf8)
    )
    exit(64)
}

let version = CommandLine.arguments[1]
let buildNumber = CommandLine.arguments[2]
let revision = CommandLine.arguments[3]
let sparkleVersion = CommandLine.arguments[4]
let outputPath = CommandLine.arguments[5]

guard version.range(
    of: "^[A-Za-z0-9][A-Za-z0-9._-]*$",
    options: .regularExpression
) != nil,
    buildNumber.range(of: "^[1-9][0-9]*$", options: .regularExpression) != nil,
    revision.range(of: "^[0-9a-f]{7,64}$", options: .regularExpression) != nil,
    sparkleVersion.range(of: "^[0-9]+(?:\\.[0-9]+){1,3}$", options: .regularExpression) != nil
else {
    FileHandle.standardError.write(Data("Version, revision, or Sparkle version is invalid.\n".utf8))
    exit(65)
}

let timestamp = ISO8601DateFormatter().string(from: Date())
let document: [String: Any] = [
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0",
    "SPDXID": "SPDXRef-DOCUMENT",
    "name": "IssueLight-\(version)",
    "documentNamespace": "https://spdx.org/spdxdocs/issuelight-\(version)-\(buildNumber)-\(revision)",
    "creationInfo": [
        "created": timestamp,
        "creators": ["Tool: IssueLight release packaging"],
    ],
    "packages": [
        [
            "name": "IssueLight",
            "SPDXID": "SPDXRef-Package-IssueLight",
            "versionInfo": "\(version) (\(buildNumber))",
            "downloadLocation": "https://github.com/YunaBraska/issuelight/tree/\(revision)",
            "filesAnalyzed": false,
            "licenseConcluded": "Apache-2.0",
            "licenseDeclared": "Apache-2.0",
            "copyrightText": "Copyright 2026 Yuna Morgenstern and IssueLight contributors",
            "externalRefs": [
                [
                    "referenceCategory": "PACKAGE-MANAGER",
                    "referenceType": "purl",
                    "referenceLocator": "pkg:github/YunaBraska/issuelight@\(revision)",
                ],
            ],
        ],
        [
            "name": "Sparkle",
            "SPDXID": "SPDXRef-Package-Sparkle",
            "versionInfo": sparkleVersion,
            "downloadLocation": "https://github.com/sparkle-project/Sparkle/releases/tag/\(sparkleVersion)",
            "filesAnalyzed": false,
            "licenseConcluded": "NOASSERTION",
            "licenseDeclared": "NOASSERTION",
            "copyrightText": "Copyright Sparkle contributors",
            "externalRefs": [
                [
                    "referenceCategory": "PACKAGE-MANAGER",
                    "referenceType": "purl",
                    "referenceLocator": "pkg:github/sparkle-project/Sparkle@\(sparkleVersion)",
                ],
            ],
        ],
    ],
    "relationships": [
        [
            "spdxElementId": "SPDXRef-DOCUMENT",
            "relationshipType": "DESCRIBES",
            "relatedSpdxElement": "SPDXRef-Package-IssueLight",
        ],
        [
            "spdxElementId": "SPDXRef-Package-IssueLight",
            "relationshipType": "DEPENDS_ON",
            "relatedSpdxElement": "SPDXRef-Package-Sparkle",
        ],
    ],
]

do {
    let data = try JSONSerialization.data(
        withJSONObject: document,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
} catch {
    FileHandle.standardError.write(Data("Could not write SPDX SBOM: \(error)\n".utf8))
    exit(74)
}
