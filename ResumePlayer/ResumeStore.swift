import Foundation

actor ResumeStore {
    private struct Record: Codable {
        var bookmarkData: Data
        var position: TimeInterval
    }

    private struct ResolvedRecord {
        let url: URL
        let refreshedBookmarkData: Data?
    }

    private let storageURL: URL

    init(storageURL: URL) {
        self.storageURL = storageURL
    }

    func save(position: TimeInterval, duration: TimeInterval, for url: URL) throws {
        let records = try loadRecords()
        var refreshedRecords = records

        let matchingIndexes = matchingRecordIndexes(
            in: records,
            for: url,
            updating: &refreshedRecords
        )

        for index in matchingIndexes.reversed() {
            refreshedRecords.remove(at: index)
        }

        if ResumePositionPolicy.shouldSave(position: position, duration: duration) {
            let bookmarkData = try makeBookmarkData(for: url)
            refreshedRecords.append(Record(bookmarkData: bookmarkData, position: position))
        }

        try writeRecords(refreshedRecords)
    }

    func position(for url: URL) throws -> TimeInterval? {
        let records = try loadRecords()
        var refreshedRecords = records
        var didRefresh = false

        for index in records.indices {
            guard let resolved = resolve(records[index]) else { continue }

            if let bookmarkData = resolved.refreshedBookmarkData {
                refreshedRecords[index].bookmarkData = bookmarkData
                didRefresh = true
            }

            if resolved.url.standardizedFileURL == url.standardizedFileURL {
                if didRefresh {
                    try writeRecords(refreshedRecords)
                }
                return records[index].position
            }
        }

        if didRefresh {
            try writeRecords(refreshedRecords)
        }
        return nil
    }

    private func loadRecords() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return []
        }

        return try JSONDecoder().decode([Record].self, from: Data(contentsOf: storageURL))
    }

    private func writeRecords(_ records: [Record]) throws {
        let parentDirectory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )

        let data = try JSONEncoder().encode(records)
        try data.write(to: storageURL, options: .atomic)
    }

    private func makeBookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [
                .withSecurityScope,
                .securityScopeAllowOnlyReadAccess
            ],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func matchingRecordIndexes(
        in records: [Record],
        for url: URL,
        updating refreshedRecords: inout [Record]
    ) -> [Int] {
        var matchingIndexes: [Int] = []

        for index in records.indices {
            guard let resolved = resolve(records[index]) else { continue }

            if let bookmarkData = resolved.refreshedBookmarkData {
                refreshedRecords[index].bookmarkData = bookmarkData
            }

            if resolved.url.standardizedFileURL == url.standardizedFileURL {
                matchingIndexes.append(index)
            }
        }

        return matchingIndexes
    }

    private func resolve(_ record: Record) -> ResolvedRecord? {
        var bookmarkDataIsStale = false

        guard let resolvedURL = try? URL(
            resolvingBookmarkData: record.bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &bookmarkDataIsStale
        ) else {
            return nil
        }

        let didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                resolvedURL.stopAccessingSecurityScopedResource()
            }
        }

        guard bookmarkDataIsStale else {
            return ResolvedRecord(url: resolvedURL, refreshedBookmarkData: nil)
        }

        let refreshedBookmarkData = try? makeBookmarkData(for: resolvedURL)
        return ResolvedRecord(url: resolvedURL, refreshedBookmarkData: refreshedBookmarkData)
    }
}
