import Accelerate
import CoreImage
import simd
import UIKit
import Vision

struct PhotoSimilaritySignature {
    let averageHash: UInt64
    let differenceHash: UInt64
    let perceptualHash: UInt64
    let sharpnessScore: Double
    let labHistogram: [Float]
    let labMoments: SIMD3<Float>
    let edgeHistogram: [Float]
    let edgeDensity: Float
    let faceCount: Int
}

enum PhotoSimilarityAnalyzer {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let downsampledSize = 96
    private static let perceptualHashSize = 32
    private static let histogramBinCount = 12
    private static let edgeBinCount = 8
    private static let epsilon: Float = 1e-6

    static func makeSignature(from image: UIImage) -> PhotoSimilaritySignature? {
        let normalized = normalizeOrientation(of: image)

        guard let baseCGImage = prepareNormalizedImage(
            from: normalized,
            targetSize: CGSize(width: downsampledSize, height: downsampledSize)
        ) else {
            return nil
        }

        let width = baseCGImage.width
        let height = baseCGImage.height

        guard let rgba = rgbaPixels(for: baseCGImage) else { return nil }

        let luminance = makeLuminanceBuffer(from: rgba, width: width, height: height)
        let (labHistogram, labMoments) = makeLabHistogram(from: rgba, width: width, height: height)
        let (edgeHistogram, edgeDensity) = makeEdgeHistogram(from: luminance, width: width, height: height)

        guard let averageHash = makeAverageHash(from: luminance, width: width, height: height),
              let differenceHash = makeDifferenceHash(from: luminance, width: width, height: height),
              let perceptualHash = makePerceptualHash(from: luminance, width: width, height: height),
              let sharpness = sharpnessScore(from: luminance, width: width, height: height) else {
            return nil
        }

        let faceCount = detectFaceCount(in: baseCGImage)

        return PhotoSimilaritySignature(
            averageHash: averageHash,
            differenceHash: differenceHash,
            perceptualHash: perceptualHash,
            sharpnessScore: sharpness,
            labHistogram: labHistogram,
            labMoments: labMoments,
            edgeHistogram: edgeHistogram,
            edgeDensity: edgeDensity,
            faceCount: faceCount
        )
    }

    static func histogramDistance(lhs: [Float], rhs: [Float]) -> Float {
        guard lhs.count == rhs.count else { return Float.greatestFiniteMagnitude }
        var distance: Float = 0

        for index in 0..<lhs.count {
            let sum = lhs[index] + rhs[index] + epsilon
            let diff = lhs[index] - rhs[index]
            distance += (diff * diff) / sum
        }

        return 0.5 * distance
    }

    private static func makeAverageHash(from luminance: [Float], width: Int, height: Int) -> UInt64? {
        let resized = resample(
            luminance,
            sourceWidth: width,
            sourceHeight: height,
            targetWidth: 8,
            targetHeight: 8
        )
        guard resized.count == 64 else { return nil }
        let average = resized.reduce(0, +) / Float(resized.count)
        var hash: UInt64 = 0

        for (index, value) in resized.enumerated() {
            if value >= average {
                hash |= 1 << (63 - UInt64(index))
            }
        }
        return hash
    }

    private static func makeDifferenceHash(from luminance: [Float], width: Int, height: Int) -> UInt64? {
        let scaledWidth = 9
        let scaledHeight = 8
        let resized = resample(
            luminance,
            sourceWidth: width,
            sourceHeight: height,
            targetWidth: scaledWidth,
            targetHeight: scaledHeight
        )
        guard resized.count == scaledWidth * scaledHeight else { return nil }

        var hash: UInt64 = 0
        var bitIndex: UInt64 = 0

        for y in 0..<scaledHeight {
            for x in 0..<(scaledWidth - 1) {
                let current = resized[y * scaledWidth + x]
                let next = resized[y * scaledWidth + x + 1]
                if current < next {
                    hash |= 1 << (63 - bitIndex)
                }
                bitIndex += 1
            }
        }
        return hash
    }

