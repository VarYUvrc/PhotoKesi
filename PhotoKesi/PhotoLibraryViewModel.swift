import Combine
import Foundation
import Photos
import UIKit

@MainActor
final class PhotoLibraryViewModel: ObservableObject {
    enum DeletionError: LocalizedError {
        case emptyBucket
        case unauthorized
        case changesFailed(underlying: Error?)

        var errorDescription: String? {
            switch self {
            case .emptyBucket:
                return "削除候補がありません。"
            case .unauthorized:
                return "写真ライブラリへの削除権限がありません。設定アプリからアクセス権を確認してください。"
            case .changesFailed(let underlying):
                if let message = underlying?.localizedDescription, !message.isEmpty {
                    return "削除処理に失敗しました: \(message)"
                }
                return "削除処理に失敗しました。時間を置いて再度お試しください。"
            }
        }
    }

    enum GroupAdvanceError: Error {
        case quotaExceeded

        var message: String {
            switch self {
            case .quotaExceeded:
                return "本日の仕分け上限（\(PhotoLibraryViewModel.dailyAdvanceLimit)回）に達しました。明日0:00以降に再度お試しください。"
            }
        }
    }


    struct AssetThumbnail: Identifiable, Equatable {
        let asset: PHAsset
        let image: UIImage
        let signature: PhotoSimilaritySignature
        var isChecked: Bool = false
        var isInBucket: Bool = false
        var isBest: Bool = false
        var isRetained: Bool = false

        var id: String { asset.localIdentifier }
        var sharpnessScore: Double { signature.sharpnessScore }

        static func == (lhs: AssetThumbnail, rhs: AssetThumbnail) -> Bool {
            lhs.id == rhs.id
            && lhs.isChecked == rhs.isChecked
            && lhs.isInBucket == rhs.isInBucket
            && lhs.isBest == rhs.isBest
            && lhs.isRetained == rhs.isRetained
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

        var identifierKey: String {
            thumbnails.map(\.id).sorted().joined(separator: "|")
        }

        var idSet: Set<String> {
            Set(thumbnails.map(\.id))
        }
    }

    private struct AssetSnapshot {
        let isChecked: Bool
        let isInBucket: Bool
        let isBest: Bool
        let isRetained: Bool
    }

