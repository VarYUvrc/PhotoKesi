import Combine
import Foundation
import Photos
import UIKit

@MainActor
final class PhotoLibraryViewModel: ObservableObject {
    struct AssetThumbnail: Identifiable, Equatable {
        let asset: PHAsset
        let image: UIImage
        var isChecked: Bool = false
        var isInBucket: Bool = false

        var id: String { asset.localIdentifier }

        static func == (lhs: AssetThumbnail, rhs: AssetThumbnail) -> Bool {
            lhs.id == rhs.id && lhs.isChecked == rhs.isChecked && lhs.isInBucket == rhs.isInBucket
        }
    }

    @Published private(set) var currentGroup: [AssetThumbnail] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var currentGroupIndex: Int = 0
    @Published private(set) var didFinishInitialLoad: Bool = false
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
        didFinishInitialLoad = false
        defer { isLoading = false }

        let fetchResult = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        guard fetchResult.count > 0 else {
            reset()
            didFinishInitialLoad = true
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

        didFinishInitialLoad = true
    }

    func reset() {
        rawThumbnails = []
        groupedThumbnails = []
        currentGroup = []
        currentGroupIndex = 0
        didFinishInitialLoad = false
    }

    func toggleCheck(for assetIdentifier: String) {
        guard !currentGroup.isEmpty else { return }
        var updatedGroup = currentGroup
        guard let index = updatedGroup.firstIndex(where: { $0.id == assetIdentifier }) else { return }

        updatedGroup[index].isChecked.toggle()
        if updatedGroup[index].isChecked {
            updatedGroup[index].isInBucket = false
        } else {
            updatedGroup[index].isInBucket = true
        }

        applyUpdatedCurrentGroup(updatedGroup)
    }

    func setCheck(_ isChecked: Bool, for assetIdentifier: String) {
        guard !currentGroup.isEmpty else { return }
        var updatedGroup = currentGroup
        guard let index = updatedGroup.firstIndex(where: { $0.id == assetIdentifier }) else { return }

        guard updatedGroup[index].isChecked != isChecked else { return }

        updatedGroup[index].isChecked = isChecked
        updatedGroup[index].isInBucket = !isChecked

        applyUpdatedCurrentGroup(updatedGroup)
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

        for index in updated.indices {
            updated[index].isInBucket = !updated[index].isChecked
        }

        applyUpdatedCurrentGroup(updated)
    }

    func advanceToNextGroup() {
        guard !groupedThumbnails.isEmpty else { return }

        let nextIndex = currentGroupIndex + 1
        currentGroupIndex = nextIndex < groupedThumbnails.count ? nextIndex : 0
        currentGroup = groupedThumbnails[currentGroupIndex]
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

        if groupedThumbnails.isEmpty {
            currentGroup = []
            currentGroupIndex = 0
            return
        }

        if resetGroupIndex || currentGroupIndex >= groupedThumbnails.count {
            currentGroupIndex = 0
        }

        currentGroup = groupedThumbnails[currentGroupIndex]
    }

    private func ensureDefaultCheck(in group: inout [AssetThumbnail]) {
        guard !group.isEmpty else { return }
        if !group.contains(where: { $0.isChecked }) {
            group[0].isChecked = true
        }
        for index in group.indices {
            group[index].isInBucket = !group[index].isChecked
        }
    }

    private func applyUpdatedCurrentGroup(_ updatedGroup: [AssetThumbnail]) {
        if groupedThumbnails.indices.contains(currentGroupIndex) {
            groupedThumbnails[currentGroupIndex] = updatedGroup
        }

        currentGroup = updatedGroup

        for item in updatedGroup {
            if let rawIndex = rawThumbnails.firstIndex(where: { $0.id == item.id }) {
                rawThumbnails[rawIndex] = item
            }
        }
    }

    private func groupThumbnails(_ thumbnails: [AssetThumbnail]) -> [[AssetThumbnail]] {
        guard !thumbnails.isEmpty else { return [] }

        let window = TimeInterval(groupingWindowMinutes * 60)
        var groups: [[AssetThumbnail]] = []
        var current: [AssetThumbnail] = []
        var lastDate: Date?

        for thumbnail in thumbnails {
            guard let creationDate = thumbnail.asset.creationDate else {
                if current.count > 1 {
                    groups.append(current)
                }
                current = []
                lastDate = nil
                continue
            }

            if let last = lastDate {
                let delta = abs(last.timeIntervalSince(creationDate))
                if delta <= window {
                    current.append(thumbnail)
                } else {
                    if current.count > 1 {
                        groups.append(current)
                    }
                    current = [thumbnail]
                }
            } else {
                current = [thumbnail]
            }

            lastDate = creationDate
        }

        if current.count > 1 {
            groups.append(current)
        }

        return groups
    }
}
