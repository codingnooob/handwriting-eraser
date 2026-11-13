import Foundation
import CryptoKit
import Testing
@testable import HandwritingEraserKit

struct HandwritingDetectorInstallerTests {
    private static let content = Data("detector model".utf8)
    private static var hash: String {
        SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
    }
    private static let fetch: HandwritingDetectorInstaller.Fetch = { _, destination in
        try content.write(to: destination)
    }
    private static func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DetectorTests-\(UUID().uuidString)")
    }
    private static func installer(_ root: URL, fetch: @escaping HandwritingDetectorInstaller.Fetch = fetch) -> HandwritingDetectorInstaller {
        HandwritingDetectorInstaller(directory: root, source: URL(string: "https://example.test/detector.onnx")!,
                                     expectedSize: Int64(content.count), expectedHash: hash, fetch: fetch)
    }

    @Test func installsVerifiedFileAndReusesCache() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = Self.installer(root)
        let url = try await installer.install()
        #expect(url == installer.installedModelURL)
        #expect(try Data(contentsOf: url) == Self.content)
        #expect(try installer.verifyInstalledModel() == url)
        let offline = Self.installer(root, fetch: { _, _ in throw URLError(.notConnectedToInternet) })
        #expect(try await offline.install() == url)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [url.lastPathComponent])
    }

    @Test func rejectsSameSizeWrongHashAndCleansStaging() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = Self.installer(root, fetch: { _, destination in
            try Data(repeating: 65, count: Self.content.count).write(to: destination)
        })
        do {
            _ = try await installer.install()
            Issue.record("A corrupt model must not be installed")
        } catch let error as ModelInstallationError {
            #expect(error.stage == "Verifying the handwriting detector")
            #expect(error.details.contains("SHA-256"))
        }
        #expect(!FileManager.default.fileExists(atPath: installer.installedModelURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func failedDownloadPreservesPreviousInvalidCache() async throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = Self.installer(root, fetch: { _, _ in throw URLError(.notConnectedToInternet) })
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installer.installedModelURL)
        do {
            _ = try await installer.install()
            Issue.record("Expected the download to fail")
        } catch let error as ModelInstallationError {
            #expect(error.stage == "Downloading the handwriting detector")
        }
        #expect(try Data(contentsOf: installer.installedModelURL) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [installer.installedModelURL.lastPathComponent])
    }

    @Test func verifyCachedFileDetectsCorruption() throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = Self.installer(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0, count: Self.content.count).write(to: installer.installedModelURL)
        #expect(throws: (any Error).self) { try installer.verifyInstalledModel() }
    }
}
