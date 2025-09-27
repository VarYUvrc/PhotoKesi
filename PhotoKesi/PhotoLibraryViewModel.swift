import Foundation
import Photos
import UIKit

@MainActor
final class PhotoLibraryViewModel: ObservableObject {
    struct AssetThumbnail: Identifiable {
        let asset: PHAsset
        let image: UIImage

        var id: String { asset.localIdentifier }
    }

    @Published private(set) var thumbnails: [AssetThumbnail] = []
    @Published private(set) var isLoading: Bool = false

    private let thumbnailCache: PhotoThumbnailCache
    private let fetchOptions: PHFetchOptions

    init(thumbnailCache: PhotoThumbnailCache = .shared,
         fetchOptions: PHFetchOptions = PhotoLibraryViewModel.defaultFetchOptions()) {
        self.thumbnailCache = thumbnailCache
        self.fetchOptions = fetchOptions
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
                thumbnails = newThumbnails
            case .failure:
                continue
            }
        }

        thumbnails = newThumbnails
    }

    func reset() {
        thumbnails = []
    }

    private static func defaultFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        return options
    }
}
