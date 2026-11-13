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
    public func clean(images: [NSImage], onPage: ((Int, Int) -> Void)? = nil) async throws -> [NSImage] {
        var cleanedImages: [NSImage] = []
        for (index, image) in images.enumerated() {
            try Task.checkCancellation()
            onPage?(index + 1, images.count)
            cleanedImages.append(try await model.removeHandwriting(from: image))
        }
        return cleanedImages
    }

    /// Render the visible crop box at up to 1536 pixels on its long edge while
    /// retaining its original physical size for PDF export.
    public static func renderPage(_ page: PDFPage) throws -> NSImage {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw InkRemovalError.pageRenderingFailed
        }
        // Do not enlarge a simple scanned page beyond its embedded bitmap's
        // native resolution. Upscaling low-resolution scans can make printed
        // text look like handwriting to the segmentation model.
        let edge = min(1536, nativeScanLongEdge(page, bounds: bounds) ?? 1536)
        let image = page.thumbnail(of: CGSize(width: edge, height: edge), for: .cropBox)
        guard image.isValid, let raster = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              raster.width > 0, raster.height > 0 else {
            throw InkRemovalError.pageRenderingFailed
        }
        let rotation = ((page.rotation % 360) + 360) % 360
        image.size = rotation == 90 || rotation == 270
            ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        return image
    }

    public func renderPage(_ page: PDFPage) throws -> NSImage {
        try Self.renderPage(page)
    }

    /// Conservative detection of a single, page-shaped image XObject. For
    /// vector or mixed/unknown pages, use the normal 1536-pixel render instead.
    private static func nativeScanLongEdge(_ page: PDFPage, bounds: CGRect) -> Int? {
        guard let pageDictionary = page.pageRef?.dictionary else { return nil }
        var current: CGPDFDictionaryRef? = pageDictionary
        var resources: CGPDFDictionaryRef?
        // PDF resources may be inherited from a parent page-tree node.
        for _ in 0..<32 {
            guard let dictionary = current else { break }
            if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), resources != nil { break }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "Parent", &parent) else { break }
            current = parent
        }
        guard let resources else { return nil }
        var xObjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects), let xObjects else { return nil }

        struct ScanInfo { var images: [(Int, Int)] = []; var otherObjects = 0 }
        var info = ScanInfo()
        withUnsafeMutablePointer(to: &info) { pointer in
            CGPDFDictionaryApplyFunction(xObjects, { _, object, context in
                let info = context!.assumingMemoryBound(to: ScanInfo.self)
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let dictionary = CGPDFStreamGetDictionary(stream) else {
                    info.pointee.otherObjects += 1
                    return
                }
                var subtype: UnsafePointer<CChar>?
                var width: CGPDFInteger = 0, height: CGPDFInteger = 0
                if CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
                   String(cString: subtype) == "Image",
                   CGPDFDictionaryGetInteger(dictionary, "Width", &width),
                   CGPDFDictionaryGetInteger(dictionary, "Height", &height), width > 0, height > 0 {
                    info.pointee.images.append((width, height))
                } else {
                    info.pointee.otherObjects += 1
                }
            }, pointer)
        }
        guard info.otherObjects == 0, info.images.count == 1, let (width, height) = info.images.first,
              min(width, height) >= 128 else { return nil }
        let imageAspect = Double(max(width, height)) / Double(min(width, height))
        let pageAspect = Double(max(bounds.width, bounds.height) / min(bounds.width, bounds.height))
        guard abs(imageAspect / pageAspect - 1) < 0.1 else { return nil }
        return max(width, height)
    }

    /// Writes a cleaned document containing the given page images.
    public static func writeCleanedDocument(pages: [NSImage], to url: URL) throws -> Bool {
        guard !pages.isEmpty else { throw InkRemovalError.pageRenderingFailed }
        let document = PDFDocument()
        for (index, image) in pages.enumerated() {
            guard image.isValid, let page = PDFPage(image: image) else {
                throw InkRemovalError.pageRenderingFailed
            }
            document.insert(page, at: index)
        }
        guard document.write(toFile: url.path) else {
            throw InkRemovalError.pdfWriteFailed
        }
        return true
    }
}
