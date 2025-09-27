import Foundation
import Photos
import UIKit

enum PhotoThumbnailCacheError: Error {
    case imageUnavailable
    case requestCancelled
    case underlying(Error)
}

final class PhotoThumbnailCache {
    static let shared = PhotoThumbnailCache()

    private let imageManager: PHCachingImageManager
    private let cache: NSCache<NSString, UIImage>
    private let requestOptions: PHImageRequestOptions

    init(imageManager: PHCachingImageManager = PHCachingImageManager(),
         cache: NSCache<NSString, UIImage> = NSCache()) {
        self.imageManager = imageManager
        self.cache = cache
        self.cache.countLimit = 200
        self.cache.totalCostLimit = 50 * 1024 * 1024

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true
        self.requestOptions = options
    }

    func image(for asset: PHAsset,
               targetSize: CGSize,
               contentMode: PHImageContentMode = .aspectFill) async -> Result<UIImage, PhotoThumbnailCacheError> {
        let key = asset.localIdentifier as NSString

        if let cachedImage = cache.object(forKey: key) {
            return .success(cachedImage)
        }

        var requestID: PHImageRequestID = PHInvalidImageRequestID

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                requestID = imageManager.requestImage(for: asset,
                                                      targetSize: targetSize,
                                                      contentMode: contentMode,
                                                      options: requestOptions) { [weak self] image, info in
                    guard let self = self else { return }

                    guard let info = info else {
                        if let image = image {
                            self.store(image, forKey: key)
                            continuation.resume(returning: .success(image))
                        } else {
                            continuation.resume(returning: .failure(.imageUnavailable))
                        }
                        return
                    }

                    if let error = info[PHImageErrorKey] as? Error {
                        continuation.resume(returning: .failure(.underlying(error)))
                        return
                    }

                    if (info[PHImageCancelledKey] as? Bool) == true {
                        continuation.resume(returning: .failure(.requestCancelled))
                        return
                    }

                    let isDegraded = (info[PHImageResultIsDegradedKey] as? Bool) ?? false

                    if let image = image, !isDegraded {
                        self.store(image, forKey: key)
                        continuation.resume(returning: .success(image))
                    } else if image == nil && !isDegraded {
                        continuation.resume(returning: .failure(.imageUnavailable))
                    }
                }
            }
        }, onCancel: {
            if requestID != PHInvalidImageRequestID {
                imageManager.cancelImageRequest(requestID)
            }
        })
    }

    private func store(_ image: UIImage, forKey key: NSString) {
        let cost = costEstimate(for: image)
        cache.setObject(image, forKey: key, cost: cost)
    }

    private func costEstimate(for image: UIImage) -> Int {
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        return max(pixelWidth * pixelHeight * 4, 1)
    }

    func removeCachedImage(for asset: PHAsset) {
        let key = asset.localIdentifier as NSString
        cache.removeObject(forKey: key)
    }

    func clear() {
        cache.removeAllObjects()
    }
}
