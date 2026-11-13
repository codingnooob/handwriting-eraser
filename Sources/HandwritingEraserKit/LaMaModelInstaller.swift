import Foundation
import CoreML
import CryptoKit

/// Downloads the complete published LaMa package, compiles it, and caches the
/// resulting Core ML model locally. The source revision and hashes are pinned so
/// a partial or changed download cannot be mistaken for a working model.
@available(macOS 15.0, *)
public struct LaMaModelInstaller: Sendable {
    private static let revision = "5ed76e3799ab4cad31381750d29880c267477e18"
    public static let sourceURL = URL(string: "https://huggingface.co/mlboydaisuke/LaMa-CoreML/resolve/\(revision)/LaMa.mlpackage")!

    struct Artifact: Sendable {
        let path: String
        let byteCount: Int64
        let sha256: String
    }

    typealias Fetch = @Sendable (URL, URL) async throws -> Void
    typealias Compile = @Sendable (URL) async throws -> URL
    typealias Validate = @Sendable (URL) throws -> Void

    private static let artifacts: [Artifact] = [
        Artifact(path: "Manifest.json", byteCount: 617,
                 sha256: "c814fff3cedf827c044094545ef80b0280b6cb8dd0e5c0bcf69fd31921191e58"),
        Artifact(path: "Data/com.apple.CoreML/model.mlmodel", byteCount: 1_101_809,
                 sha256: "06a100ef99e0fd16326a3a8c4a687d13f7b26f544ea906a75338932d8554f953"),
        Artifact(path: "Data/com.apple.CoreML/weights/weight.bin", byteCount: 215_544_960,
                 sha256: "d0541f6044a94cd4982bfdac074fc1ccfe11d8f1f590c299d6b5071b501fc184")
    ]

    private let directory: URL
    private let source: URL
    private let artifacts: [Artifact]
    private let fetch: Fetch
    private let compile: Compile
    private let validate: Validate

    /// The compiled model is stored in Application Support, not Documents.
    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HandwritingEraser", isDirectory: true)
    }

    public init(directory: URL = LaMaModelInstaller.defaultDirectory()) {
        self.init(
            directory: directory,
            source: Self.sourceURL,
            artifacts: Self.artifacts,
            fetch: Self.download,
            compile: { try await MLModel.compileModel(at: $0) },
            validate: Self.validateModel
        )
    }

    // Injectable operations make the package layout and error handling testable
    // without a network connection or a 206 MiB model.
    init(directory: URL, source: URL, artifacts: [Artifact],
         fetch: @escaping Fetch, compile: @escaping Compile,
         validate: @escaping Validate) {
        self.directory = directory
        self.source = source
        self.artifacts = artifacts
        self.fetch = fetch
        self.compile = compile
        self.validate = validate
    }

    public var installedModelURL: URL {
        directory.appendingPathComponent("LaMa-\(Self.revision).mlmodelc", isDirectory: true)
    }

    /// Returns a verified existing model, or downloads and compiles a new one.
    /// Downloads are staged separately and never replace a cached model until
    /// compilation and loading succeed.
    public func install() async throws -> URL {
        let fileManager = FileManager.default
        let installID = UUID().uuidString
        let staging = directory.appendingPathComponent(".install-\(installID)", isDirectory: true)
        var stage = "Preparing the model directory"
        defer { try? fileManager.removeItem(at: staging) }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: installedModelURL.path) {
                do {
                    try validate(installedModelURL)
                    return installedModelURL
                } catch {
                    // Keep the old artifact until a replacement is verified.
                }
            }

            // Core ML derives its temporary output name from the source name;
            // a unique name prevents simultaneous compilations from colliding.
            let package = staging.appendingPathComponent("LaMa-\(installID).mlpackage", isDirectory: true)
            for artifact in artifacts {
                try Task.checkCancellation()
                stage = "Downloading \(artifact.path)"
                let destination = artifact.path.split(separator: "/").reduce(package) {
                    $0.appendingPathComponent(String($1))
                }
                let remote = artifact.path.split(separator: "/").reduce(source) {
                    $0.appendingPathComponent(String($1))
                }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await fetch(remote, destination)
                stage = "Verifying \(artifact.path)"
                try Self.verify(destination, artifact: artifact)
            }

            try Task.checkCancellation()
            stage = "Compiling the Core ML package"
            let compiled = try await compile(package)
            defer { try? fileManager.removeItem(at: compiled) }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: compiled.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw Detail.invalidCompiledArtifact
            }

            stage = "Staging the compiled Core ML model"
            let stagedModel = staging.appendingPathComponent("LaMa.mlmodelc", isDirectory: true)
            try fileManager.moveItem(at: compiled, to: stagedModel)
            stage = "Loading the compiled Core ML model"
            try validate(stagedModel)

            try Task.checkCancellation()
            stage = "Saving the compiled Core ML model"
            let backup = staging.appendingPathComponent("Previous.mlmodelc", isDirectory: true)
            let hadPreviousModel = fileManager.fileExists(atPath: installedModelURL.path)
            if hadPreviousModel {
                try fileManager.moveItem(at: installedModelURL, to: backup)
            }
            do {
                try fileManager.moveItem(at: stagedModel, to: installedModelURL)
            } catch {
                if hadPreviousModel {
                    try fileManager.moveItem(at: backup, to: installedModelURL)
                }
                throw error
            }
            return installedModelURL
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let nsError = error as NSError
            var details = "\(nsError.localizedDescription) [\(nsError.domain):\(nsError.code)]"
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                details += "; caused by \(underlying.localizedDescription) [\(underlying.domain):\(underlying.code)]"
            }
            throw ModelInstallationError(stage: stage, details: details)
        }
    }

    private static func download(_ url: URL, to destination: URL) async throws {
        // URLSession streams the large weights file to disk instead of holding
        // the whole download in memory.
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse else { throw Detail.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw Detail.httpStatus(http.statusCode) }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
    }

    private static func verify(_ url: URL, artifact: Artifact) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size == artifact.byteCount else {
            throw Detail.wrongSize(expected: artifact.byteCount, actual: size)
        }

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == artifact.sha256 else { throw Detail.checksumMismatch }
    }

    private static func validateModel(_ url: URL) throws {
        let model = try MLModel(contentsOf: url)
        let inputs = model.modelDescription.inputDescriptionsByName
        let outputs = model.modelDescription.outputDescriptionsByName
        guard inputs["image"]?.type == .image,
              inputs["mask"]?.type == .image,
              outputs["output"]?.type == .image else {
            throw Detail.unexpectedInterface
        }
    }

    private enum Detail: LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case wrongSize(expected: Int64, actual: Int64)
        case checksumMismatch
        case invalidCompiledArtifact
        case unexpectedInterface

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "The server did not return an HTTP response."
            case .httpStatus(let status): "The server returned HTTP \(status)."
            case .wrongSize(let expected, let actual): "Expected \(expected) bytes but received \(actual)."
            case .checksumMismatch: "The downloaded file failed its SHA-256 check."
            case .invalidCompiledArtifact: "Core ML did not return a compiled model directory."
            case .unexpectedInterface: "The compiled model has an unexpected image/mask interface."
            }
        }
    }
}

public struct ModelInstallationError: LocalizedError {
    public let stage: String
    public let details: String

    public var errorDescription: String? { "\(stage) failed: \(details)" }
}
