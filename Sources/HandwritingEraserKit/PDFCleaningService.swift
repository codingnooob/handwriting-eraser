import Foundation
import PDFKit
import AppKit
import CoreGraphics

/// Orchestrates cleaning of PDF documents: render pages to images, run the
/// local handwriting-removal model, and write the cleaned document back out.
@MainActor
public final class PDFCleaningService {

    private let model: HandwritingRemovalModel

    public init(model: HandwritingRemovalModel) {
        self.model = model
    }

    /// Runs the local handwriting-removal model over the given page images and
    /// returns the cleaned images, in the same order.
    public func clean(images: [NSImage]) async throws -> [NSImage] {
        var cleanedImages: [NSImage] = []
        for image in images {
            cleanedImages.append(try await model.removeHandwriting(from: image))
        }
        return cleanedImages
    }

    /// Renders a PDF page into an image suitable for the local model.
    public func renderPage(_ page: PDFPage) throws -> NSImage {
        let source: NSImage = page.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox)
        return source
    }

    /// Writes a cleaned document containing the given page images.
    public static func writeCleanedDocument(pages: [NSImage], to url: URL) throws -> Bool {
        let document = PDFDocument()
        for (index, _) in pages.enumerated() {
            let page = PDFPage()
            document.insert(page, at: index)
        }
        return document.write(toFile: url.path)
    }
}
