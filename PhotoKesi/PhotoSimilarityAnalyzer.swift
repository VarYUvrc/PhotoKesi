import CoreImage
import UIKit

struct PhotoSimilaritySignature {
    let perceptualHash: UInt64
    let differenceHash: UInt64
    let sharpnessScore: Double
}

enum PhotoSimilarityAnalyzer {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func makeSignature(from image: UIImage) -> PhotoSimilaritySignature? {
        let normalized = normalizeOrientation(of: image)

        guard
            let perceptual = averageHash(of: normalized),
            let difference = differenceHash(of: normalized)
        else {
            return nil
        }

        let sharpness = sharpnessScore(of: normalized) ?? 0

        return PhotoSimilaritySignature(
            perceptualHash: perceptual,
            differenceHash: difference,
            sharpnessScore: sharpness
        )
    }

    private static func averageHash(of image: UIImage) -> UInt64? {
        guard let pixels = grayscalePixels(for: image, width: 8, height: 8) else { return nil }
        let sum = pixels.reduce(0) { $0 + Int($1) }
        let average = Double(sum) / Double(pixels.count)
        var hash: UInt64 = 0

        for (index, value) in pixels.enumerated() {
            if Double(value) >= average {
                hash |= 1 << (63 - UInt64(index))
            }
        }
        return hash
    }

    private static func differenceHash(of image: UIImage) -> UInt64? {
        let width = 9
        let height = 8
        guard let pixels = grayscalePixels(for: image, width: width, height: height) else { return nil }
        var hash: UInt64 = 0
        var bitIndex: UInt64 = 0

        for y in 0..<height {
            for x in 0..<(width - 1) {
                let current = pixels[y * width + x]
                let next = pixels[y * width + x + 1]
                if current < next {
                    hash |= 1 << (63 - bitIndex)
                }
                bitIndex += 1
            }
        }
        return hash
    }

    private static func sharpnessScore(of image: UIImage) -> Double? {
        let dimension = 16
        guard let pixels = grayscalePixels(for: image, width: dimension, height: dimension) else { return nil }
        var sum: Double = 0
        var count: Double = 0

        for y in 0..<dimension {
            for x in 0..<dimension {
                let value = Double(pixels[y * dimension + x])
                if x > 0 {
                    let diff = value - Double(pixels[y * dimension + x - 1])
                    sum += diff * diff
                    count += 1
                }
                if y > 0 {
                    let diff = value - Double(pixels[(y - 1) * dimension + x])
                    sum += diff * diff
                    count += 1
                }
            }
        }

        guard count > 0 else { return nil }
        return sum / count
    }

    private static func grayscalePixels(for image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cgImage = cgImage(from: image) else { return nil }

        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return nil }
        let buffer = data.bindMemory(to: UInt8.self, capacity: width * height)
        return Array(UnsafeBufferPointer(start: buffer, count: width * height))
    }

    private static func normalizeOrientation(of image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func cgImage(from image: UIImage) -> CGImage? {
        if let cgImage = image.cgImage {
            return cgImage
        }

        if let ciImage = image.ciImage {
            return ciContext.createCGImage(ciImage, from: ciImage.extent)
        }

        guard let ciImage = CIImage(image: image) else {
            return nil
        }
        return ciContext.createCGImage(ciImage, from: ciImage.extent)
    }
}