    private static func makePerceptualHash(from luminance: [Float], width: Int, height: Int) -> UInt64? {
        let resized = resample(
            luminance,
            sourceWidth: width,
            sourceHeight: height,
            targetWidth: perceptualHashSize,
            targetHeight: perceptualHashSize
        )
        guard resized.count == perceptualHashSize * perceptualHashSize else { return nil }

        var dctInput = resized
        guard let dct = vDSP.DCT(count: perceptualHashSize, transformType: .II) else { return nil }

        for row in 0..<perceptualHashSize {
            let start = row * perceptualHashSize
            var slice = Array(dctInput[start ..< start + perceptualHashSize])
            dct.transform(slice, result: &slice)
            dctInput.replaceSubrange(start ..< start + perceptualHashSize, with: slice)
        }

        var column = [Float](repeating: 0, count: perceptualHashSize)
        for columnIndex in 0..<perceptualHashSize {
            for row in 0..<perceptualHashSize {
                column[row] = dctInput[row * perceptualHashSize + columnIndex]
            }
            dct.transform(column, result: &column)
            for row in 0..<perceptualHashSize {
                dctInput[row * perceptualHashSize + columnIndex] = column[row]
            }
        }

        let regionSize = 8
        var lowFrequencyValues: [Float] = []
        lowFrequencyValues.reserveCapacity(regionSize * regionSize)

        for y in 0..<regionSize {
            for x in 0..<regionSize {
                lowFrequencyValues.append(dctInput[y * perceptualHashSize + x])
            }
        }

        let dcComponent = lowFrequencyValues[0]
        let mean = (lowFrequencyValues.reduce(0, +) - dcComponent) / Float(lowFrequencyValues.count - 1)

        var hash: UInt64 = 0
        for (index, value) in lowFrequencyValues.enumerated() where index != 0 {
            if value >= mean {
                let bitIndex = index - 1
                if bitIndex < 64 {
                    hash |= 1 << (63 - UInt64(bitIndex))
                }
            }
        }
        return hash
    }

