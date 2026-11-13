import Foundation
import CoreGraphics

/// A consistently ordered, opaque RGBA bitmap. Pixel operations below use the
/// same row order for the source, model input, mask, and exported CGImage.
struct PageRaster: Sendable {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init(image: CGImage, width: Int? = nil, height: Int? = nil) throws {
        let w = width ?? image.width
        let h = height ?? image.height
        guard w > 0, h > 0 else { throw InkRemovalError.pageRenderingFailed }
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { memory -> Bool in
            guard let context = CGContext(
                data: memory.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw InkRemovalError.pageRenderingFailed }
        self.init(width: w, height: h, pixels: bytes)
    }

    func cgImage() throws -> CGImage {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw InkRemovalError.pageRenderingFailed
        }
        return image
    }

    func resized(width: Int, height: Int) throws -> PageRaster {
        try PageRaster(image: cgImage(), width: width, height: height)
    }
}

struct InkMask: Sendable {
    let width: Int
    let height: Int
    var pixels: [UInt8] // 0 = preserve, 1 = repair

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0 && pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    var isEmpty: Bool { !pixels.contains(where: { $0 != 0 }) }

    /// Include the antialiased edge around detected strokes, not whole words or boxes.
    func dilated(radius: Int) -> InkMask {
        guard radius > 0 else { return self }
        var result = pixels
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] != 0 {
                for yy in max(0, y - radius)...min(height - 1, y + radius) {
                    for xx in max(0, x - radius)...min(width - 1, x + radius) {
                        result[yy * width + xx] = 1
                    }
                }
            }
        }
        return InkMask(width: width, height: height, pixels: result)
    }

    /// Complete a connected coloured stroke when the detector marked only part
    /// of it. Neutral/dark print is never grown this way. Large coloured regions
    /// are left alone to avoid flooding page backgrounds or diagrams.
    func extendingColoredStrokes(in page: PageRaster) -> InkMask {
        precondition(page.width == width && page.height == height)
        var colors = [UInt8](repeating: 0, count: pixels.count)
        for i in 0..<pixels.count {
            let r = Int(page.pixels[i * 4]), g = Int(page.pixels[i * 4 + 1]), b = Int(page.pixels[i * 4 + 2])
            if b > r + 25 && b > g + 20 { colors[i] = 1 }
            else if r > g + 25 && r > b + 20 { colors[i] = 2 }
            else if g > r + 25 && g > b + 20 { colors[i] = 3 }
        }
        var visited = [UInt8](repeating: 0, count: pixels.count)
        var result = pixels
        let maxComponent = max(4096, pixels.count / 200)
        for seed in 0..<pixels.count where pixels[seed] != 0 && colors[seed] != 0 && visited[seed] == 0 {
            let color = colors[seed]
            var queue = [seed]
            visited[seed] = 1
            var head = 0
            while head < queue.count {
                let point = queue[head]
                head += 1
                let x = point % width, y = point / width
                for yy in max(0, y - 1)...min(height - 1, y + 1) {
                    for xx in max(0, x - 1)...min(width - 1, x + 1) {
                        let next = yy * width + xx
                        if visited[next] == 0 && colors[next] == color {
                            visited[next] = 1
                            queue.append(next)
                        }
                    }
                }
            }
            if queue.count <= maxComponent {
                for point in queue { result[point] = 1 }
            }
        }
        return InkMask(width: width, height: height, pixels: result)
    }

    func resized(width newWidth: Int, height newHeight: Int) -> InkMask {
        guard newWidth != width || newHeight != height else { return self }
        var result = [UInt8](repeating: 0, count: newWidth * newHeight)
        for y in 0..<newHeight {
            let sy = min(height - 1, y * height / newHeight)
            for x in 0..<newWidth {
                let sx = min(width - 1, x * width / newWidth)
                result[y * newWidth + x] = pixels[sy * width + sx]
            }
        }
        return InkMask(width: newWidth, height: newHeight, pixels: result)
    }
}

/// Deterministic local background interpolation. Unlike generative inpainting,
/// this cannot invent text. Pixels outside the mask are copied byte-for-byte.
/// Printed content *inside* the mask cannot be recovered and may be removed.
enum BackgroundRepair {
    static func apply(to source: PageRaster, mask: InkMask) -> PageRaster {
        precondition(source.width == mask.width && source.height == mask.height)
        guard !mask.isEmpty else { return source }
        let width = source.width
        let height = source.height
        let fallback = medianBackground(source: source, mask: mask)
        let input = source.pixels
        var output = input
        let directions = [(dx: -1, dy: 0), (dx: 1, dy: 0), (dx: 0, dy: -1), (dx: 0, dy: 1)]

        for y in 0..<height {
            for x in 0..<width where mask.pixels[y * width + x] != 0 {
                var candidates: [(offset: Int, distance: Int, brightness: Int)] = []
                for direction in directions {
                    // A large solid marked area falls back to the page median.
                    for distance in 1...48 {
                        let xx = x + direction.dx * distance
                        let yy = y + direction.dy * distance
                        guard xx >= 0, xx < width, yy >= 0, yy < height else { break }
                        let index = yy * width + xx
                        if mask.pixels[index] == 0 {
                            let offset = index * 4
                            let brightness = Int(input[offset]) + Int(input[offset + 1]) + Int(input[offset + 2])
                            candidates.append((offset, distance, brightness))
                            break
                        }
                    }
                }
                let offset = (y * width + x) * 4
                guard let brightest = candidates.map(\.brightness).max() else {
                    output[offset] = fallback.0
                    output[offset + 1] = fallback.1
                    output[offset + 2] = fallback.2
                    output[offset + 3] = 255
                    continue
                }

                // Prefer nearby paper over a dark printed character on one side.
                // Weighted interpolation retains gentle page color/shading changes.
                var sums = [Int](repeating: 0, count: 3)
                var totalWeight = 0
                for candidate in candidates where candidate.brightness >= brightest - 90 {
                    let weight = max(1, 256 / candidate.distance)
                    for channel in 0..<3 { sums[channel] += Int(input[candidate.offset + channel]) * weight }
                    totalWeight += weight
                }
                for channel in 0..<3 { output[offset + channel] = UInt8(sums[channel] / totalWeight) }
                output[offset + 3] = 255
            }
        }
        return PageRaster(width: width, height: height, pixels: output)
    }

    private static func medianBackground(source: PageRaster, mask: InkMask) -> (UInt8, UInt8, UInt8) {
        var histogram = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        var samples = 0
        let stride = max(1, mask.pixels.count / 50_000)
        for index in Swift.stride(from: 0, to: mask.pixels.count, by: stride) where mask.pixels[index] == 0 {
            for channel in 0..<3 { histogram[channel][Int(source.pixels[index * 4 + channel])] += 1 }
            samples += 1
        }
        guard samples > 0 else { return (255, 255, 255) }
        func median(_ channel: Int) -> UInt8 {
            var sum = 0
            for value in 0..<256 {
                sum += histogram[channel][value]
                if sum >= (samples + 1) / 2 { return UInt8(value) }
            }
            return 255
        }
        return (median(0), median(1), median(2))
    }
}
