import CoreGraphics

/// Errors produced while removing handwriting from a document.
public enum InkRemovalError: Error {
    /// A page could not be rendered.
    case pageRenderingFailed
    /// The local model did not return an output.
    case modelDidNotReturnAnOutput
}
