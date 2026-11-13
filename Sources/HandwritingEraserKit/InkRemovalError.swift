import Foundation

/// Errors produced while removing handwriting from a document.
public enum InkRemovalError: LocalizedError {
    case pageRenderingFailed
    case modelDidNotReturnAnOutput
    case modelUnavailable
    case modelDownloadInProgress
    case processingInProgress
    case unexpectedDetectorInterface
    case handwritingDetectionNotImplemented
    case pdfWriteFailed

    public var errorDescription: String? {
        switch self {
        case .pageRenderingFailed: "A PDF page could not be rendered."
        case .modelDidNotReturnAnOutput: "The local model did not return an image."
        case .modelUnavailable: "Download the local model before processing a PDF."
        case .modelDownloadInProgress: "The local model is already being installed."
        case .processingInProgress: "A document is already being processed."
        case .unexpectedDetectorInterface: "The handwriting detector has an unexpected input or output format."
        case .handwritingDetectionNotImplemented:
            "LaMa requires a separate mask. Use the local handwriting detector instead."
        case .pdfWriteFailed: "Could not write the cleaned PDF."
        }
    }
}
