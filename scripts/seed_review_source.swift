import Foundation

@main
enum SeedReviewSource {
    static func main() async throws {
        guard CommandLine.arguments.count == 4,
              let port = Int(CommandLine.arguments[2]),
              let webPort = Int(CommandLine.arguments[3]),
              (1...65_535).contains(port),
              (1...65_535).contains(webPort),
              let endpoint = URL(string: "https://localhost:\(port)"),
              let webBaseURL = URL(string: "http://localhost:\(webPort)/icingaweb2/icingadb")
        else {
            FileHandle.standardError.write(
                Data("Usage: seed-review-source <sources.json> <api-port> <web-port>\n".utf8)
            )
            Foundation.exit(64)
        }

        let source = MonitoringSource(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            name: "Local Icinga 2 Review Lab",
            providerID: ProviderID(rawValue: "icinga2"),
            endpoint: endpoint,
            authentication: .basic(username: "issuelight-basic"),
            serverTrust: .disabled,
            web: MonitoringWebConfiguration(baseURL: webBaseURL)
        )
        let store = SourceStore(fileURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        _ = try await store.save([source])
    }
}
