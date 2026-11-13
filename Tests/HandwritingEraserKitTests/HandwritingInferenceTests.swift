import Foundation
import AppKit
import PDFKit
import Testing
@testable import HandwritingEraserKit

struct HandwritingInferenceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HANDWRITING_ERASER_DETECTOR_MODEL"] != nil,
                   "Set HANDWRITING_ERASER_DETECTOR_MODEL to the verified ONNX model"))
    @MainActor func removesSyntheticHandwritingAndExportsMultipagePDF() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HANDWRITING_ERASER_DETECTOR_MODEL"])
        let answeredURL = try #require(Bundle.module.url(forResource: "worksheet-answered", withExtension: "png", subdirectory: "Fixtures"))
        let referenceURL = try #require(Bundle.module.url(forResource: "worksheet-clean", withExtension: "png", subdirectory: "Fixtures"))
        let answered = try #require(NSImage(contentsOf: answeredURL))
        let reference = try #require(NSImage(contentsOf: referenceURL))
        let model = try ONNXHandwritingRemovalModel(contentsOf: URL(fileURLWithPath: path))
        let service = PDFCleaningService(model: model)
        var progress: [Int] = []
        let pages = try await service.clean(images: [answered, reference]) { page, _ in progress.append(page) }
        #expect(progress == [1, 2])
        #expect(pages.count == 2)

        func raster(_ image: NSImage) throws -> PageRaster {
            try PageRaster(image: #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        }
        let before = try raster(answered)
        let expected = try raster(reference)
        let after = try raster(pages[0])
        var ink = 0, inkRemoved = 0, printed = 0, printedPreserved = 0
        for i in 0..<(before.width * before.height) {
            let p = i * 4
            let sourceDifference = (0..<3).map { abs(Int(before.pixels[p + $0]) - Int(expected.pixels[p + $0])) }.max()!
            let resultDifference = (0..<3).map { abs(Int(after.pixels[p + $0]) - Int(expected.pixels[p + $0])) }.max()!
            if sourceDifference > 30 {
                ink += 1
                if resultDifference < 30 { inkRemoved += 1 }
            }
            if sourceDifference < 10 && (0..<3).allSatisfy({ expected.pixels[p + $0] < 128 }) {
                printed += 1
                if resultDifference < 10 { printedPreserved += 1 }
            }
        }
        #expect(ink > 1000 && printed > 1000)
        #expect(Double(inkRemoved) / Double(ink) > 0.90)
        #expect(Double(printedPreserved) / Double(printed) > 0.99)

        let output = FileManager.default.temporaryDirectory.appendingPathComponent("HandwritingInference-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try PDFCleaningService.writeCleanedDocument(pages: pages, to: output)
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 2)
        #expect(try #require(document.page(at: 0)).bounds(for: .mediaBox).size == answered.size)
        #expect(try #require(document.page(at: 1)).bounds(for: .mediaBox).size == reference.size)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HANDWRITING_ERASER_SAMPLE_IMAGE"] != nil,
                   "Set HANDWRITING_ERASER_SAMPLE_IMAGE and HANDWRITING_ERASER_DETECTOR_MODEL to run an actual sample"))
    func removesDetectedPixelsFromSample() async throws {
        let environment = ProcessInfo.processInfo.environment
        let inputPath = try #require(environment["HANDWRITING_ERASER_SAMPLE_IMAGE"])
        let modelPath = try #require(environment["HANDWRITING_ERASER_DETECTOR_MODEL"])
        let source = try #require(NSImage(contentsOfFile: inputPath))
        let model = try ONNXHandwritingRemovalModel(contentsOf: URL(fileURLWithPath: modelPath))
        let start = Date()
        let cleaned = try await model.removeHandwriting(from: source)
        let originalImage = try #require(source.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let cleanedImage = try #require(cleaned.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(cleanedImage.width == originalImage.width)
        #expect(cleanedImage.height == originalImage.height)
        let before = try PageRaster(image: originalImage)
        let after = try PageRaster(image: cleanedImage)
        var changed = 0
        for index in 0..<(before.width * before.height) {
            if before.pixels[index * 4] != after.pixels[index * 4] ||
                before.pixels[index * 4 + 1] != after.pixels[index * 4 + 1] ||
                before.pixels[index * 4 + 2] != after.pixels[index * 4 + 2] { changed += 1 }
        }
        print("Actual sample: \(before.width)x\(before.height), \(changed) pixels changed, \(Date().timeIntervalSince(start)) seconds")
        #expect(changed > 0)
        if let output = environment["HANDWRITING_ERASER_SAMPLE_OUTPUT"] {
            let bitmap = NSBitmapImageRep(cgImage: cleanedImage)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: output))
        }
    }
}
