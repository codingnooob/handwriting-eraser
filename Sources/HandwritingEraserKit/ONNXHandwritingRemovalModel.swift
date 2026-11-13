import AppKit
import Foundation
import OnnxRuntimeBindings

/// Runs a local handwriting segmenter and repairs only the detected pixels.
/// The detector's ONNX model and all PDF page processing remain on this device.
public final class ONNXHandwritingRemovalModel: HandwritingRemovalModel, Sendable {
    private let worker: HandwritingDetectorWorker

    public init(contentsOf url: URL) throws {
        worker = try HandwritingDetectorWorker(modelURL: url)
    }

    public func removeHandwriting(from source: NSImage) async throws -> NSImage {
        guard let image = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw InkRemovalError.pageRenderingFailed
        }
        let pageSize = source.size
        let cleaned = try await worker.clean(image)
        return NSImage(cgImage: cleaned, size: pageSize)
    }
}

/// An actor serializes expensive page inference and keeps the UI responsive.
private actor HandwritingDetectorWorker {
    private let environment: ORTEnv
    private let session: ORTSession
    private let maxLongEdge = 1536

    init(modelURL: URL) throws {
        let environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))))
        let session = try ORTSession(env: environment, modelPath: modelURL.path, sessionOptions: options)
        guard try session.inputNames() == ["input"], try session.outputNames() == ["logits"] else {
            throw InkRemovalError.unexpectedDetectorInterface
        }
        self.environment = environment
        self.session = session
    }

    func clean(_ image: CGImage) throws -> CGImage {
        try Task.checkCancellation()
        let page = try PageRaster(image: image)
        let scale = min(1.0, Double(maxLongEdge) / Double(max(page.width, page.height)))
        let detectorWidth = max(1, Int((Double(page.width) * scale).rounded()))
        let detectorHeight = max(1, Int((Double(page.height) * scale).rounded()))
        let detectorPage = scale < 1 ? try page.resized(width: detectorWidth, height: detectorHeight) : page
        let smallMask = try detect(in: detectorPage)
        try Task.checkCancellation()
        guard !smallMask.isEmpty else { return try page.cgImage() }
        let completedMask = smallMask.extendingColoredStrokes(in: detectorPage)
        let mask = completedMask.resized(width: page.width, height: page.height).dilated(radius: 1)
        return try BackgroundRepair.apply(to: page, mask: mask).cgImage()
    }

    private func detect(in page: PageRaster) throws -> InkMask {
        // The encoder/decoder's skip connections require compatible sizes.
        // Padding is white and excluded from the returned mask.
        let width = ((page.width + 31) / 32) * 32
        let height = ((page.height + 31) / 32) * 32
        let plane = width * height
        let inputData = NSMutableData(length: 3 * plane * MemoryLayout<Float>.size)!
        let input = inputData.mutableBytes.bindMemory(to: Float.self, capacity: 3 * plane)
        input.initialize(repeating: 0.5, count: 3 * plane) // white: 255/255 - 0.5
        for y in 0..<page.height {
            for x in 0..<page.width {
                let source = (y * page.width + x) * 4
                let destination = y * width + x
                input[destination] = Float(page.pixels[source]) / 255 - 0.5
                input[plane + destination] = Float(page.pixels[source + 1]) / 255 - 0.5
                input[2 * plane + destination] = Float(page.pixels[source + 2]) / 255 - 0.5
            }
        }
        let value = try ORTValue(tensorData: inputData, elementType: .float,
                                 shape: [1, 3, NSNumber(value: height), NSNumber(value: width)])
        let outputs = try session.run(withInputs: ["input": value], outputNames: ["logits"], runOptions: nil)
        guard let output = outputs["logits"] else { throw InkRemovalError.modelDidNotReturnAnOutput }
        let info = try output.tensorTypeAndShapeInfo()
        guard info.elementType == .float, info.shape.map(\.intValue) == [1, 4, height, width] else {
            throw InkRemovalError.unexpectedDetectorInterface
        }
        let data = try output.tensorData()
        guard data.length == 4 * plane * MemoryLayout<Float>.size else {
            throw InkRemovalError.unexpectedDetectorInterface
        }
        let logits = data.bytes.bindMemory(to: Float.self, capacity: 4 * plane)
        var mask = [UInt8](repeating: 0, count: page.width * page.height)
        for y in 0..<page.height {
            for x in 0..<page.width {
                let i = y * width + x
                let a = logits[i], b = logits[plane + i]
                let c = logits[2 * plane + i], d = logits[3 * plane + i]
                let maximum = max(max(a, b), max(c, d))
                // The model card recommends softmax(handwriting + overlap) > 0.6.
                let ink = expf(c - maximum) + expf(d - maximum)
                let other = expf(a - maximum) + expf(b - maximum)
                if ink > 1.5 * other { mask[y * page.width + x] = 1 }
            }
        }
        return InkMask(width: page.width, height: page.height, pixels: mask)
    }
}
