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

    private enum SceneProfile {
        case selfie
        case people
        case food
        case landscape
        case generic
    }

    private struct SimilarityThresholds {
        let averageSoft: Int
        let averageHard: Int
        let differenceSoft: Int
        let differenceHard: Int
        let perceptualSoft: Int
        let perceptualHard: Int
        let labThreshold: Float
        let edgeThreshold: Float
        let edgeDensityTolerance: Float

        func applying(_ tuning: SimilarityTuning) -> SimilarityThresholds {
            let clampDouble: (Double, Double, Double) -> Double = { value, lower, upper in
                min(max(value, lower), upper)
            }

            let hashSoftOffset = tuning.hashSoftOffset
            let hashHardOffset = tuning.hashHardOffset

            let adjustedAverageSoft = max(0, averageSoft + hashSoftOffset)
            let adjustedDifferenceSoft = max(0, differenceSoft + hashSoftOffset)
            let adjustedPerceptualSoft = max(0, perceptualSoft + hashSoftOffset)

            let avgHardRaw = max(0, averageHard + hashHardOffset)
            let diffHardRaw = max(0, differenceHard + hashHardOffset)
            let percHardRaw = max(0, perceptualHard + hashHardOffset)

            let adjustedAverageHard = max(adjustedAverageSoft, avgHardRaw)
            let adjustedDifferenceHard = max(adjustedDifferenceSoft, diffHardRaw)
            let adjustedPerceptualHard = max(adjustedPerceptualSoft, percHardRaw)

            let histogramScale = clampDouble(tuning.histogramScale, 0.3, 2.0)
            let edgeScale = clampDouble(tuning.edgeScale, 0.3, 2.0)
            let edgeDensityScale = clampDouble(tuning.edgeDensityScale, 0.3, 2.0)

            let adjustedLabThreshold = min(1.0, max(0.05, labThreshold * Float(histogramScale)))
            let adjustedEdgeThreshold = min(1.0, max(0.05, edgeThreshold * Float(edgeScale)))
            let adjustedEdgeDensity = min(1.0, max(0.05, edgeDensityTolerance * Float(edgeDensityScale)))

            return SimilarityThresholds(
                averageSoft: adjustedAverageSoft,
                averageHard: adjustedAverageHard,
                differenceSoft: adjustedDifferenceSoft,
                differenceHard: adjustedDifferenceHard,
                perceptualSoft: adjustedPerceptualSoft,
                perceptualHard: adjustedPerceptualHard,
                labThreshold: adjustedLabThreshold,
                edgeThreshold: adjustedEdgeThreshold,
                edgeDensityTolerance: adjustedEdgeDensity
            )
        }
    }

    struct SimilarityTuning: Equatable {
        var hashSoftOffset: Int = 0
        var hashHardOffset: Int = 0
        var histogramScale: Double = 1.0
        var edgeScale: Double = 1.0
        var edgeDensityScale: Double = 1.0
    }

    enum SimilarityPreset: String, CaseIterable, Identifiable {
        case standard
        case strict
        case extraStrict
        case loose
        case extraLoose

        var id: Self { self }

        var displayName: String {
            switch self {
            case .standard: return "標準"
            case .strict: return "厳密"
            case .extraStrict: return "さらに厳密"
            case .loose: return "ゆるい"
            case .extraLoose: return "さらにゆるい"
            }
        }

        var tuning: SimilarityTuning {
            switch self {
            case .standard:
                return SimilarityTuning()
            case .strict:
                return SimilarityTuning(
                    hashSoftOffset: -2,
                    hashHardOffset: -2,
                    histogramScale: 0.9,
                    edgeScale: 0.9,
                    edgeDensityScale: 0.9
                )
            case .extraStrict:
                return SimilarityTuning(
                    hashSoftOffset: -4,
                    hashHardOffset: -4,
                    histogramScale: 0.8,
                    edgeScale: 0.85,
                    edgeDensityScale: 0.85
                )
            case .loose:
                return SimilarityTuning(
                    hashSoftOffset: 2,
                    hashHardOffset: 2,
                    histogramScale: 1.1,
                    edgeScale: 1.1,
                    edgeDensityScale: 1.1
                )
            case .extraLoose:
                return SimilarityTuning(
                    hashSoftOffset: 4,
                    hashHardOffset: 4,
                    histogramScale: 1.2,
                    edgeScale: 1.2,
                    edgeDensityScale: 1.2
                )
            }
        }
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
    @Published var debugSimilarityTuning: SimilarityTuning = SimilarityPreset.standard.tuning
    @Published var selectedPreset: SimilarityPreset = .standard {
        didSet {
            guard oldValue != selectedPreset else { return }
            applyPreset(selectedPreset)
        }
    }
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
    private static let advanceCountKey = "PhotoLibraryViewModel.dailyAdvanceCount"
    private static let advanceDateKey = "PhotoLibraryViewModel.dailyAdvanceDate"
    private static let targetUpcomingGroupCount = 10
    private static let bufferReplenishThreshold = 7
    private static let initialFetchBatchSize = 80
    private static let subsequentFetchBatchSize = 40
    private static let profilePriority: [SceneProfile: Int] = [
        .selfie: 0,
        .people: 1,
        .food: 2,
        .landscape: 3,
        .generic: 4
    ]

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

        await fetchAdditionalThumbnailsIfNeeded(minUpcomingCount: 1)
        promoteQueuedGroupsIfNeeded(targetUpcoming: 1)

        if !groupedThumbnails.isEmpty {
            currentGroupIndex = min(currentGroupIndex, groupedThumbnails.count - 1)
            presentGroup(at: currentGroupIndex)
        } else {
            currentGroup = []
        }

        didFinishInitialLoad = true

        if !groupedThumbnails.isEmpty {
            requestBufferReplenishmentIfNeeded()
        }
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

    func updateSimilarityTuning<Value>(_ keyPath: WritableKeyPath<SimilarityTuning, Value>, to newValue: Value) {
        debugSimilarityTuning[keyPath: keyPath] = newValue
        applySimilarityTuningChanges()
    }

    func resetSimilarityTuning() {
        if selectedPreset != .standard {
            selectedPreset = .standard
        } else {
            applyPreset(.standard)
        }
    }

    func reprocessAllGroupsFromStart() async {
        guard !isLoading else { return }
        await loadThumbnails(targetSize: thumbnailTargetSize)
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

    private func applySimilarityTuningChanges() {
        guard !rawThumbnails.isEmpty else { return }
        rebuildGroupsFromRaw(resetGroupIndex: false)
        promoteQueuedGroupsIfNeeded(targetUpcoming: Self.targetUpcomingGroupCount)
        if !groupedThumbnails.isEmpty {
            currentGroupIndex = min(currentGroupIndex, groupedThumbnails.count - 1)
            presentGroup(at: currentGroupIndex)
        } else {
            currentGroup = []
        }
        updateBufferedCounts()
    }

    private func applyPreset(_ preset: SimilarityPreset) {
        let desired = preset.tuning
        if debugSimilarityTuning != desired {
            debugSimilarityTuning = desired
        }
        applySimilarityTuningChanges()
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

            let memberProfile = sceneProfile(for: member)
            let candidateProfile = sceneProfile(for: candidate)
            let dominantProfile = PhotoLibraryViewModel.dominantProfile(memberProfile, candidateProfile)
            let thresholds = thresholds(for: dominantProfile)

            return evaluateSimilarity(
                lhs: member.signature,
                rhs: candidate.signature,
                thresholds: thresholds
            )
        }
    }

    private func sceneProfile(for thumbnail: AssetThumbnail) -> SceneProfile {
        if thumbnail.signature.faceCount > 0 {
            if thumbnail.asset.pixelWidth <= thumbnail.asset.pixelHeight && thumbnail.asset.pixelWidth < 2200 {
                return .selfie
            }
            return .people
        }

        let lab = thumbnail.signature.labMoments
        let meanA = lab.y
        let meanB = lab.z

        if meanA > 14 && meanB > 12 {
            return .food
        }

        if meanB < -8 || thumbnail.signature.edgeDensity > 0.35 {
            return .landscape
        }

        return .generic
    }

    private static func dominantProfile(_ lhs: SceneProfile, _ rhs: SceneProfile) -> SceneProfile {
        if lhs == rhs { return lhs }
        let lhsPriority = profilePriority[lhs] ?? 4
        let rhsPriority = profilePriority[rhs] ?? 4
        return lhsPriority <= rhsPriority ? lhs : rhs
    }

    private func thresholds(for profile: SceneProfile) -> SimilarityThresholds {
        let base: SimilarityThresholds = {
        switch profile {
        case .selfie:
            return SimilarityThresholds(
                averageSoft: 8,
                averageHard: 14,
                differenceSoft: 12,
                differenceHard: 20,
                perceptualSoft: 16,
                perceptualHard: 26,
                labThreshold: 0.30,
                edgeThreshold: 0.28,
                edgeDensityTolerance: 0.20
            )
        case .people:
            return SimilarityThresholds(
                averageSoft: 10,
                averageHard: 16,
                differenceSoft: 14,
                differenceHard: 22,
                perceptualSoft: 18,
                perceptualHard: 30,
                labThreshold: 0.32,
                edgeThreshold: 0.30,
                edgeDensityTolerance: 0.24
            )
        case .food:
            return SimilarityThresholds(
                averageSoft: 12,
                averageHard: 18,
                differenceSoft: 16,
                differenceHard: 26,
                perceptualSoft: 22,
                perceptualHard: 34,
                labThreshold: 0.40,
                edgeThreshold: 0.36,
                edgeDensityTolerance: 0.28
            )
        case .landscape:
            return SimilarityThresholds(
                averageSoft: 12,
                averageHard: 18,
                differenceSoft: 16,
                differenceHard: 26,
                perceptualSoft: 24,
                perceptualHard: 34,
                labThreshold: 0.38,
                edgeThreshold: 0.34,
                edgeDensityTolerance: 0.30
            )
        case .generic:
            return SimilarityThresholds(
                averageSoft: 12,
                averageHard: 16,
                differenceSoft: 16,
                differenceHard: 24,
                perceptualSoft: 22,
                perceptualHard: 30,
                labThreshold: 0.36,
                edgeThreshold: 0.32,
                edgeDensityTolerance: 0.26
            )
        }
    }()

        return base.applying(debugSimilarityTuning)
    }

    private func evaluateSimilarity(lhs: PhotoSimilaritySignature,
                                    rhs: PhotoSimilaritySignature,
                                    thresholds: SimilarityThresholds) -> Bool {
        let averageDistance = Self.hammingDistance(lhs.averageHash, rhs.averageHash)
        if averageDistance > thresholds.averageHard { return false }

        let differenceDistance = Self.hammingDistance(lhs.differenceHash, rhs.differenceHash)
        if differenceDistance > thresholds.differenceHard { return false }

        let perceptualDistance = Self.hammingDistance(lhs.perceptualHash, rhs.perceptualHash)
        if perceptualDistance > thresholds.perceptualHard { return false }

        let labDistance = PhotoSimilarityAnalyzer.histogramDistance(lhs: lhs.labHistogram, rhs: rhs.labHistogram)
        if labDistance > thresholds.labThreshold { return false }

        let edgeDistance = PhotoSimilarityAnalyzer.histogramDistance(lhs: lhs.edgeHistogram, rhs: rhs.edgeHistogram)
        if edgeDistance > thresholds.edgeThreshold { return false }

        let densityGap = abs(lhs.edgeDensity - rhs.edgeDensity)
        if densityGap > thresholds.edgeDensityTolerance { return false }

        return true
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
