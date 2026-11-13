import Foundation
import CryptoKit

/// Installs the pinned handwriting-segmentation model. Documents are never
/// sent to the model host: only this public model file is downloaded.
public struct HandwritingDetectorInstaller: Sendable {
    private static let revision = "5b35de75b65da89fddc62e177b002f35b3b1f620"
    public static let sourceURL = URL(string: "https://huggingface.co/guoguo27/handwriting-segmenter/resolve/\(revision)/finetuned_e.onnx")!
    private static let byteCount: Int64 = 176_174_239
    private static let sha256 = "e396488615dff875476934b2d43c94ecc1d1545ad608e67be79bf8ef9d0b0087"

    typealias Fetch = @Sendable (URL, URL) async throws -> Void

    private let directory: URL
    private let source: URL
    private let expectedSize: Int64
    private let expectedHash: String
    private let fetch: Fetch

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HandwritingEraser", isDirectory: true)
    }

    public init(directory: URL = Self.defaultDirectory()) {
        self.init(directory: directory, source: Self.sourceURL, expectedSize: Self.byteCount,
                  expectedHash: Self.sha256, fetch: Self.download)
    }

    // Small injectable artifacts let the integrity and rollback paths be tested offline.
    init(directory: URL, source: URL, expectedSize: Int64, expectedHash: String,
         fetch: @escaping Fetch) {
        self.directory = directory
        self.source = source
        self.expectedSize = expectedSize
        self.expectedHash = expectedHash
        self.fetch = fetch
    }

    public var installedModelURL: URL {
        directory.appendingPathComponent("HandwritingDetector-\(Self.revision).onnx")
    }

    /// Verifies a cached model before it is loaded.
    public func verifyInstalledModel() throws -> URL {
        try verify(installedModelURL)
        return installedModelURL
    }

    /// A previous model is kept until the new download has been fully verified.
    public func install() async throws -> URL {
        let files = FileManager.default
        let staging = directory.appendingPathComponent(".detector-install-\(UUID().uuidString)", isDirectory: true)
        var stage = "Preparing the handwriting detector directory"
        defer { try? files.removeItem(at: staging) }

        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            if files.fileExists(atPath: installedModelURL.path), (try? verify(installedModelURL)) != nil {
                return installedModelURL
            }

            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            let downloaded = staging.appendingPathComponent("detector.onnx")
            stage = "Downloading the handwriting detector"
            try await fetch(source, downloaded)
            try Task.checkCancellation()
            stage = "Verifying the handwriting detector"
            try verify(downloaded)
            try Task.checkCancellation()

            stage = "Saving the handwriting detector"
            let previous = staging.appendingPathComponent("previous.onnx")
            let hadPrevious = files.fileExists(atPath: installedModelURL.path)
            if hadPrevious { try files.moveItem(at: installedModelURL, to: previous) }
            do {
                try files.moveItem(at: downloaded, to: installedModelURL)
            } catch {
                if hadPrevious { try files.moveItem(at: previous, to: installedModelURL) }
                throw error
            }
            return installedModelURL
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let error = error as NSError
            throw ModelInstallationError(stage: stage,
                                         details: "\(error.localizedDescription) [\(error.domain):\(error.code)]")
        }
    }

    private static func download(_ url: URL, to destination: URL) async throws {
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard let response = response as? HTTPURLResponse else { throw Detail.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw Detail.httpStatus(response.statusCode) }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func verify(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size == expectedSize else { throw Detail.wrongSize(expected: expectedSize, actual: size) }

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expectedHash else { throw Detail.checksumMismatch }
    }

    private enum Detail: LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case wrongSize(expected: Int64, actual: Int64)
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "The server did not return an HTTP response."
            case .httpStatus(let status): "The server returned HTTP \(status)."
            case .wrongSize(let expected, let actual): "Expected \(expected) bytes but received \(actual)."
            case .checksumMismatch: "The downloaded file failed its SHA-256 check."
            }
        }
    }
}
