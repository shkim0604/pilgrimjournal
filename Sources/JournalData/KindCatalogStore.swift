import Foundation
import JournalDomain

/// KV 저장소 대신 테스트에서 주입할 수 있는 최소 표면.
public protocol KindCatalogCloudStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KindCatalogCloudStore {}

/// Persists the kind catalog in UserDefaults and (optionally) the iCloud key-value store.
@MainActor
public final class KindCatalogStore {
    public static let key = "journal-kind-catalog"

    public private(set) var catalog: KindCatalog

    private let defaults: UserDefaults
    private let cloudStore: (any KindCatalogCloudStore)?

    public init(defaults: UserDefaults, cloudStore: (any KindCatalogCloudStore)?) {
        self.defaults = defaults
        self.cloudStore = cloudStore
        self.catalog =
            Self.decode(defaults.data(forKey: Self.key)) ?? KindCatalog()
        if cloudStore != nil {
            mergeFromCloud()
        }
    }

    /// 로컬 값과 클라우드 값을 병합. 결과가 바뀌었으면 두 곳에 다시 쓰고 true를 돌려준다.
    @discardableResult
    public func mergeFromCloud() -> Bool {
        guard let cloudStore else { return false }
        cloudStore.synchronize()
        guard let remote = Self.decode(cloudStore.data(forKey: Self.key)) else { return false }
        let merged = catalog.merged(with: remote)
        guard merged != catalog else { return false }
        save(merged)
        return true
    }

    public func save(_ catalog: KindCatalog) {
        self.catalog = catalog
        guard let data = Self.encode(catalog) else { return }
        defaults.set(data, forKey: Self.key)
        cloudStore?.set(data, forKey: Self.key)
        cloudStore?.synchronize()
    }

    private static func encode(_ catalog: KindCatalog) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(catalog)
    }

    private static func decode(_ data: Data?) -> KindCatalog? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(KindCatalog.self, from: data)
    }
}
