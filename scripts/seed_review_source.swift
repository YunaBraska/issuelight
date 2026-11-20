import Foundation

@main
enum SeedReviewSource {
    static func main() async throws {
        guard CommandLine.arguments.count == 4,
              let port = Int(CommandLine.arguments[2]),
              let webPort = Int(CommandLine.arguments[3]),
              (1...65_535).contains(port),
              (1...65_535).contains(webPort)
        else {
            FileHandle.standardError.write(
                Data("Usage: seed-review-source <sources.json> <api-port> <web-port>\n".utf8)
            )
            Foundation.exit(64)
        }

        let source: [String: Any] = [
            "id": "11111111-1111-4111-8111-111111111111",
            "name": "Local Icinga 2 Review Lab",
            "providerID": "icinga2",
            "endpoint": "https://localhost:\(port)",
            "isEnabled": true,
            "authentication": ["basic": ["username": "issuelight-basic"]],
            "serverTrust": ["disabled": [:]],
            "web": ["baseURL": "http://localhost:\(webPort)/icingaweb2/icingadb"],
        ]
        let fileURL = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: [source],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
