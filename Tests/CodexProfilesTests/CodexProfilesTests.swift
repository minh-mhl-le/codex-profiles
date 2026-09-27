import XCTest
@testable import CodexProfiles

final class CodexProfilesTests: XCTestCase {
    func testCodexBinaryResolverFindsLegacyLocation() throws {
        let app = try makeTemporaryApp()
        let legacyBinary = app.appendingPathComponent("Contents/Resources/codex")
        try makeExecutable(at: legacyBinary)

        XCTAssertEqual(CodexBinaryResolver().resolve(in: [app]), legacyBinary)
    }

    func testCodexBinaryResolverFindsUpdatedCodexLocation() throws {
        let app = try makeTemporaryApp()
        let updatedBinary = app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
        try makeExecutable(at: updatedBinary)

        XCTAssertEqual(CodexBinaryResolver().resolve(in: [app]), updatedBinary)
    }

    private func makeTemporaryApp() throws -> URL {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexProfilesTests-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: app) }
        return app
    }

    private func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func testUsageBucketStoresPercentageAndReset() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let bucket = UsageBucket(id: "codex", name: "codex", usedPercent: 42, resetsAt: reset, windowDurationMinutes: 300)

        XCTAssertEqual(bucket.usedPercent, 42)
        XCTAssertEqual(bucket.resetsAt, reset)
        XCTAssertEqual(bucket.windowDurationMinutes, 300)
    }

    func testProfileIsCodable() throws {
        let profile = Profile(id: UUID(), name: "Personal", email: "person@example.com", planType: "free", createdAt: Date())
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)

        XCTAssertEqual(decoded, profile)
    }
}
