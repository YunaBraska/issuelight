import Foundation

public enum SourceStoreError: Error, Equatable {
    case duplicateSourceID(UUID)
}

public actor SourceStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL(bundleIdentifier: String) throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("sources.json", isDirectory: false)
    }

    public func load() throws -> [MonitoringSource] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let sources = try JSONDecoder().decode([MonitoringSource].self, from: Data(contentsOf: fileURL))
        try validateUniqueIDs(sources)
        return sources
    }

    @discardableResult
    public func save(_ sources: [MonitoringSource]) throws -> [MonitoringSource] {
        try validateUniqueIDs(sources)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sources).write(to: fileURL, options: [.atomic, .completeFileProtection])
        return sources
    }

    @discardableResult
    public func upsert(_ source: MonitoringSource) throws -> [MonitoringSource] {
        var sources = try load()
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        return try save(sources)
    }

    @discardableResult
    public func remove(id: UUID) throws -> [MonitoringSource] {
        let sources = try load().filter { $0.id != id }
        return try save(sources)
    }

    private func validateUniqueIDs(_ sources: [MonitoringSource]) throws {
        var ids = Set<UUID>()
        for source in sources where !ids.insert(source.id).inserted {
            throw SourceStoreError.duplicateSourceID(source.id)
        }
    }
}
