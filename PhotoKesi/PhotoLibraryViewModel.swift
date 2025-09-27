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

    @Published private(set) var thumbnails: [AssetThumbnail] = []
    @Published private(set) var isLoading: Bool = false

    var bucketItems: [AssetThumbnail] {
        thumbnails.filter { $0.isInBucket }
    }

    private let thumbnailCache: PhotoThumbnailCache
    private let fetchOptions: PHFetchOptions

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
            thumbnails = []
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
            newThumbnails[0].isChecked = true
        }

        thumbnails = newThumbnails
    }

    func reset() {
        thumbnails = []
    }

    func toggleCheck(for assetIdentifier: String) {
        var updated = thumbnails
        guard let index = updated.firstIndex(where: { $0.id == assetIdentifier }) else { return }

        updated[index].isChecked.toggle()
        if updated[index].isChecked {
            updated[index].isInBucket = false
        }

        thumbnails = updated
    }

    func sendUncheckedToBucket() -> BucketActionResult {
        var updated = thumbnails
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

        thumbnails = updated

        let total = updated.filter { $0.isInBucket }.count
        return BucketActionResult(totalItems: total, newlyAdded: newlyAdded)
    }

    func clearBucketAfterDeletion() {
        var updated = thumbnails

        for index in updated.indices where updated[index].isInBucket {
            updated[index].isInBucket = false
            updated[index].isChecked = false
        }

        if !updated.isEmpty, !updated.contains(where: { $0.isChecked }) {
            updated[0].isChecked = true
        }

        thumbnails = updated
    }

    nonisolated private static func defaultFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        return options
    }
}
