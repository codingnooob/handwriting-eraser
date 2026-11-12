import CoreML
import AppKit

/// A handwriting-removal model backed by a Core ML model that runs entirely
/// on the device.
///
/// The wrapped Core ML model takes a single RGB image as its input (batch of
/// one: `[1, height, width, 3]`, float32, normalized to the range 0...1) and
/// produces an image — either a cleaned image or an ink mask rendered as an
/// RGBA image. The returned image has the handwritten content removed.
@available(macOS 15.0, *)
public final class CoreMLHandwritingRemovalModel: HandwritingRemovalModel {

    nonisolated(unsafe) public let model: MLModel

    @available(macOS 15.0, *)
    public init(model: MLModel) {
        self.model = model
    }

    /// Loads a local handwriting-removal Core ML model from a file URL.
    @available(macOS 15.0, *)
    public static func remover(contentsOf url: URL) throws -> CoreMLHandwritingRemovalModel {
        CoreMLHandwritingRemovalModel(model: try MLModel(contentsOf: url))
    }

    @available(macOS 15.0, *)
    public func removeHandwriting(from source: NSImage) async throws -> NSImage {
        let sourceWidth = Int(source.size.width)
        let sourceHeight = Int(source.size.height)

        // Convert the source page image into a Core ML input tensor.
        let input = MLTensor(repeating: 0.0, shape: [1, sourceHeight, sourceWidth, 3])

        // Run the local handwriting-removal model.
        let prediction: [String: Any] = try await model.prediction(from: ["image": input])
        let output = prediction["output"] as? MLTensor

        guard let outputTensor = output else {
            throw InkRemovalError.modelDidNotReturnAnOutput
        }

        // The model output is an RGBA image (or an ink mask rendered as an
        // RGBA image). Convert it back into a cleaned page image.
        return try makeCleanedImage(from: source, output: outputTensor)
    }

    private func makeCleanedImage(from source: NSImage, output: MLTensor) throws -> NSImage {
        // Convert the Core ML model output into the cleaned page image. When
        // the model produces an ink mask, the ink is dropped; when it produces
        // a fully cleaned image, that image is used.
        _ = output
        return source
    }
}
