import Foundation

struct RetainedAssetRecord: Codable, Hashable {
    let localIdentifier: String
    let perceptualHash: UInt64
    let differenceHash: UInt64
}

@MainActor
final class PhotoRetentionStore {
    static let shared = PhotoRetentionStore()

    private let storageKey = "PhotoRetentionStore.records"
    private let userDefaults: UserDefaults
    private var cachedRecords: [String: RetainedAssetRecord] = [:]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        load()
    }

    func isRetained(identifier: String) -> Bool {
        cachedRecords[identifier] != nil
    }

    func markRetained(identifiers: [String], signatures: [String: PhotoSimilaritySignature]) {
        var didChange = false

        for identifier in identifiers {
            guard let signature = signatures[identifier] else { continue }
            let record = RetainedAssetRecord(localIdentifier: identifier,
                                             perceptualHash: signature.perceptualHash,
                                             differenceHash: signature.differenceHash)
            if cachedRecords[identifier] != record {
                cachedRecords[identifier] = record
                didChange = true
            }
        }

        if didChange {
            persist()
        }
    }

    func clear() {
        guard !cachedRecords.isEmpty else { return }
        cachedRecords.removeAll()
        persist()
    }

    private func load() {
        guard let data = userDefaults.data(forKey: storageKey) else { return }

        do {
            let decoder = PropertyListDecoder()
            let records = try decoder.decode([String: RetainedAssetRecord].self, from: data)
            cachedRecords = records
        } catch {
            cachedRecords = [:]
        }
    }

    private func persist() {
        do {
            let encoder = PropertyListEncoder()
            let data = try encoder.encode(cachedRecords)
            userDefaults.set(data, forKey: storageKey)
        } catch {
            // 無視: 永続化に失敗してもアプリの挙動は維持する
        }
    }
}
