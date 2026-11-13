import CoreML
import AppKit

/// Legacy LaMa adapter, retained for compatibility. LaMa cannot detect
/// handwriting without a separate mask; use ONNXHandwritingRemovalModel.
@available(*, deprecated, message: "Use ONNXHandwritingRemovalModel for handwriting detection and removal.")
@available(macOS 15.0, *)
public final class CoreMLHandwritingRemovalModel: HandwritingRemovalModel {

    nonisolated(unsafe) public let model: MLModel

    @available(macOS 15.0, *)
    public init(model: MLModel) {
        self.model = model
    }

    /// Loads an already-compiled local `.mlmodelc` directory.
    @available(macOS 15.0, *)
    public static func remover(contentsOf url: URL) throws -> CoreMLHandwritingRemovalModel {
        CoreMLHandwritingRemovalModel(model: try MLModel(contentsOf: url))
    }

    @available(macOS 15.0, *)
    public func removeHandwriting(from source: NSImage) async throws -> NSImage {
        // Returning the source unchanged (or supplying an all-zero tensor)
        // would falsely claim that handwriting was removed. A handwriting
        // detector and mask-to-image pipeline are still required.
        throw InkRemovalError.handwritingDetectionNotImplemented
    }
}
