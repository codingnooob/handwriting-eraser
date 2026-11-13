import Foundation
import AppKit
import PDFKit
import Testing
import HandwritingEraserKit
@testable import HandwritingEraserApp

struct EraserStoreTests {
    @Test @MainActor func startsWithoutAModelWhenTheCacheIsEmpty() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HandwritingEraserStoreTests-\(UUID().uuidString)")
        let store = EraserStore(modelDirectory: root)
        #expect(store.model == nil)
        #expect(store.downloadedModelURL == nil)
        #expect(!store.isDownloadingModel)
    }

    @Test @MainActor func importsAllPagesAndReportsInvalidFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HandwritingEraserImport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func image(red: UInt8, blue: UInt8, size: NSSize) -> NSImage {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let bytes = bitmap.bitmapData!
            for y in 0..<32 { for x in 0..<32 {
                let offset = y * bitmap.bytesPerRow + x * 4
                bytes[offset] = red
                bytes[offset + 1] = 0
                bytes[offset + 2] = blue
                bytes[offset + 3] = 255
            } }
            let image = NSImage(size: size)
            image.addRepresentation(bitmap)
            return image
        }
        let url = root.appendingPathComponent("input.pdf")
        _ = try PDFCleaningService.writeCleanedDocument(pages: [image(red: 255, blue: 0, size: NSSize(width: 400, height: 600)),
                                                          image(red: 0, blue: 255, size: NSSize(width: 600, height: 400))], to: url)
        let store = EraserStore(modelDirectory: root.appendingPathComponent("models"))
        store.loadDocument(at: url)
        #expect(store.errorMessage == nil)
        #expect(store.documentURL == url)
        #expect(store.pageImages.count == 2)
        #expect(store.pageImages[0].size == NSSize(width: 400, height: 600))
        #expect(store.pageImages[1].size == NSSize(width: 600, height: 400))
        let bad = root.appendingPathComponent("invalid.pdf")
        try Data("not a PDF".utf8).write(to: bad)
        store.loadDocument(at: bad)
        #expect(store.errorMessage != nil)
        #expect(store.documentURL == url) // An invalid import does not discard the prior document.
        #expect(store.pageImages.count == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HANDWRITING_ERASER_INTEGRATION"] == "1",
                   "Downloads and verifies the real 176 MB detector"))
    @MainActor func installsThroughStoreAndRestoresAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HandwritingEraserStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EraserStore(modelDirectory: root)
        let installation = Task { try await store.downloadModel() }
        for _ in 0..<100 where !store.isDownloadingModel { await Task.yield() }
        #expect(store.isDownloadingModel)
        do {
            _ = try await store.downloadModel()
            Issue.record("A second installation should be rejected while one is in progress")
        } catch InkRemovalError.modelDownloadInProgress {
            // Expected.
        } catch {
            Issue.record("Unexpected duplicate-install error: \(error)")
        }
        let url = try await installation.value
        #expect(store.model is ONNXHandwritingRemovalModel)
        #expect(store.downloadedModelURL == url)
        #expect(!store.isDownloadingModel)
        #expect(store.modelStatus == "Local handwriting detector installed.")
        let reopened = EraserStore(modelDirectory: root)
        for _ in 0..<1200 where reopened.isLoadingModel { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!reopened.isLoadingModel)
        #expect(reopened.model is ONNXHandwritingRemovalModel)
        #expect(reopened.downloadedModelURL == url)
    }
}
