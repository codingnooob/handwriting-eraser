import SwiftUI
import AppKit
import PDFKit

@available(macOS 15.0, *)
struct ContentView: View {
    @StateObject private var store = EraserStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Handwriting Eraser")
                    .font(.title)
                Text("Remove handwriting from PDF pages locally on this Mac.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button(store.documentURL == nil ? "Import PDF" : "Import Another PDF") {
                        store.isImporterPresented = true
                    }
                    .accessibilityLabel(store.documentURL == nil ? "Import PDF" : "Import Another PDF")
                    .disabled(store.isProcessing)

                    if store.documentURL != nil {
                        Button {
                            Task { await runClean() }
                        } label: {
                            Label("Remove Handwriting", systemImage: "eraser")
                        }
                        .accessibilityLabel("Remove Handwriting")
                        .disabled(store.isProcessing || store.isDownloadingModel || store.isLoadingModel || store.model == nil || store.pageImages.isEmpty)
                    }
                }

                modelControls

                if store.isProcessing {
                    ProgressView(store.processingStatus ?? "Preparing pages…")
                }
                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if let cleanedURL = store.cleanedDocumentURL {
                    Text("Cleaned PDF saved to: \(cleanedURL.path)")
                        .font(.footnote)
                        .textSelection(.enabled)
                }

                if store.documentURL != nil {
                    Text("Review the result: detection can miss marks or erase printed content, especially where ink overlaps it. Exported pages are rasterized.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if !store.cleanedPages.isEmpty {
                        Picker("Preview", selection: $store.showCleaned) {
                            Text("Original").tag(false)
                            Text("Cleaned").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 260)
                    }

                    let pages = store.showCleaned && !store.cleanedPages.isEmpty ? store.cleanedPages : store.pageImages
                    Text("\(pages.count) page\(pages.count == 1 ? "" : "s")")
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 240), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { index, image in
                            VStack(alignment: .leading, spacing: 4) {
                                PageThumbnailView(image: image)
                                Text("Page \(index + 1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .fileImporter(isPresented: $store.isImporterPresented, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    store.loadDocument(at: url)
                    store.showCleaned = true
                }
            case .failure(let error):
                let nsError = error as NSError
                if nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError {
                    store.reportImportError(error)
                }
            }
        }
    }

    private var modelControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.isDownloadingModel {
                ProgressView("Downloading the local handwriting detector (about 176 MB)…")
            } else if store.isLoadingModel {
                ProgressView("Loading the local handwriting detector…")
            } else if store.model == nil {
                Button("Download Local AI Model") {
                    Task { await downloadModel() }
                }
                .accessibilityLabel("Download Local AI Model")
                .disabled(store.isProcessing)
            }
            if let status = store.modelStatus {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func downloadModel() async {
        do {
            _ = try await store.downloadModel()
        } catch {
            store.errorMessage = "Local model download failed: \(error.localizedDescription)"
        }
    }

    private func runClean() async {
        do {
            let cleanedImages = try await store.cleanImages()
            _ = try store.exportCleaned(images: cleanedImages)
            store.cleanedPages = cleanedImages
            store.showCleaned = true
        } catch {
            store.reportProcessingError(error)
        }
    }
}

struct PageThumbnailView: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: 220, height: 300)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
