import Foundation
import Observation

struct UploadRecord: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = UUID()
    var identifier: String
    var title: String
    var date: Date
    var fileCount: Int
    var totalBytes: Int64

    var itemURL: URL? {
        URL(string: "https://archive.org/details/\(identifier)")
    }
}

@MainActor
@Observable
final class UploadHistory {
    private static let storageKey = "IAUploader.history.v1"
    private let defaults: UserDefaults
    private(set) var records: [UploadRecord] = []

    init(defaults: UserDefaults = AppPaths.defaults) {
        self.defaults = defaults
        load()
    }

    func add(identifier: String, title: String, fileCount: Int, totalBytes: Int64) {
        records.insert(
            UploadRecord(
                identifier: identifier,
                title: title,
                date: Date(),
                fileCount: fileCount,
                totalBytes: totalBytes
            ),
            at: 0
        )
        if records.count > 25 {
            records.removeLast(records.count - 25)
        }
        save()
    }

    /// Adds a finished file to today's record for the item, creating it if needed.
    func recordFile(identifier: String, title: String, bytes: Int64) {
        if let index = records.firstIndex(where: { $0.identifier == identifier && Calendar.current.isDateInToday($0.date) }) {
            var record = records.remove(at: index)
            record.fileCount += 1
            record.totalBytes += bytes
            record.date = Date()
            if !title.isEmpty { record.title = title }
            records.insert(record, at: 0)
            save()
        } else {
            add(identifier: identifier, title: title, fileCount: 1, totalBytes: bytes)
        }
    }

    func remove(_ ids: Set<UUID>) {
        records.removeAll { ids.contains($0.id) }
        save()
    }

    func clear() {
        records.removeAll()
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([UploadRecord].self, from: data) else {
            return
        }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
