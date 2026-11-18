import Foundation

enum SourceNameSuggestion {
    static let creativeDefaults = [
        "Production", "Beacon", "Watchtower", "Sentinel", "Night Watch", "Signal Post",
        "North Star", "Harbor Light", "Lookout", "Pulse", "Early Warning",
        "Control Room", "Guardrail", "Ops Lantern", "Skyline", "Radar",
        "Firewatch", "Signal Tower", "Safe Harbor", "Observer", "Lifeline",
        "Pathfinder", "Overwatch", "Heartbeat", "High Ground",
    ]

    static func name(
        rawEndpoint: String,
        providerName: String,
        sourceID: UUID
    ) -> String {
        let trimmedEndpoint = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedEndpoint.isEmpty {
            let value = trimmedEndpoint.contains("://")
                ? trimmedEndpoint
                : "https://\(trimmedEndpoint)"
            if let host = URLComponents(string: value)?.host,
               !host.isEmpty {
                return name(host: host, providerName: providerName)
            }
        }

        let index = sourceID.uuidString.utf8.reduce(0) { partialResult, byte in
            (partialResult + Int(byte)) % creativeDefaults.count
        }
        return creativeDefaults[index]
    }

    static func name(host: String, providerName: String) -> String {
        let normalizedHost = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if ["localhost", "127.0.0.1", "::1"].contains(normalizedHost) {
            return "Local \(providerName)"
        }
        if normalizedHost.range(of: #"^\d{1,3}(?:\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
            return normalizedHost
        }

        let firstLabel = normalizedHost.split(separator: ".").first.map(String.init) ?? normalizedHost
        let words = firstLabel
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map(String.init)
            .filter { !$0.isEmpty }
            .prefix(3)
            .map { word in
                switch word {
                case "prod", "prd": return "Production"
                case "dev": return "Development"
                case "stage", "staging", "stg": return "Staging"
                case "qa": return "QA"
                default: return word.prefix(1).uppercased() + word.dropFirst()
                }
            }
        let candidate = words.joined(separator: " ")
        return candidate.isEmpty ? normalizedHost : candidate
    }
}