    private static func sharpnessScore(from luminance: [Float], width: Int, height: Int) -> Double? {
        guard width > 1, height > 1 else { return nil }
        var sum: Double = 0
        var count: Double = 0

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let value = Double(luminance[index])
                if x > 0 {
                    let diff = value - Double(luminance[index - 1])
                    sum += diff * diff
                    count += 1
                }
                if y > 0 {
                    let diff = value - Double(luminance[index - width])
                    sum += diff * diff
                    count += 1
                }
            }
        }

        guard count > 0 else { return nil }
        return sum / count
    }

    private static func resample(
        _ source: [Float],
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> [Float] {
        guard sourceWidth > 0,
              sourceHeight > 0,
              targetWidth > 0,
              targetHeight > 0,
              source.count == sourceWidth * sourceHeight else {
            return []
        }

        var destination = [Float](repeating: 0, count: targetWidth * targetHeight)
        let xScale = Float(sourceWidth) / Float(targetWidth)
        let yScale = Float(sourceHeight) / Float(targetHeight)

        for ty in 0..<targetHeight {
            let srcY = (Float(ty) + 0.5) * yScale - 0.5
            let y0 = max(Int(floor(srcY)), 0)
            let y1 = min(y0 + 1, sourceHeight - 1)
            let yWeight = srcY - Float(y0)

            for tx in 0..<targetWidth {
                let srcX = (Float(tx) + 0.5) * xScale - 0.5
                let x0 = max(Int(floor(srcX)), 0)
                let x1 = min(x0 + 1, sourceWidth - 1)
                let xWeight = srcX - Float(x0)

                let topLeft = source[y0 * sourceWidth + x0]
                let topRight = source[y0 * sourceWidth + x1]
                let bottomLeft = source[y1 * sourceWidth + x0]
                let bottomRight = source[y1 * sourceWidth + x1]

                let top = topLeft * (1 - xWeight) + topRight * xWeight
                let bottom = bottomLeft * (1 - xWeight) + bottomRight * xWeight
                destination[ty * targetWidth + tx] = top * (1 - yWeight) + bottom * yWeight
            }
        }

        return destination
    }

    private static func makeEdgeHistogram(from luminance: [Float], width: Int, height: Int) -> ([Float], Float) {
        guard width > 2, height > 2 else {
            return (Array(repeating: 0, count: edgeBinCount), 0)
        }

        var histogram = [Float](repeating: 0, count: edgeBinCount)
        var magnitudeSum: Float = 0
        var processed: Float = 0

        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let left = luminance[index - 1]
                let right = luminance[index + 1]
                let up = luminance[index - width]
                let down = luminance[index + width]

                let gx = right - left
                let gy = down - up
                let magnitude = sqrt(gx * gx + gy * gy)
                let angle = atan2(gy, gx)
                let normalizedAngle = (angle < 0 ? angle + .pi : angle) / .pi
                let bin = min(edgeBinCount - 1, Int(normalizedAngle * Float(edgeBinCount)))
                histogram[bin] += magnitude
                magnitudeSum += magnitude
                processed += 1
            }
        }

        let normalization = magnitudeSum + epsilon
        for index in 0..<histogram.count {
            histogram[index] /= normalization
        }

        let edgeDensity = processed > 0 ? (magnitudeSum / processed) : 0
        return (histogram, edgeDensity)
    }

    private static func makeLabHistogram(from rgba: [UInt8], width: Int, height: Int) -> ([Float], SIMD3<Float>) {
        guard width > 0, height > 0, rgba.count == width * height * 4 else {
            return (Array(repeating: 0, count: histogramBinCount), SIMD3<Float>(repeating: 0))
        }

        var histogram = [Float](repeating: 0, count: histogramBinCount)
        var sumL: Float = 0
        var sumA: Float = 0
        var sumB: Float = 0
        let pixelCount = Float(width * height)

        for index in stride(from: 0, to: rgba.count, by: 4) {
            let r = Float(rgba[index]) / 255.0
            let g = Float(rgba[index + 1]) / 255.0
            let b = Float(rgba[index + 2]) / 255.0

            let (l, a, bb) = convertToLab(r: r, g: g, b: b)
            sumL += l
            sumA += a
            sumB += bb

            let lBin = clamp(Int(((l / 100).clamped(to: 0...1)) * 4), lower: 0, upper: 3)
            let aBin = clamp(Int((((a + 80) / 160).clamped(to: 0...1)) * 4), lower: 0, upper: 3)
            let bBin = clamp(Int((((bb + 80) / 160).clamped(to: 0...1)) * 4), lower: 0, upper: 3)

            histogram[lBin] += 1
            histogram[4 + aBin] += 1
            histogram[8 + bBin] += 1
        }

        for index in 0..<histogram.count {
            histogram[index] /= pixelCount
        }

        let meanVector = SIMD3<Float>(sumL / pixelCount, sumA / pixelCount, sumB / pixelCount)
        return (histogram, meanVector)
    }

    private static func makeLuminanceBuffer(from rgba: [UInt8], width: Int, height: Int) -> [Float] {
        var luminance = [Float](repeating: 0, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * 4
                let r = Float(rgba[pixelIndex])
                let g = Float(rgba[pixelIndex + 1])
                let b = Float(rgba[pixelIndex + 2])
                luminance[y * width + x] = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
            }
        }

        return luminance
    }

    private static func detectFaceCount(in cgImage: CGImage) -> Int {
        #if targetEnvironment(simulator)
        return 0
        #else
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            return request.results?.count ?? 0
        } catch {
            return 0
        }
        #endif
    }

    private static func convertToLab(r: Float, g: Float, b: Float) -> (Float, Float, Float) {
        func pivot(_ value: Float) -> Float {
            let delta: Float = 6 / 29
            let deltaCubed = delta * delta * delta
            if value > deltaCubed {
                return pow(value, 1.0 / 3.0)
            } else {
                return (value / (3 * delta * delta)) + (4.0 / 29.0)
            }
        }

        func srgbToLinear(_ value: Float) -> Float {
            if value <= 0.04045 {
                return value / 12.92
            } else {
                return pow((value + 0.055) / 1.055, 2.4)
            }
        }

        let linearR = srgbToLinear(r)
        let linearG = srgbToLinear(g)
        let linearB = srgbToLinear(b)

        let x = 0.4124 * linearR + 0.3576 * linearG + 0.1805 * linearB
        let y = 0.2126 * linearR + 0.7152 * linearG + 0.0722 * linearB
        let z = 0.0193 * linearR + 0.1192 * linearG + 0.9505 * linearB

        let xn: Float = 0.95047
        let yn: Float = 1.0
        let zn: Float = 1.08883

        let fx = pivot(x / xn)
        let fy = pivot(y / yn)
        let fz = pivot(z / zn)

        let l = max(0, min(100, 116 * fy - 16))
        let a = 500 * (fx - fy)
        let b = 200 * (fy - fz)

        return (l, a, b)
    }

    private static func clamp(_ value: Int, lower: Int, upper: Int) -> Int {
        min(max(value, lower), upper)
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

    private static func prepareNormalizedImage(from image: UIImage, targetSize: CGSize) -> CGImage? {
        guard let source = cgImage(from: image) else { return nil }
        let width = Int(targetSize.width)
        let height = Int(targetSize.height)

        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            )
        else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(source, in: CGRect(origin: .zero, size: targetSize))
        return context.makeImage()
    }

    private static func rgbaPixels(for cgImage: CGImage) -> [UInt8]? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: &data,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            )
        else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
