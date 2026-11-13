import Foundation
import Combine
import AppKit
import PDFKit
import CoreGraphics
import HandwritingEraserKit

@available(macOS 15.0, *)
@MainActor
public final class EraserStore: ObservableObject {

    private let modelDirectory: URL

    @Published public var documentURL: URL?
    @Published public var pageImages: [NSImage] = []
    @Published public var cleanedPages: [NSImage] = []
    @Published public var showCleaned = true
    @Published public var isProcessing = false
    @Published public var isDownloadingModel = false
    @Published public var isLoadingModel = false
    @Published public var processingStatus: String?
    @Published public var errorMessage: String?
    @Published public var modelStatus: String?
    @Published public var cleanedDocumentURL: URL?
    @Published public var model: HandwritingRemovalModel?
    @Published public var downloadedModelURL: URL?

    @Published public var isImporterPresented = false

    public init(modelDirectory: URL = HandwritingDetectorInstaller.defaultDirectory()) {
        self.modelDirectory = modelDirectory
        let installer = HandwritingDetectorInstaller(directory: modelDirectory)
        if FileManager.default.fileExists(atPath: installer.installedModelURL.path) {
            isLoadingModel = true
            modelStatus = "Loading the local handwriting detector…"
            Task { await restoreCachedModel(installer) }
        }
    }

    private func restoreCachedModel(_ installer: HandwritingDetectorInstaller) async {
        defer { isLoadingModel = false }
        do {
            let load = Task.detached(priority: .userInitiated) {
                let url = try installer.verifyInstalledModel()
                return (url, try ONNXHandwritingRemovalModel(contentsOf: url))
            }
            let (url, loadedModel) = try await load.value
            model = loadedModel
            downloadedModelURL = url
            modelStatus = "Local handwriting detector installed."
        } catch {
            modelStatus = "Could not load the cached detector. Download it again."
            logError("Could not load the cached handwriting detector: \(String(describing: error))")
        }
    }

    private func logError(_ message: String) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let logURL = directory.appendingPathComponent("handwriting-eraser-errors.log")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let entry = "[\(formatter.string(from: Date()))] \(message)\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: logURL.path),
               !FileManager.default.createFile(atPath: logURL.path, contents: nil) {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(entry.utf8))
        } catch {
            NSLog("Could not write diagnostics to %@: %@", logURL.path, error.localizedDescription)
        }
    }

    public func loadDocument(at url: URL) {
        errorMessage = nil
        // SwiftUI's file importer may return a security-scoped URL in a sandbox.
        // All pages are rendered before access is released.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
            errorMessage = "Could not open the PDF. It may be empty, damaged, or password-protected."
            return
        }
        do {
            var images: [NSImage] = []
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { throw InkRemovalError.pageRenderingFailed }
                images.append(try renderPage(page))
            }
            pageImages = images
            documentURL = url
            cleanedPages = []
            cleanedDocumentURL = nil
        } catch {
            errorMessage = "Failed to render PDF pages: \(error.localizedDescription)"
            logError("PDF page rendering failed: \(String(describing: error))")
        }
    }

    public func renderPage(_ page: PDFPage) throws -> NSImage {
        try PDFCleaningService.renderPage(page)
    }

    public func reportImportError(_ error: Error) {
        errorMessage = "Could not import the PDF: \(error.localizedDescription)"
        logError("PDF import failed: \(String(describing: error))")
    }

    public func reportProcessingError(_ error: Error) {
        errorMessage = "Handwriting removal failed: \(error.localizedDescription)"
        logError("Handwriting removal or export failed: \(String(describing: error))")
    }

    @available(macOS 15.0, *)
    public func downloadModel() async throws -> URL {
        guard !isDownloadingModel && !isLoadingModel else { throw InkRemovalError.modelDownloadInProgress }
        isDownloadingModel = true
        errorMessage = nil
        modelStatus = nil
        defer { isDownloadingModel = false }

        do {
            let installer = HandwritingDetectorInstaller(directory: modelDirectory)
            let installation = Task.detached(priority: .userInitiated) {
                let url = try await installer.install()
                return (url, try ONNXHandwritingRemovalModel(contentsOf: url))
            }
            let (url, loadedModel) = try await withTaskCancellationHandler {
                try await installation.value
            } onCancel: {
                installation.cancel()
            }
            self.model = loadedModel
            downloadedModelURL = url
            modelStatus = "Local handwriting detector installed."
            return url
        } catch {
            logError("Local model installation failed: \(String(describing: error))")
            throw error
        }
    }

    @available(macOS 15.0, *)
    public func cleanImages() async throws -> [NSImage] {
        guard let model else {
            throw InkRemovalError.modelUnavailable
        }
        guard !pageImages.isEmpty else {
            throw InkRemovalError.pageRenderingFailed
        }

        guard !isProcessing else { throw InkRemovalError.processingInProgress }
        isProcessing = true
        errorMessage = nil
        processingStatus = nil
        // Keep the last successful preview and output if a retry fails.
        defer {
            isProcessing = false
            processingStatus = nil
        }

        do {
            let service = PDFCleaningService(model: model)
            return try await service.clean(images: pageImages) { page, total in
                self.processingStatus = "Removing handwriting from page \(page) of \(total)…"
            }
        } catch {
            logError("Handwriting removal failed: \(String(describing: error))")
            throw error
        }
    }

    @available(macOS 15.0, *)
    public func exportCleaned(images: [NSImage]) throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("handwriting-eraser-\(UUID().uuidString).pdf")
        _ = try PDFCleaningService.writeCleanedDocument(pages: images, to: url)
        cleanedDocumentURL = url
        return url
    }
}
