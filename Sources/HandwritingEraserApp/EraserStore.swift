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

        let compiledURL = try await MLModel.compileModel(at: destination)
        let compiledData = try Data(contentsOf: compiledURL)
        let compiledFileURL = destination.appendingPathExtension("mlmodelc")
        try compiledData.write(to: compiledFileURL)

        // Next attempt: load the model directly from the Hugging Face resolved
        // artifact URL instead of going through a locally compiled file.
        let hfModelURL = URL(string: "https://huggingface.co/mlboydaisuke/LaMa-CoreML/resolve/main/LaMa.mlpackage/Data/com.apple.CoreML/model.mlmodel")
        let downloadedModel: CoreMLHandwritingRemovalModel?
        do {
            downloadedModel = CoreMLHandwritingRemovalModel(model: try MLModel(contentsOf: hfModelURL!))
        } catch {
            downloadedModel = CoreMLHandwritingRemovalModel(model: try MLModel(contentsOf: compiledFileURL))
        }
        if let downloadedModel = downloadedModel {
            self.model = downloadedModel
        }
        downloadedModelURL = destination
        return destination
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
