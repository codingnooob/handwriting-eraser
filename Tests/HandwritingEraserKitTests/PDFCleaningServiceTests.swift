import Foundation
import AppKit
import PDFKit
import Testing
@testable import HandwritingEraserKit

struct PDFCleaningServiceTests {
    @Test @MainActor func rejectsEmptyExports() {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        #expect(throws: InkRemovalError.self) { try PDFCleaningService.writeCleanedDocument(pages: [], to: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test @MainActor func doesNotArtificiallyUpscaleSimpleScannedPages() throws {
        let input = try #require(Bundle.module.url(forResource: "worksheet-answered", withExtension: "png", subdirectory: "Fixtures"))
        let scan = try #require(NSImage(contentsOf: input))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try PDFCleaningService.writeCleanedDocument(pages: [scan], to: output)
        let document = try #require(PDFDocument(url: output))
        let page = try #require(document.page(at: 0))
        let rendered = try PDFCleaningService.renderPage(page)
        let cg = try #require(rendered.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(cg.width == 800 && cg.height == 1024)
        #expect(rendered.size == scan.size)
    }

    @Test @MainActor func rendersCropAndRotationAtOriginalPhysicalSize() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 120,
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let source = NSImage(size: NSSize(width: 400, height: 600))
        source.addRepresentation(bitmap)
        let page = try #require(PDFPage(image: source))
        page.setBounds(NSRect(x: 20, y: 30, width: 300, height: 500), for: .cropBox)
        page.rotation = 90
        let rendered = try PDFCleaningService.renderPage(page)
        let cg = try #require(rendered.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(rendered.size == NSSize(width: 500, height: 300))
        #expect(cg.width == 1536 && cg.height < cg.width)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("rotated-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try PDFCleaningService.writeCleanedDocument(pages: [rendered], to: output)
        let reopened = try #require(PDFDocument(url: output))
        #expect(try #require(reopened.page(at: 0)).bounds(for: .mediaBox).size == NSSize(width: 500, height: 300))
    }

    @Test @MainActor func writesTheActualPageImage() throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let pixels = try #require(bitmap.bitmapData)
        for y in 0..<32 {
            for x in 0..<32 {
                let offset = y * bitmap.bytesPerRow + x * 4
                pixels[offset] = 255
                pixels[offset + 1] = 0
                pixels[offset + 2] = 0
                pixels[offset + 3] = 255
            }
        }
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.addRepresentation(bitmap)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HandwritingEraserTest-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try PDFCleaningService.writeCleanedDocument(pages: [image], to: url))
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == 1)
        let page = try #require(document.page(at: 0))
        let thumbnail: NSImage = page.thumbnail(of: NSSize(width: 32, height: 32), for: .mediaBox)
        let tiff = try #require(thumbnail.tiffRepresentation)
        let rendered = try #require(NSBitmapImageRep(data: tiff))
        let center = try #require(rendered.colorAt(x: 16, y: 16)?.usingColorSpace(.deviceRGB))
        #expect(center.redComponent > 0.8)
        #expect(center.redComponent > center.greenComponent * 2)
        #expect(center.redComponent > center.blueComponent * 2)
    }
}