    @Published private(set) var currentGroup: [AssetThumbnail] = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var currentGroupIndex: Int = 0
    @Published private(set) var didFinishInitialLoad: Bool = false
    @Published private(set) var remainingAdvanceQuota: Int = 0
    @Published private(set) var advancesPerformedToday: Int = 0
    @Published private(set) var discoveredGroupCount: Int = 0
    @Published private(set) var upcomingBufferedGroupCount: Int = 0
    @Published private(set) var isExploringGroups: Bool = false
    @Published var groupingWindowMinutes: Int = 60 {
        didSet {
            let clamped = max(Self.minGroupingMinutes, min(groupingWindowMinutes, Self.maxGroupingMinutes))
            if groupingWindowMinutes != clamped {
                groupingWindowMinutes = clamped
                return
            }

            if oldValue != groupingWindowMinutes {
                rebuildGroupsFromRaw(resetGroupIndex: false)
                Task { [weak self] in
                    await self?.fetchAdditionalThumbnailsIfNeeded(minUpcomingCount: Self.targetUpcomingGroupCount)
                }
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

    var groupCount: Int { discoveredGroupCount }

    var currentGroupNumber: Int {
        guard !groupedThumbnails.isEmpty else { return 0 }
        return currentGroupIndex + 1
    }

    var hasPreviousGroup: Bool { currentGroupIndex > 0 }
    var hasNextDiscoveredGroup: Bool { currentGroupIndex + 1 < groupedThumbnails.count }

    static let minGroupingMinutes = 15
    static let maxGroupingMinutes = 240
    nonisolated static let dailyAdvanceLimit = 3
    private static let perceptualHashThreshold = 12
    private static let differenceHashThreshold = 18
    private static let advanceCountKey = "PhotoLibraryViewModel.dailyAdvanceCount"
    private static let advanceDateKey = "PhotoLibraryViewModel.dailyAdvanceDate"
    private static let targetUpcomingGroupCount = 10
    private static let bufferReplenishThreshold = 7
    private static let initialFetchBatchSize = 80
    private static let subsequentFetchBatchSize = 40

    private let thumbnailCache: PhotoThumbnailCache
    private let fetchOptions: PHFetchOptions
    private let userDefaults: UserDefaults
    private let retentionStore: PhotoRetentionStore

    private var groupedThumbnails: [GroupState] = []
    private var queuedGroupStates: [GroupState] = []
    private var rawThumbnails: [AssetThumbnail] = []
    private var fetchResult: PHFetchResult<PHAsset>?
    private var nextFetchIndex: Int = 0
    private var thumbnailTargetSize: CGSize = CGSize(width: 240, height: 240)
    private var isBufferReplenishmentInFlight: Bool = false

    init(thumbnailCache: PhotoThumbnailCache? = nil,
         fetchOptions: PHFetchOptions? = nil,
         userDefaults: UserDefaults = .standard,
         retentionStore: PhotoRetentionStore? = nil) {
        self.thumbnailCache = thumbnailCache ?? PhotoThumbnailCache.shared
        self.fetchOptions = fetchOptions ?? PhotoLibraryViewModel.defaultFetchOptions()
        self.userDefaults = userDefaults
        self.retentionStore = retentionStore ?? PhotoRetentionStore.shared
        refreshAdvanceQuotaIfNeeded()
    }

    func loadThumbnails(limit: Int = 60,
                        targetSize: CGSize = CGSize(width: 240, height: 240)) async {
        guard !isLoading else { return }

        isLoading = true
        didFinishInitialLoad = false
        thumbnailTargetSize = targetSize

        defer { isLoading = false }

        let fetchedResults = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        fetchResult = fetchedResults
        nextFetchIndex = 0
        rawThumbnails.removeAll()
        groupedThumbnails.removeAll()
        queuedGroupStates.removeAll()
        currentGroup.removeAll()
        currentGroupIndex = 0
        discoveredGroupCount = 0
        upcomingBufferedGroupCount = 0

        guard fetchedResults.count > 0 else {
            didFinishInitialLoad = true
            return
        }

        await fetchAdditionalThumbnailsIfNeeded(minUpcomingCount: Self.targetUpcomingGroupCount)
        promoteQueuedGroupsIfNeeded(targetUpcoming: Self.targetUpcomingGroupCount)

        if !groupedThumbnails.isEmpty {
            currentGroupIndex = min(currentGroupIndex, groupedThumbnails.count - 1)
            presentGroup(at: currentGroupIndex)
        } else {
            currentGroup = []
        }

        didFinishInitialLoad = true
    }

    func reset() {
        rawThumbnails = []
        groupedThumbnails = []
        queuedGroupStates = []
        currentGroup = []
        currentGroupIndex = 0
        discoveredGroupCount = 0
        upcomingBufferedGroupCount = 0
        didFinishInitialLoad = false
    }

    func resetRetainedFlags() async {
        retentionStore.clear()
        await loadThumbnails(targetSize: thumbnailTargetSize)
    }

    func toggleCheck(for assetIdentifier: String) {
        guard !currentGroup.isEmpty else { return }
        var updatedGroup = currentGroup
        guard let index = updatedGroup.firstIndex(where: { $0.id == assetIdentifier }) else { return }

        if updatedGroup[index].isRetained && updatedGroup[index].isChecked {
            return
        }

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

        if updatedGroup[index].isRetained && !isChecked {
            return
        }

        guard updatedGroup[index].isChecked != isChecked else { return }

        updatedGroup[index].isChecked = isChecked
        updatedGroup[index].isInBucket = !isChecked

        applyUpdatedCurrentGroup(updatedGroup)
    }

    func refreshAdvanceQuotaIfNeeded(currentDate: Date = Date()) {
        let storedDate = userDefaults.object(forKey: PhotoLibraryViewModel.advanceDateKey) as? Date
        let calendar = Calendar.current

        let isSameDay = {
            guard let storedDate else { return false }
            return calendar.isDate(storedDate, inSameDayAs: currentDate)
        }()

        if !isSameDay {
            userDefaults.set(currentDate, forKey: PhotoLibraryViewModel.advanceDateKey)
            userDefaults.set(0, forKey: PhotoLibraryViewModel.advanceCountKey)
            advancesPerformedToday = 0
            remainingAdvanceQuota = PhotoLibraryViewModel.dailyAdvanceLimit
        } else {
            let used = userDefaults.integer(forKey: PhotoLibraryViewModel.advanceCountKey)
            advancesPerformedToday = min(used, PhotoLibraryViewModel.dailyAdvanceLimit)
            remainingAdvanceQuota = max(0, PhotoLibraryViewModel.dailyAdvanceLimit - advancesPerformedToday)
        }
    }

    @discardableResult
    func deleteBucketItems(currentDate: Date = Date()) async throws -> Int {
        let groups = bucketItemGroups
        guard !groups.isEmpty else {
            throw DeletionError.emptyBucket
        }

        let assets = groups.flatMap { $0.items.map(\.asset) }

        guard !assets.isEmpty else {
            throw DeletionError.emptyBucket
        }

        guard isDeletionAuthorized else {
            throw DeletionError.unauthorized
        }

        do {
            let deletedCount = try await performDeletion(for: assets)
            let identifiersToRemove = Set(groups.flatMap { $0.items.map(\.id) })
            rawThumbnails.removeAll { identifiersToRemove.contains($0.id) }
            rebuildGroupsFromRaw(resetGroupIndex: false)
            promoteQueuedGroupsIfNeeded(targetUpcoming: Self.targetUpcomingGroupCount)
            if !groupedThumbnails.isEmpty {
                currentGroupIndex = min(currentGroupIndex, groupedThumbnails.count - 1)
                presentGroup(at: currentGroupIndex)
            } else {
                currentGroup = []
            }
            updateBufferedCounts()
            return deletedCount
        } catch let error as DeletionError {
            throw error
        } catch {
            throw DeletionError.changesFailed(underlying: error)
        }
    }

    private func performDeletion(for assets: [PHAsset]) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            } completionHandler: { success, error in
                if success {
                    continuation.resume(returning: assets.count)
                } else {
                    continuation.resume(throwing: DeletionError.changesFailed(underlying: error))
                }
            }
        }
    }

