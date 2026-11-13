import SwiftUI
import Observation

/// Remembers UI state (collapsed cards, expanded folders, filters, selected
/// panes) across tab switches and app launches. Views read and write it
/// through keys, scoped per tab with the `memoryScope` environment value.
@MainActor
@Observable
final class ViewMemory {
    static let shared = ViewMemory()

    private struct Snapshot: Codable {
        var flags: [String: Bool] = [:]
        var sets: [String: [String]] = [:]
        var strings: [String: String] = [:]
    }

    private static let storageKey = "IAUploader.viewMemory.v1"
    private let defaults: UserDefaults
    private var flags: [String: Bool]
    private var sets: [String: Set<String>]
    private var strings: [String: String]
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(defaults: UserDefaults = AppPaths.defaults) {
        self.defaults = defaults
        let snapshot = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
        flags = snapshot.flags
        sets = snapshot.sets.mapValues(Set.init)
        strings = snapshot.strings
    }

    // MARK: Flags

    func flag(_ key: String, default defaultValue: Bool) -> Bool {
        flags[key] ?? defaultValue
    }

    func setFlag(_ key: String, _ value: Bool) {
        guard flags[key] != value else { return }
        flags[key] = value
        scheduleSave()
    }

    func flagBinding(_ key: String, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { self.flag(key, default: defaultValue) },
            set: { self.setFlag(key, $0) }
        )
    }

    // MARK: Sets (expanded folders, collapsed groups…)

    func members(_ key: String) -> Set<String> {
        sets[key] ?? []
    }

    func contains(_ key: String, _ member: String) -> Bool {
        sets[key]?.contains(member) ?? false
    }

    func setMember(_ key: String, _ member: String, _ isMember: Bool) {
        var set = sets[key] ?? []
        let changed = isMember ? set.insert(member).inserted : (set.remove(member) != nil)
        guard changed else { return }
        sets[key] = set
        scheduleSave()
    }

    func replaceMembers(_ key: String, _ members: Set<String>) {
        guard sets[key] != members else { return }
        sets[key] = members
        scheduleSave()
    }

    func memberBinding(_ key: String, _ member: String) -> Binding<Bool> {
        Binding(
            get: { self.contains(key, member) },
            set: { self.setMember(key, member, $0) }
        )
    }

    // MARK: Strings

    func string(_ key: String, default defaultValue: String) -> String {
        strings[key] ?? defaultValue
    }

    func setString(_ key: String, _ value: String) {
        guard strings[key] != value else { return }
        strings[key] = value
        scheduleSave()
    }

    func stringBinding(_ key: String, default defaultValue: String) -> Binding<String> {
        Binding(
            get: { self.string(key, default: defaultValue) },
            set: { self.setString(key, $0) }
        )
    }

    // MARK: Persistence

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = Snapshot(flags: flags, sets: sets.mapValues { Array($0).sorted() }, strings: strings)
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
}

private struct MemoryScopeKey: EnvironmentKey {
    static let defaultValue = "global"
}

extension EnvironmentValues {
    /// Prefix for `ViewMemory` keys so cards with the same title on
    /// different tabs remember their state independently.
    var memoryScope: String {
        get { self[MemoryScopeKey.self] }
        set { self[MemoryScopeKey.self] = newValue }
    }
}
