import Foundation
import CryptoKit
import Testing
@testable import HandwritingEraserKit

struct LaMaModelInstallerTests {
    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HandwritingEraserTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static let files: [String: Data] = [
        "Manifest.json": Data("manifest".utf8),
        "model.mlmodel": Data("source model".utf8),
        "weight.bin": Data("weights".utf8)
    ]

    private static var artifacts: [LaMaModelInstaller.Artifact] {
        [
            "Manifest.json",
            "Data/com.apple.CoreML/model.mlmodel",
            "Data/com.apple.CoreML/weights/weight.bin"
        ].map { path in
            let data = files[URL(fileURLWithPath: path).lastPathComponent]!
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return LaMaModelInstaller.Artifact(path: path, byteCount: Int64(data.count), sha256: digest)
        }
    }

    private static let download: LaMaModelInstaller.Fetch = { remote, destination in
        guard let data = files[remote.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
        try data.write(to: destination)
    }

    private static func compiler(in root: URL) -> LaMaModelInstaller.Compile {
        { package in
            for path in ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"] {
                let file = path.split(separator: "/").reduce(package) { $0.appendingPathComponent(String($1)) }
                guard try Data(contentsOf: file) == files[file.lastPathComponent] else {
                    throw URLError(.cannotDecodeContentData)
                }
            }
            let compiled = root.appendingPathComponent("compiler-output.mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
            try Data("compiled".utf8).write(to: compiled.appendingPathComponent("coremldata.bin"))
            return compiled
        }
    }

    private static let validate: LaMaModelInstaller.Validate = { directory in
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
              try Data(contentsOf: directory.appendingPathComponent("coremldata.bin")) == Data("compiled".utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
    }

    private static func installer(in root: URL,
                                  fetch: @escaping LaMaModelInstaller.Fetch = download,
                                  compile: LaMaModelInstaller.Compile? = nil,
                                  validate: @escaping LaMaModelInstaller.Validate = validate) -> LaMaModelInstaller {
        LaMaModelInstaller(directory: root, source: URL(string: "https://example.test/LaMa.mlpackage")!,
                           artifacts: artifacts, fetch: fetch, compile: compile ?? compiler(in: root), validate: validate)
    }

    @Test func stagesCompletePackageAndKeepsCompiledDirectory() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = Self.installer(in: root)
        let installed = try await installer.install()
        #expect(installed == installer.installedModelURL)
        #expect(installed.pathExtension == "mlmodelc")
        try Self.validate(installed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [installed.lastPathComponent])
    }

    @Test func reusesValidCachedModelWithoutDownloading() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Self.installer(in: root)
        let installed = try await first.install()
        let cached = Self.installer(in: root, fetch: { _, _ in throw URLError(.notConnectedToInternet) },
                                    compile: { _ in throw URLError(.cannotDecodeContentData) })
        #expect(try await cached.install() == installed)
    }

    @Test func failedWeightDownloadReportsStageAndCleansStaging() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = Self.installer(in: root, fetch: { remote, destination in
            if remote.lastPathComponent == "weight.bin" { throw URLError(.notConnectedToInternet) }
            try await Self.download(remote, destination)
        })
        do {
            _ = try await installer.install()
            Issue.record("Expected the weights download to fail")
        } catch let error as ModelInstallationError {
            #expect(error.stage.contains("weights/weight.bin"))
        }
        #expect(!FileManager.default.fileExists(atPath: installer.installedModelURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func rejectsCorruptDownloadBeforeCompilation() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = Self.installer(in: root, fetch: { remote, destination in
            if remote.lastPathComponent == "Manifest.json" {
                try Data("MANIFEST".utf8).write(to: destination) // same length, wrong hash
            } else {
                try await Self.download(remote, destination)
            }
        }, compile: { _ in
            Issue.record("A corrupt package must not be compiled")
            throw URLError(.cannotDecodeContentData)
        })
        do {
            _ = try await installer.install()
            Issue.record("Expected checksum verification to fail")
        } catch let error as ModelInstallationError {
            #expect(error.stage == "Verifying Manifest.json")
            #expect(error.details.contains("SHA-256"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func failedValidationNeverPublishesTheCompiledModel() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = Self.installer(in: root, validate: { _ in throw URLError(.cannotDecodeContentData) })
        do {
            _ = try await installer.install()
            Issue.record("Expected model validation to fail")
        } catch let error as ModelInstallationError {
            #expect(error.stage == "Loading the compiled Core ML model")
        }
        #expect(!FileManager.default.fileExists(atPath: installer.installedModelURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func failedCompilationDoesNotDeletePreviousModel() async throws {
        let root = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = Self.installer(in: root, compile: { _ in throw URLError(.cannotDecodeContentData) },
                                       validate: { _ in throw URLError(.cannotDecodeContentData) })
        let previous = installer.installedModelURL
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        let marker = previous.appendingPathComponent("old-model")
        try Data("old".utf8).write(to: marker)
        do {
            _ = try await installer.install()
            Issue.record("Expected compilation to fail")
        } catch let error as ModelInstallationError {
            #expect(error.stage == "Compiling the Core ML package")
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

}
