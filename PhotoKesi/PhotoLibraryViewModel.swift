import Combine
import Foundation
import Photos
import UIKit

@MainActor
final class PhotoLibraryViewModel: ObservableObject {
    struct AssetThumbnail: Identifiable {
        let asset: PHAsset
        let image: UIImage
        var isChecked: Bool = false
        var isInBucket: Bool = false

        var id: String { asset.localIdentifier }
    }

    struct BucketActionResult {
        let totalItems: Int
        let newlyAdded: Int
    }

    @Published private(set) var currentGroup: [AssetThumbnail] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var currentGroupIndex: Int = 0
    @Published var groupingWindowMinutes: Int = 60 {
        didSet {
            let clamped = max(Self.minGroupingMinutes, min(groupingWindowMinutes, Self.maxGroupingMinutes))
            if groupingWindowMinutes != clamped {
                groupingWindowMinutes = clamped
                return
            }

            if oldValue != groupingWindowMinutes {
                regroupThumbnailsFromRaw(resetGroupIndex: false)
            }
        }
    }

    var bucketItems: [AssetThumbnail] {
        currentGroup.filter { $0.isInBucket }
    }

    var groupCount: Int {
        groupedThumbnails.count
    }

    static let minGroupingMinutes = 15
    static let maxGroupingMinutes = 240

    private let thumbnailCache: PhotoThumbnailCache
    private let fetchOptions: PHFetchOptions

    private var groupedThumbnails: [[AssetThumbnail]] = []
    private var rawThumbnails: [AssetThumbnail] = []

    init(thumbnailCache: PhotoThumbnailCache = .shared,
         fetchOptions: PHFetchOptions? = nil) {
        self.thumbnailCache = thumbnailCache
        self.fetchOptions = fetchOptions ?? PhotoLibraryViewModel.defaultFetchOptions()
    }

    func loadThumbnails(limit: Int = 60,
                        targetSize: CGSize = CGSize(width: 240, height: 240)) async {
        guard !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        guard fetchResult.count > 0 else {
            reset()
            return
        }

        var newThumbnails: [AssetThumbnail] = []
        let upperBound = min(fetchResult.count, limit)

        for index in 0..<upperBound {
            if Task.isCancelled { break }

            let asset = fetchResult.object(at: index)
            let result = await thumbnailCache.image(for: asset, targetSize: targetSize)

            switch result {
            case .success(let image):
                let thumbnail = AssetThumbnail(asset: asset, image: image)
                newThumbnails.append(thumbnail)
            case .failure:
                continue
            }
        }

        if !newThumbnails.isEmpty {
            if !newThumbnails.contains(where: { $0.isChecked }) {
                newThumbnails[0].isChecked = true
            }
        }

        setRawThumbnails(newThumbnails)
    }

    func reset() {
        rawThumbnails = []
        groupedThumbnails = []
        currentGroup = []
        currentGroupIndex = 0
    }

    func toggleCheck(for assetIdentifier: String) {
        guard !currentGroup.isEmpty else { return }
        var updatedGroup = currentGroup
        guard let index = updatedGroup.firstIndex(where: { $0.id == assetIdentifier }) else { return }

        updatedGroup[index].isChecked.toggle()
        if updatedGroup[index].isChecked {
            updatedGroup[index].isInBucket = false
        }

        applyUpdatedCurrentGroup(updatedGroup)
    }

    func sendUncheckedToBucket() -> BucketActionResult {
        guard !currentGroup.isEmpty else {
            return BucketActionResult(totalItems: 0, newlyAdded: 0)
        }

        var updated = currentGroup
        var newlyAdded = 0

        for index in updated.indices {
            if updated[index].isChecked {
                if updated[index].isInBucket {
                    updated[index].isInBucket = false
                }
            } else {
                if !updated[index].isInBucket {
                    newlyAdded += 1
                }
                updated[index].isInBucket = true
            }
        }

        applyUpdatedCurrentGroup(updated)

        let total = updated.filter { $0.isInBucket }.count
        return BucketActionResult(totalItems: total, newlyAdded: newlyAdded)
    }

    func clearBucketAfterDeletion() {
        guard !currentGroup.isEmpty else { return }

        var updated = currentGroup

        for index in updated.indices where updated[index].isInBucket {
            updated[index].isInBucket = false
            updated[index].isChecked = false
        }

        if !updated.isEmpty, !updated.contains(where: { $0.isChecked }) {
            updated[0].isChecked = true
        }

        applyUpdatedCurrentGroup(updated)
    }

    nonisolated private static func defaultFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        return options
    }

    private func setRawThumbnails(_ thumbnails: [AssetThumbnail]) {
        rawThumbnails = thumbnails
        regroupThumbnailsFromRaw(resetGroupIndex: true)
    }

    private func regroupThumbnailsFromRaw(resetGroupIndex: Bool) {
        guard !rawThumbnails.isEmpty else {
            groupedThumbnails = []
            currentGroup = []
            currentGroupIndex = 0
            return
        }

        var grouped = groupThumbnails(rawThumbnails)

        for index in grouped.indices {
            ensureDefaultCheck(in: &grouped[index])
        }

        groupedThumbnails = grouped

        if resetGroupIndex || currentGroupIndex >= groupedThumbnails.count {
            currentGroupIndex = 0
        }

        currentGroup = groupedThumbnails[currentGroupIndex]
        rawThumbnails = groupedThumbnails.flatMap { $0 }
    }

    private func ensureDefaultCheck(in group: inout [AssetThumbnail]) {
        guard !group.isEmpty else { return }
        if !group.contains(where: { $0.isChecked }) {
            group[0].isChecked = true
        }
    }

    private func applyUpdatedCurrentGroup(_ updatedGroup: [AssetThumbnail]) {
        guard groupedThumbnails.indices.contains(currentGroupIndex) else {
            currentGroup = updatedGroup
            return
        }

        groupedThumbnails[currentGroupIndex] = updatedGroup
        currentGroup = updatedGroup
        rawThumbnails = groupedThumbnails.flatMap { $0 }
    }

    private func groupThumbnails(_ thumbnails: [AssetThumbnail]) -> [[AssetThumbnail]] {
        guard !thumbnails.isEmpty else { return [] }

        let window = TimeInterval(groupingWindowMinutes * 60)
        var groups: [[AssetThumbnail]] = []
        var current: [AssetThumbnail] = []

        for thumbnail in thumbnails {
            guard let creationDate = thumbnail.asset.creationDate else {
                if !current.isEmpty {
                    groups.append(current)
                    current = []
                }
                groups.append([thumbnail])
                continue
            }

            if current.isEmpty {
                current.append(thumbnail)
                continue
            }

            if let referenceDate = current.first?.asset.creationDate {
                let delta = abs(referenceDate.timeIntervalSince(creationDate))
                if delta <= window {
                    current.append(thumbnail)
                } else {
                    groups.append(current)
                    current = [thumbnail]
                }
            } else {
                groups.append(current)
                current = [thumbnail]
            }
        }

        if !current.isEmpty {
            groups.append(current)
        }

        return groups
    }
}
