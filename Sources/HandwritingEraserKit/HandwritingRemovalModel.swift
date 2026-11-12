import AppKit

/// A handwriting-removal model that runs fully on-device (no cloud).
///
/// Implementations wrap a local AI model (for example a Core ML image model
/// that segments or inpaints handwritten ink) and expose a single operation:
/// given a page image, produce a copy of the image with the handwriting
/// removed.
public protocol HandwritingRemovalModel: AnyObject, Sendable {

    /// Returns a new image with the handwriting contained in `source`
    /// removed. The source image is never mutated.
    func removeHandwriting(from source: NSImage) async throws -> NSImage
}