    private func incrementAdvanceCount(currentDate: Date = Date()) {
        refreshAdvanceQuotaIfNeeded(currentDate: currentDate)
        guard remainingAdvanceQuota > 0 else { return }

        var used = userDefaults.integer(forKey: PhotoLibraryViewModel.advanceCountKey)
        used = min(PhotoLibraryViewModel.dailyAdvanceLimit, used + 1)
        userDefaults.set(currentDate, forKey: PhotoLibraryViewModel.advanceDateKey)
        userDefaults.set(used, forKey: PhotoLibraryViewModel.advanceCountKey)
        advancesPerformedToday = used
        remainingAdvanceQuota = max(0, PhotoLibraryViewModel.dailyAdvanceLimit - used)
    }

    private var isDeletionAuthorized: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return true
        default:
            return false
        }
    }

    @discardableResult
    func advanceToNextGroup(currentDate: Date = Date()) throws -> Bool {
        refreshAdvanceQuotaIfNeeded(currentDate: currentDate)

        guard remainingAdvanceQuota > 0 else {
            throw GroupAdvanceError.quotaExceeded
        }

        guard !groupedThumbnails.isEmpty else { return false }

        finalizeCurrentGroup()
        incrementAdvanceCount(currentDate: currentDate)
        promoteQueuedGroupsIfNeeded(targetUpcoming: Self.targetUpcomingGroupCount)

        let nextIndex = currentGroupIndex + 1
        if groupedThumbnails.indices.contains(nextIndex) {
            currentGroupIndex = nextIndex
            presentGroup(at: currentGroupIndex)
            requestBufferReplenishmentIfNeeded()
            return true
        } else {
            requestBufferReplenishmentIfNeeded()
            updateBufferedCounts()
            return false
        }
    }

    @discardableResult
    func navigateToPreviousGroup() -> Bool {
        guard hasPreviousGroup else { return false }
        currentGroupIndex -= 1
        presentGroup(at: currentGroupIndex)
        return true
    }

    @discardableResult
    func navigateToNextDiscoveredGroup() -> Bool {
        guard hasNextDiscoveredGroup else {
            requestBufferReplenishmentIfNeeded()
            return false
        }
        currentGroupIndex += 1
        presentGroup(at: currentGroupIndex)
        requestBufferReplenishmentIfNeeded()
        return true
    }

    private func requestBufferReplenishmentIfNeeded() {
        promoteQueuedGroupsIfNeeded(targetUpcoming: Self.targetUpcomingGroupCount)
        updateBufferedCounts()

        guard upcomingBufferedGroupCount < Self.bufferReplenishThreshold else { return }
        guard (!queuedGroupStates.isEmpty) || (fetchResult != nil && nextFetchIndex < (fetchResult?.count ?? 0)) else { return }
        guard !isBufferReplenishmentInFlight else { return }

        isBufferReplenishmentInFlight = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBufferReplenishmentInFlight = false }
            await self.fetchAdditionalThumbnailsIfNeeded(minUpcomingCount: Self.targetUpcomingGroupCount)
            self.promoteQueuedGroupsIfNeeded(targetUpcoming: Self.targetUpcomingGroupCount)
            if !self.groupedThumbnails.isEmpty {
                self.currentGroupIndex = min(self.currentGroupIndex, self.groupedThumbnails.count - 1)
                self.presentGroup(at: self.currentGroupIndex)
            }
            self.updateBufferedCounts()
        }
    }

    private func presentGroup(at index: Int) {
        guard groupedThumbnails.indices.contains(index) else {
            currentGroup = []
            updateBufferedCounts()
            return
        }

        var state = groupedThumbnails[index]
        ensureDefaultCheck(in: &state.thumbnails,
                           enforceChecked: !state.thumbnails.contains { $0.isChecked },
                           markBucketForDeletion: state.isProcessed)
        groupedThumbnails[index] = state
        currentGroup = state.thumbnails
        updateBufferedCounts()
    }

    private func finalizeCurrentGroup() {
        guard groupedThumbnails.indices.contains(currentGroupIndex) else { return }

        var state = groupedThumbnails[currentGroupIndex]
        guard !state.thumbnails.isEmpty else { return }

        state.thumbnails = currentGroup
        markRetainedAssets(in: &state.thumbnails)
        ensureDefaultCheck(in: &state.thumbnails,
                           enforceChecked: false,
                           markBucketForDeletion: true)
        state.isProcessed = true
        groupedThumbnails[currentGroupIndex] = state
        currentGroup = state.thumbnails
        synchronizeRetentionFlags(with: state.thumbnails)
        updateBufferedCounts()
    }

    nonisolated private static func defaultFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        return options
    }

    private func fetchAdditionalThumbnailsIfNeeded(minUpcomingCount: Int) async {
        promoteQueuedGroupsIfNeeded(targetUpcoming: minUpcomingCount)
        updateBufferedCounts()

        guard let fetchResult else { return }

        while upcomingBufferedGroupCount < minUpcomingCount && nextFetchIndex < fetchResult.count {
            let batchSize = groupedThumbnails.isEmpty ? Self.initialFetchBatchSize : Self.subsequentFetchBatchSize
            let didFetch = await fetchNextBatch(batchSize: batchSize)
            promoteQueuedGroupsIfNeeded(targetUpcoming: minUpcomingCount)
            updateBufferedCounts()
            if !didFetch { break }
        }

        if !groupedThumbnails.isEmpty {
            currentGroupIndex = min(currentGroupIndex, groupedThumbnails.count - 1)
            presentGroup(at: currentGroupIndex)
        }
    }

    private func fetchNextBatch(batchSize: Int) async -> Bool {
        guard let fetchResult else { return false }
        guard nextFetchIndex < fetchResult.count else { return false }

        isExploringGroups = true
        defer { isExploringGroups = false }

        var addedThumbnails: [AssetThumbnail] = []
        let batchEnd = min(nextFetchIndex + batchSize, fetchResult.count)

        for index in nextFetchIndex..<batchEnd {
            if Task.isCancelled { break }
            let asset = fetchResult.object(at: index)
            let result = await thumbnailCache.image(for: asset, targetSize: thumbnailTargetSize)

            switch result {
            case .success(let image):
                guard let signature = PhotoSimilarityAnalyzer.makeSignature(from: image) else { continue }
                var thumbnail = AssetThumbnail(asset: asset, image: image, signature: signature)
                thumbnail.isRetained = retentionStore.isRetained(identifier: thumbnail.id)
                addedThumbnails.append(thumbnail)
            case .failure:
                continue
            }
        }

        nextFetchIndex = batchEnd

        guard !addedThumbnails.isEmpty else { return false }

        rawThumbnails.append(contentsOf: addedThumbnails)
        rebuildGroupsFromRaw(resetGroupIndex: groupedThumbnails.isEmpty)
        return true
    }

    private func rebuildGroupsFromRaw(resetGroupIndex: Bool) {
        if rawThumbnails.isEmpty {
            groupedThumbnails = []
            queuedGroupStates = []
            currentGroup = []
            currentGroupIndex = 0
            updateDiscoveredGroupCount()
            updateBufferedCounts()
            return
        }

        let previousGroups = groupedThumbnails + queuedGroupStates
        let previousDiscoveredCount = groupedThumbnails.count
        let previousCurrentIDSet = Set(currentGroup.map(\.id))
        let previousCurrentIndex = currentGroupIndex

        var assetSnapshots: [String: AssetSnapshot] = [:]
        var processedStatusByKey: [String: Bool] = [:]

        for state in previousGroups {
            processedStatusByKey[state.identifierKey] = state.isProcessed
            for item in state.thumbnails {
                assetSnapshots[item.id] = AssetSnapshot(isChecked: item.isChecked,
                                                         isInBucket: item.isInBucket,
                                                         isBest: item.isBest,
                                                         isRetained: item.isRetained)
            }
        }

        let grouped = groupThumbnails(rawThumbnails)
        var assembledStates: [GroupState] = []
        assembledStates.reserveCapacity(grouped.count)

        for group in grouped {
            var thumbnails = group
            var hadSnapshot = false

            for index in thumbnails.indices {
                if let snapshot = assetSnapshots[thumbnails[index].id] {
                    thumbnails[index].isChecked = snapshot.isChecked
                    thumbnails[index].isInBucket = snapshot.isInBucket
                    thumbnails[index].isBest = snapshot.isBest
                    thumbnails[index].isRetained = snapshot.isRetained
                    hadSnapshot = true
                }
            }

            applyRetentionStoreState(to: &thumbnails)

            let key = thumbnails.map(\.id).sorted().joined(separator: "|")
            let wasProcessed = processedStatusByKey[key] ?? false

            ensureDefaultCheck(in: &thumbnails,
                               enforceChecked: !hadSnapshot,
                               markBucketForDeletion: wasProcessed)

            assembledStates.append(GroupState(thumbnails: thumbnails, isProcessed: wasProcessed))
        }

        let minimumDiscovered = resetGroupIndex ? 1 : max(previousDiscoveredCount, 0)
        let requiredForCurrent = min(previousCurrentIndex + 1, assembledStates.count)
        let discoveredCount = min(max(minimumDiscovered, requiredForCurrent), assembledStates.count)

        groupedThumbnails = Array(assembledStates.prefix(discoveredCount))
        queuedGroupStates = Array(assembledStates.dropFirst(discoveredCount))

        if resetGroupIndex {
            currentGroupIndex = groupedThumbnails.isEmpty ? 0 : 0
        }

        if !previousCurrentIDSet.isEmpty,
           let index = groupedThumbnails.firstIndex(where: { $0.idSet == previousCurrentIDSet }) {
            currentGroupIndex = index
        } else if groupedThumbnails.indices.contains(previousCurrentIndex) {
            currentGroupIndex = previousCurrentIndex
        } else {
            currentGroupIndex = max(0, groupedThumbnails.count - 1)
        }

        updateDiscoveredGroupCount()
        updateBufferedCounts()
    }

    private func promoteQueuedGroupsIfNeeded(targetUpcoming: Int) {
        var didMutate = false

        if groupedThumbnails.isEmpty, let first = queuedGroupStates.first {
            groupedThumbnails.append(first)
            queuedGroupStates.removeFirst()
            didMutate = true
        }

        while groupedThumbnails.count > 0 &&
                max(0, groupedThumbnails.count - currentGroupIndex - 1) < targetUpcoming,
              let next = queuedGroupStates.first {
            groupedThumbnails.append(next)
            queuedGroupStates.removeFirst()
            didMutate = true
        }

        if didMutate {
            updateDiscoveredGroupCount()
        }
    }

    private func updateDiscoveredGroupCount() {
        discoveredGroupCount = groupedThumbnails.count
    }

    private func updateBufferedCounts() {
        if groupedThumbnails.isEmpty {
            upcomingBufferedGroupCount = 0
        } else {
            upcomingBufferedGroupCount = max(0, groupedThumbnails.count - currentGroupIndex - 1)
        }
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

    private func markRetainedAssets(in group: inout [AssetThumbnail]) {
        let checkedItems = group.filter { $0.isChecked }
        guard !checkedItems.isEmpty else { return }

        let identifiers = checkedItems.map(\.id)
        let identifierSet = Set(identifiers)
        let signatures = Dictionary(uniqueKeysWithValues: checkedItems.map { ($0.id, $0.signature) })
        retentionStore.markRetained(identifiers: identifiers, signatures: signatures)

        for index in group.indices where identifierSet.contains(group[index].id) {
            group[index].isRetained = true
        }
    }

    private func synchronizeRetentionFlags(with thumbnails: [AssetThumbnail]) {
        for item in thumbnails {
            if let rawIndex = rawThumbnails.firstIndex(where: { $0.id == item.id }) {
                rawThumbnails[rawIndex].isRetained = item.isRetained
            }
        }
    }

    private func applyRetentionStoreState(to thumbnails: inout [AssetThumbnail]) {
        for index in thumbnails.indices {
            if retentionStore.isRetained(identifier: thumbnails[index].id) {
                thumbnails[index].isRetained = true
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
                if group.allSatisfy({ $0.isRetained }) {
                    continue
                }

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
