import Foundation
import JournalDomain

/// Persists the prayer-note template catalog in UserDefaults and (optionally)
/// the iCloud key-value store, mirroring `KindCatalogStore`.
@MainActor
public final class PrayerTemplateStore {
    public static let key = "journal-prayer-templates"

    public private(set) var catalog: PrayerTemplateCatalog

    private let defaults: UserDefaults
    private let cloudStore: (any KindCatalogCloudStore)?

    public init(defaults: UserDefaults, cloudStore: (any KindCatalogCloudStore)?) {
        self.defaults = defaults
        self.cloudStore = cloudStore
        self.catalog =
            Self.decode(defaults.data(forKey: Self.key)) ?? PrayerTemplateCatalog()
        if cloudStore != nil {
            mergeFromCloud()
        }
    }

    /// Merges the local and cloud values. Returns true when the local catalog changed.
    @discardableResult
    public func mergeFromCloud() -> Bool {
        guard let cloudStore else { return false }
        cloudStore.synchronize()
        let cloudData = cloudStore.data(forKey: Self.key)
        let remote = Self.decode(cloudData)
        // Present but unreadable: leave the cloud value alone.
        if cloudData != nil && remote == nil { return false }
        // Compare round-tripped values so encoding differences never look like changes.
        let merged = Self.roundTripped(remote.map { catalog.merged(with: $0) } ?? catalog)
        let localChanged = merged != catalog
        let cloudStale = remote.map { merged != $0 } ?? (merged != PrayerTemplateCatalog())
        guard localChanged || cloudStale, let data = Self.encode(merged) else {
            return false
        }
        catalog = Self.decode(data) ?? merged
        if localChanged { defaults.set(data, forKey: Self.key) }
        if cloudStale {
            cloudStore.set(data, forKey: Self.key)
            cloudStore.synchronize()
        }
        return localChanged
    }

    public func save(_ catalog: PrayerTemplateCatalog) {
        guard let data = Self.encode(catalog) else {
            self.catalog = catalog
            return
        }
        self.catalog = Self.decode(data) ?? catalog
        defaults.set(data, forKey: Self.key)
        cloudStore?.set(data, forKey: Self.key)
        cloudStore?.synchronize()
    }

    private static func roundTripped(_ catalog: PrayerTemplateCatalog) -> PrayerTemplateCatalog {
        encode(catalog).flatMap { decode($0) } ?? catalog
    }

    private static func encode(_ catalog: PrayerTemplateCatalog) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(catalog)
    }

    private static func decode(_ data: Data?) -> PrayerTemplateCatalog? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PrayerTemplateCatalog.self, from: data)
    }
}
