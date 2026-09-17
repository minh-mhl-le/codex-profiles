import XCTest
@testable import CodexProfiles

final class CodexProfilesTests: XCTestCase {
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
