import Foundation
import Photos
import UIKit

enum PhotoFullImageLoaderError: Error {
    case cancelled
    case unavailable
    case underlying(Error)
}

final class PhotoFullImageLoader {
    static let shared = PhotoFullImageLoader()

    private let imageManager: PHImageManager
    private let requestOptions: PHImageRequestOptions

    private init(imageManager: PHImageManager = PHImageManager.default()) {
        self.imageManager = imageManager

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true
        options.version = .current
        self.requestOptions = options
    }

    func image(for asset: PHAsset,
               targetSize: CGSize,
               contentMode: PHImageContentMode = .aspectFit) async -> Result<UIImage, PhotoFullImageLoaderError> {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                var requestID: PHImageRequestID = PHInvalidImageRequestID

                requestID = imageManager.requestImage(for: asset,
                                                       targetSize: targetSize,
                                                       contentMode: contentMode,
                                                       options: requestOptions) { image, info in
                    guard let info = info else {
                        if let image = image {
                            continuation.resume(returning: .success(image))
                        } else {
                            continuation.resume(returning: .failure(.unavailable))
                        }
                        return
                    }

                    if let error = info[PHImageErrorKey] as? Error {
                        continuation.resume(returning: .failure(.underlying(error)))
                        return
                    }

                    if (info[PHImageCancelledKey] as? Bool) == true {
                        continuation.resume(returning: .failure(.cancelled))
                        return
                    }

                    let isDegraded = (info[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if let image = image, !isDegraded {
                        continuation.resume(returning: .success(image))
                    } else if image == nil && !isDegraded {
                        continuation.resume(returning: .failure(.unavailable))
                    }
                }

                Task.detached(priority: .background) {
                    if Task.isCancelled && requestID != PHInvalidImageRequestID {
                        self.imageManager.cancelImageRequest(requestID)
                    }
                }
            }
        }, onCancel: {
            // 取消時は requestImage による非同期処理が内部で完了するのを待つ。
        })
    }
}
