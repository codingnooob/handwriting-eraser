import SwiftUI
import AppKit
import PDFKit
import CoreGraphics
import Combine

@available(macOS 15.0, *)
struct ContentView: View {
    @StateObject private var store = EraserStore()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let documentURL = store.documentURL {
                        // A document is loaded: show its pages and clean them.
                        if store.pageImages.isEmpty {
                            Text("No pages could be rendered from the document.")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(0..<store.pageImages.count, id: \.self) { index in
                                    PageThumbnailView(image: store.pageImages[index])
                                }
                            }
                        }

                        if store.isProcessing {
                            ProgressView("Removing handwriting…")
                        }

                        Button {
                            Task { await runClean() }
                        } label: {
                            Label("Remove Handwriting", systemImage: "eraser")
                        }
                        .disabled(store.isProcessing)

                        if let cleanedURL = store.cleanedDocumentURL {
                            Text("Cleaned PDF saved to: \(cleanedURL.path)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        welcomeContent
                    }

                    if let errorMessage = store.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
        }
        .fileImporter(
            isPresented: Binding<Bool>(
                get: { store.isImporterPresented },
                set: { store.isImporterPresented = $0 }
            ),
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            store.loadDocument(at: url)
        }
    }

    private var welcomeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Handwriting Eraser")
                .font(.title)
            Text("Import a PDF to remove handwritten notes with a fully local AI model.")
                .foregroundStyle(.secondary)
        }
    }

    private func runClean() async {
        do {
            let cleanedImages = try await store.cleanImages()
            let url = try store.exportCleaned(images: cleanedImages)
            store.cleanedDocumentURL = url
        } catch {
            store.errorMessage = "Handwriting removal failed: \(error.localizedDescription)"
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
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary))
    }
}
