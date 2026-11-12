import Foundation
import Combine
import AppKit
import PDFKit
import CoreGraphics
import CoreML
import HandwritingEraserKit

@MainActor
public final class EraserStore: ObservableObject {

    @Published public var documentURL: URL?
    @Published public var pageImages: [NSImage] = []
    @Published public var cleanedPages: [NSImage] = []
    @Published public var isProcessing = false
    @Published public var errorMessage: String?
    @Published public var cleanedDocumentURL: URL?
    @Published public var model: HandwritingRemovalModel?
    @Published public var modelDownloadURLString: String = "https://huggingface.co/mlboydaisuke/LaMa-CoreML/resolve/main/LaMa.mlpackage/Data/com.apple.CoreML/model.mlmodel"
    @Published public var downloadedModelURL: URL?

    @Published public var isImporterPresented = false

    public init() {
        self.model = nil
    }

    private func logError(_ message: String) {
        let logsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let logURL = logsDirectory.appendingPathComponent("handwriting-eraser-errors.log")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let entry = "[\(formatter.string(from: Date()))] \(message)\n"
        if let data = entry.data(using: .utf8) {
            try? data.write(to: logURL)
        }
    }

    @available(macOS 15.0, *)
    private static func makeDefaultModel() -> HandwritingRemovalModel? {
        guard let url = Bundle.main.url(forResource: "HandwritingRemover", withExtension: "mlmodel") else { return nil }
        return try? CoreMLHandwritingRemovalModel.remover(contentsOf: url)
    }

    public func loadDocument(at url: URL) {
        // Load and render the pages of the imported PDF.
        guard let document = PDFDocument(url: url) else {
            errorMessage = "Could not open the selected document as a PDF."
            return
        }
        do {
            var images: [NSImage] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                images.append(try renderPage(page))
            }
            pageImages = images
            documentURL = url
            cleanedPages = []
            cleanedDocumentURL = nil
        } catch {
            errorMessage = "Failed to render PDF pages: \(error.localizedDescription)"
            logError("PDF page rendering failed: \(error.localizedDescription)")
        }
    }

    public func renderPage(_ page: PDFPage) throws -> NSImage {
        let source: NSImage = page.thumbnail(of: CGSize(width: 612, height: 792), for: .mediaBox)
        return source
    }

    @available(macOS 15.0, *)
    public func downloadModel(from url: URL) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw URLError(.badServerResponse)
        }

        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = directory.appendingPathComponent("HandwritingRemover-\(Int(Date().timeIntervalSince1970)).mlmodel")
        try data.write(to: destination)

        var compiledFileURL: URL? = nil
        do {
            let compiledURL = try await MLModel.compileModel(at: destination)
            let compiledData = try Data(contentsOf: compiledURL)
            let compiledDirectory = destination.deletingLastPathComponent().appendingPathComponent("HandwritingRemover")
            try FileManager.default.createDirectory(at: compiledDirectory, withIntermediateDirectories: true)
            let compiledCoreDataURL = compiledDirectory.appendingPathComponent("coremldata.bin")
            try compiledData.write(to: compiledCoreDataURL)
            compiledFileURL = compiledCoreDataURL
        } catch {
            compiledFileURL = nil
        }

        // Next attempt: load the model directly from the Hugging Face resolved
        // artifact URL instead of going through a locally compiled file.
        let hfModelURL = URL(string: "https://huggingface.co/mlboydaisuke/LaMa-CoreML/resolve/main/LaMa.mlpackage/Data/com.apple.CoreML/model.mlmodel")

        let candidates: [URL] = [
            hfModelURL ?? destination,
            compiledFileURL ?? destination,
            destination,
        ]

        var lastError: Error?
        var resolvedModel: CoreMLHandwritingRemovalModel?
        for candidate in candidates {
            do {
                let candidateModel = CoreMLHandwritingRemovalModel(model: try MLModel(contentsOf: candidate))
                resolvedModel = candidateModel
                break
            } catch {
                lastError = error
            }
        }
        if let resolvedModel = resolvedModel {
            self.model = resolvedModel
            downloadedModelURL = destination
            return destination
        }
        let attemptedPaths = candidates.map { $0.path }.joined(separator: ", ")
        let failureMessage = "Local handwriting model load failed for paths: \(attemptedPaths). Error: \(String(describing: lastError))"
        logError(failureMessage)
        throw NSError(domain: "HandwritingEraser", code: 1, userInfo: [NSLocalizedDescriptionKey: failureMessage])
    }

    @available(macOS 15.0, *)
    public func cleanImages() async throws -> [NSImage] {
        var resolvedModel = model
        if resolvedModel == nil {
            resolvedModel = Self.makeDefaultModel()
        }
        guard let model = resolvedModel else {
            throw InkRemovalError.modelDidNotReturnAnOutput
        }
        guard !pageImages.isEmpty else {
            throw InkRemovalError.pageRenderingFailed
        }

        isProcessing = true
        defer { isProcessing = false }

        let service = PDFCleaningService(model: model)
        return try await service.clean(images: pageImages)
    }

    @available(macOS 15.0, *)
    public func exportCleaned(images: [NSImage]) throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("handwriting-eraser-\(Int(Date().timeIntervalSince1970)).pdf")
        try PDFCleaningService.writeCleanedDocument(pages: images, to: url)
        cleanedDocumentURL = url
        return url
    }
}
