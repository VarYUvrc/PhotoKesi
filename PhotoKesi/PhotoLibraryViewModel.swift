import Combine
import Foundation
import Photos
import UIKit

@MainActor
final class PhotoLibraryViewModel: ObservableObject {
    struct AssetThumbnail: Identifiable, Equatable {
        let asset: PHAsset
        let image: UIImage
        let signature: PhotoSimilaritySignature
        var isChecked: Bool = false
        var isInBucket: Bool = false
        var isBest: Bool = false

        var id: String { asset.localIdentifier }
        var sharpnessScore: Double { signature.sharpnessScore }

        static func == (lhs: AssetThumbnail, rhs: AssetThumbnail) -> Bool {
            lhs.id == rhs.id
            && lhs.isChecked == rhs.isChecked
            && lhs.isInBucket == rhs.isInBucket
            && lhs.isBest == rhs.isBest
        }
    }

    struct BucketGroup: Identifiable {
        let groupIndex: Int
        let items: [AssetThumbnail]

        var id: Int { groupIndex }
        var displayIndex: Int { groupIndex + 1 }
    }

    private struct GroupState {
        var thumbnails: [AssetThumbnail]
        var isProcessed: Bool
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

    var bucketItemGroups: [BucketGroup] {
        groupedThumbnails.enumerated().compactMap { index, state in
            guard state.isProcessed else { return nil }
            let items = state.thumbnails.filter { $0.isInBucket }
            guard !items.isEmpty else { return nil }
            return BucketGroup(groupIndex: index, items: items)
        }
    }

    var bucketItems: [AssetThumbnail] {
        bucketItemGroups.flatMap { $0.items }
    }

    var hasBucketItems: Bool {
        !bucketItemGroups.isEmpty
    }

    var groupCount: Int {
        groupedThumbnails.count
    }

    static let minGroupingMinutes = 15
    static let maxGroupingMinutes = 240
    private static let perceptualHashThreshold = 12
    private static let differenceHashThreshold = 18

    private let thumbnailCache: PhotoThumbnailCache
    private let fetchOptions: PHFetchOptions

    private var groupedThumbnails: [GroupState] = []
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
                guard let signature = PhotoSimilarityAnalyzer.makeSignature(from: image) else {
                    continue
                }
                let thumbnail = AssetThumbnail(asset: asset, image: image, signature: signature)
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
        let groups = bucketItemGroups
        guard !groups.isEmpty else { return }

        let identifiersToRemove = Set(groups.flatMap { $0.items.map(\.id) })
        guard !identifiersToRemove.isEmpty else { return }

        rawThumbnails.removeAll { identifiersToRemove.contains($0.id) }

        for index in groupedThumbnails.indices {
            var state = groupedThumbnails[index]
            state.thumbnails.removeAll { identifiersToRemove.contains($0.id) }
            if state.thumbnails.isEmpty {
                state.isProcessed = false
            } else {
                ensureDefaultCheck(in: &state.thumbnails,
                                   enforceChecked: false,
                                   markBucketForDeletion: state.isProcessed)
            }
            groupedThumbnails[index] = state
        }

        groupedThumbnails.removeAll { $0.thumbnails.isEmpty }

        guard !groupedThumbnails.isEmpty else {
            currentGroup = []
            currentGroupIndex = 0
            return
        }

        if currentGroupIndex >= groupedThumbnails.count {
            currentGroupIndex = max(0, groupedThumbnails.count - 1)
        }

        currentGroup = groupedThumbnails[currentGroupIndex].thumbnails
    }

    func advanceToNextGroup() {
        guard !groupedThumbnails.isEmpty else { return }
        finalizeCurrentGroup()
        guard !groupedThumbnails.isEmpty else { return }

        let nextIndex = groupedThumbnails.isEmpty ? 0 : (currentGroupIndex + 1) % groupedThumbnails.count
        currentGroupIndex = nextIndex
        presentGroup(at: currentGroupIndex)
    }

    private func presentGroup(at index: Int) {
        guard groupedThumbnails.indices.contains(index) else {
            currentGroup = []
            return
        }

        var state = groupedThumbnails[index]

        if !state.isProcessed {
            ensureDefaultCheck(in: &state.thumbnails,
                               enforceChecked: false,
                               markBucketForDeletion: false)
        } else {
            ensureDefaultCheck(in: &state.thumbnails,
                               enforceChecked: false,
                               markBucketForDeletion: true)
        }

        groupedThumbnails[index] = state
        currentGroup = state.thumbnails
    }

    private func finalizeCurrentGroup() {
        guard groupedThumbnails.indices.contains(currentGroupIndex) else { return }

        var state = groupedThumbnails[currentGroupIndex]
        guard !state.thumbnails.isEmpty else { return }

        state.thumbnails = currentGroup
        ensureDefaultCheck(in: &state.thumbnails,
                           enforceChecked: false,
                           markBucketForDeletion: true)
        state.isProcessed = true
        groupedThumbnails[currentGroupIndex] = state
        currentGroup = state.thumbnails
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

        let grouped = groupThumbnails(rawThumbnails)
        groupedThumbnails = grouped.map { group in
            var thumbnails = group
            ensureDefaultCheck(in: &thumbnails,
                               enforceChecked: true,
                               markBucketForDeletion: false)
            return GroupState(thumbnails: thumbnails, isProcessed: false)
        }

        if groupedThumbnails.isEmpty {
            currentGroup = []
            currentGroupIndex = 0
            return
        }

        if resetGroupIndex || currentGroupIndex >= groupedThumbnails.count {
            currentGroupIndex = 0
        }

        presentGroup(at: currentGroupIndex)
    }

    private func ensureDefaultCheck(in group: inout [AssetThumbnail],
                                    enforceChecked: Bool,
                                    markBucketForDeletion: Bool) {
        guard !group.isEmpty else { return }

        if !group.contains(where: { $0.isBest }) {
            markBest(in: &group)
        } else {
            let bestIndices = group.indices.filter { group[$0].isBest }
            if bestIndices.count != 1 {
                markBest(in: &group)
            }
        }

        if enforceChecked && !group.contains(where: { $0.isChecked }) {
            if let bestIndex = group.firstIndex(where: { $0.isBest }) {
                group[bestIndex].isChecked = true
            } else {
                group[0].isChecked = true
            }
        }

        for index in group.indices {
            if markBucketForDeletion {
                group[index].isInBucket = !group[index].isChecked
            }
        }
    }

    private func applyUpdatedCurrentGroup(_ updatedGroup: [AssetThumbnail]) {
        var normalizedGroup = updatedGroup
        ensureDefaultCheck(in: &normalizedGroup,
                           enforceChecked: false,
                           markBucketForDeletion: false)

        if groupedThumbnails.indices.contains(currentGroupIndex) {
            groupedThumbnails[currentGroupIndex].thumbnails = normalizedGroup
        }

        currentGroup = normalizedGroup

        for item in normalizedGroup {
            if let rawIndex = rawThumbnails.firstIndex(where: { $0.id == item.id }) {
                rawThumbnails[rawIndex] = item
            }
        }
    }

    private func groupThumbnails(_ thumbnails: [AssetThumbnail]) -> [[AssetThumbnail]] {
        guard !thumbnails.isEmpty else { return [] }

        let window = TimeInterval(groupingWindowMinutes * 60)
        let sorted = thumbnails.sorted { lhs, rhs in
            let lhsDate = lhs.asset.creationDate ?? .distantPast
            let rhsDate = rhs.asset.creationDate ?? .distantPast
            return lhsDate > rhsDate
        }

        var groups: [[AssetThumbnail]] = []
        var usedIdentifiers = Set<String>()

        for anchor in sorted {
            guard !usedIdentifiers.contains(anchor.id),
                  anchor.asset.creationDate != nil else { continue }

            var group: [AssetThumbnail] = [anchor]
            usedIdentifiers.insert(anchor.id)

            for candidate in sorted {
                guard !usedIdentifiers.contains(candidate.id) else { continue }

                if candidateBelongs(candidate, to: group, window: window) {
                    group.append(candidate)
                    usedIdentifiers.insert(candidate.id)
                }
            }

            if group.count > 1 {
                group.sort { lhs, rhs in
                    let lhsDate = lhs.asset.creationDate ?? .distantPast
                    let rhsDate = rhs.asset.creationDate ?? .distantPast
                    return lhsDate > rhsDate
                }
                groups.append(group)
            }
        }

        groups.sort { lhs, rhs in
            let lhsDate = lhs.first?.asset.creationDate ?? .distantPast
            let rhsDate = rhs.first?.asset.creationDate ?? .distantPast
            return lhsDate > rhsDate
        }

        return groups
    }

    private func candidateBelongs(_ candidate: AssetThumbnail,
                                  to group: [AssetThumbnail],
                                  window: TimeInterval) -> Bool {
        guard let candidateDate = candidate.asset.creationDate else { return false }

        return group.contains { member in
            guard let memberDate = member.asset.creationDate else { return false }
            let timeDelta = abs(memberDate.timeIntervalSince(candidateDate))
            guard timeDelta <= window else { return false }

            let perceptualDistance = PhotoLibraryViewModel.hammingDistance(
                member.signature.perceptualHash,
                candidate.signature.perceptualHash
            )
            guard perceptualDistance <= PhotoLibraryViewModel.perceptualHashThreshold else { return false }

            let differenceDistance = PhotoLibraryViewModel.hammingDistance(
                member.signature.differenceHash,
                candidate.signature.differenceHash
            )
            return differenceDistance <= PhotoLibraryViewModel.differenceHashThreshold
        }
    }

    private func markBest(in group: inout [AssetThumbnail]) {
        guard let bestIndex = group.enumerated().max(by: { $0.element.sharpnessScore < $1.element.sharpnessScore })?.offset else {
            return
        }

        for index in group.indices {
            group[index].isBest = index == bestIndex
        }
    }

    private static func hammingDistance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }
}
