import XCTest
@testable import CodexProfiles

final class RathHandoffTests: XCTestCase {
    private let profileID = UUID()
    private let jobID = UUID()

    private func request(_ operation: String = "usage", id: UUID? = nil) throws -> RathHandoffRequest {
        try RathHandoffRequest(arguments: ["--rath-handoff", operation, "--profile",
                                           (id ?? profileID).uuidString, "--job", jobID.uuidString])
    }

    private func fixture(enabled: Bool = true, allowed: Bool = true) -> (RathHandoffService, FakeStore, FakeClient) {
        let profile = Profile(id: profileID, name: "Fixture", email: "fixture@example.invalid", planType: nil,
                              accountID: "fixture-account", createdAt: Date())
        let store = FakeStore(profile: profile)
        let client = FakeClient(snapshot: UsageSnapshot(email: profile.email, planType: nil, accountID: profile.accountID, ordinaryUsageAllowed: true,
            buckets: [.init(id: "fixture", name: "5h", usedPercent: 12, resetsAt: Date().addingTimeInterval(300),
                            windowDurationMinutes: 300)], lastRefreshed: Date()))
        return (.init(policy: .init(enabled: enabled, profileIDs: allowed ? [profileID] : []),
                      store: store, client: client), store, client)
    }

    func testDisabledAndDisallowedNeverReadStoreOrClient() async throws {
        for flags in [(false, true), (true, false)] {
            let (service, store, client) = fixture(enabled: flags.0, allowed: flags.1)
            do {
                _ = try await service.perform(request())
                XCTFail("Expected policy rejection")
            } catch let error as RathHandoffError {
                XCTAssertEqual(error, flags.0 ? .profileNotAllowed : .disabled)
            }
            XCTAssertEqual(store.readCount, 0)
            XCTAssertEqual(store.loadCount, 0)
            XCTAssertEqual(client.calls, 0)
        }
    }

    func testIdentityMismatchDoesNotSaveOrReleaseAuth() async throws {
        let (service, store, client) = fixture()
        client.snapshot.accountID = "different-fixture-account"
        do {
            _ = try await service.perform(request("auth"))
            XCTFail("Expected identity rejection")
        } catch let error as RathHandoffError {
            XCTAssertEqual(error, .identityMismatch)
        }
        XCTAssertEqual(store.saveCount, 0)
    }

    func testUsageReturnsStrictSafeOutputAndSavesRotation() async throws {
        let (service, store, _) = fixture()
        let response = try await service.perform(request())
        let bytes = try response.machineData()
        XCTAssertEqual(bytes.last, 0x0a)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "profileId", "jobId", "observedAt", "windows", "ordinaryUsageAllowed"])
        XCTAssertEqual(object["profileId"] as? String, profileID.uuidString)
        XCTAssertEqual(object["jobId"] as? String, jobID.uuidString)
        XCTAssertEqual((object["windows"] as? [[String: Any]])?.first?["usedPercent"] as? Double, 12)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testAuthOnlyAddsDedicatedPayloadField() async throws {
        let (service, store, _) = fixture()
        let response = try await service.perform(request("auth"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.machineData()) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "profileId", "jobId", "observedAt", "windows", "ordinaryUsageAllowed", "authPayloadBase64"])
        // Fixtures are arbitrary bytes, never a credential record or a JWT.
        XCTAssertTrue(response.authPayloadBase64.map { Data(base64Encoded: $0) == FakeClient.rotatedFixture } ?? false)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testUpstreamErrorsAreRedacted() async throws {
        let (service, _, client) = fixture()
        client.fails = true
        do {
            _ = try await service.perform(request())
            XCTFail("Expected sanitized rejection")
        } catch let error as RathHandoffError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    func testStaleUsageFailsClosed() async throws {
        let (service, store, client) = fixture()
        client.snapshot.lastRefreshed = Date().addingTimeInterval(-120)
        do {
            _ = try await service.perform(request("auth"))
            XCTFail("Expected stale response rejection")
        } catch let error as RathHandoffError {
            XCTAssertEqual(error, .unavailable)
        }
        // Refresh rotation is preserved after identity verification even when
        // the usage response is unsuitable for a handoff.
        XCTAssertEqual(store.saveCount, 1)
    }

    func testParserRejectsAdditionalOrImplicitArguments() {
        XCTAssertThrowsError(try RathHandoffRequest(arguments: ["--rath-handoff", "auth"]))
        XCTAssertThrowsError(try RathHandoffRequest(arguments: ["--rath-handoff", "list", "--profile", profileID.uuidString,
                                                              "--job", jobID.uuidString]))
    }

    func testPoolOnlyChecksSelectedIDsAndDoesNotExportAuth() async throws {
        let (service, store, client) = fixture()
        let response = try await service.pool(jobID: jobID)
        XCTAssertEqual(response.profiles.count, 1)
        XCTAssertEqual(response.unavailableProfileIds.count, 0)
        XCTAssertEqual(response.profiles.first?.profileId, profileID)
        XCTAssertTrue(response.profiles.allSatisfy { $0.authPayloadBase64 == nil })
        XCTAssertEqual(store.readCount, 1)
        XCTAssertEqual(client.calls, 1)
    }

    func testPoolMarksUnavailableProfilesWithoutRawErrors() async throws {
        let (service, _, client) = fixture()
        client.fails = true
        let response = try await service.pool(jobID: jobID)
        XCTAssertEqual(response.profiles.count, 0)
        XCTAssertEqual(response.unavailableProfileIds, [profileID])
    }

    func testPolicyDefaultsDisabledAndRejectsMalformedPool() {
        let store = FakePolicyStore()
        XCTAssertFalse((try? RathHandoffPolicy.load(store: store).enabled) ?? true)
        store.data = Data(#"{"schemaVersion":1,"enabled":true,"profileIDs":["invalid-id"]}"#.utf8)
        XCTAssertThrowsError(try RathHandoffPolicy.load(store: store))
    }

    func testMutableUserDefaultsCannotEnableHandoffWithoutStoredConsent() throws {
        let name = "CodexProfilesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "rathHandoffEnabled")
        defaults.set([profileID.uuidString], forKey: "rathHandoffProfileIDs")

        let disabled = try RathHandoffPolicy.load(store: FakePolicyStore())
        XCTAssertFalse(disabled.enabled)

        let store = FakePolicyStore()
        try RathHandoffPolicy(enabled: true, profileIDs: [profileID]).save(to: store)
        let stored = try RathHandoffPolicy.load(store: store)
        XCTAssertTrue(stored.enabled)
        XCTAssertEqual(stored.profileIDs, Set([profileID]))
    }

    func testGateParsesRootPermissionAndNestedDiagnostics() throws {
        let json = Data(#"{"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{"codex":{"rateLimitReachedType":"none","spendControlReached":true,"individualLimit":{"limit":"10","used":"10","remainingPercent":0,"resetsAt":1800000000}}}}"#.utf8)
        let gate = RathUsageGate.parse(try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any]))
        XCTAssertEqual(gate.ordinaryUsageAllowed, true)
        XCTAssertEqual(gate.spendControlReached, true)
        XCTAssertEqual(gate.individualLimit?.remainingPercent, 0)
        XCTAssertEqual(gate.rateLimitReachedType, "none")
    }

    func testGateParsesNestedPermissionAndConflictsFailClosed() {
        XCTAssertEqual(RathUsageGate.parse(["rateLimits": ["ordinaryUsageAllowed": true]]).ordinaryUsageAllowed, true)
        XCTAssertEqual(RathUsageGate.parse(["ordinaryUsageAllowed": true,
                                           "rateLimits": ["ordinaryUsageAllowed": false]]).ordinaryUsageAllowed, nil)
        XCTAssertEqual(RathUsageGate.parse(["rateLimits": ["spendControlReached": false]]).ordinaryUsageAllowed, nil)
        XCTAssertEqual(RathUsageGate.parse(["ordinaryUsageAllowed": 1]).ordinaryUsageAllowed, nil)
    }

    func testConflictingRateLimitTypesFailClosedForAuthGate() {
        let gate = RathUsageGate.parse([
            "ordinaryUsageAllowed": true,
            "rateLimitReachedType": "none",
            "rateLimits": ["rateLimitReachedType": "usage_limit"],
        ])
        XCTAssertEqual(gate.ordinaryUsageAllowed, nil as Bool?)
        XCTAssertEqual(gate.rateLimitReachedType, "none")
    }

    func testUnknownAndDeniedOrdinaryGateNeverExportAuth() async throws {
        for permission in [nil, false] as [Bool?] {
            let (service, _, client) = fixture()
            client.snapshot.ordinaryUsageAllowed = permission
            do {
                _ = try await service.perform(request("auth"))
                XCTFail("Expected explicit ordinary permission requirement")
            } catch let error as RathHandoffError {
                XCTAssertEqual(error, .unavailable)
            }
        }
    }

    func testExplicitReachedLimitNeverExportsAuth() async throws {
        let (service, _, client) = fixture()
        client.snapshot.rateLimitReachedType = "usage_limit"
        do {
            _ = try await service.perform(request("auth"))
            XCTFail("Expected explicit usage-limit rejection")
        } catch let error as RathHandoffError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    func testSpendControlDiagnosticsDoNotOverrideOrdinaryGate() async throws {
        let (service, _, client) = fixture()
        client.snapshot.spendControlReached = true
        client.snapshot.individualLimit = .init(limit: "10", used: "10", remainingPercent: 0, resetsAt: nil)
        let response = try await service.perform(request("auth"))
        XCTAssertTrue(response.authPayloadBase64 != nil)
        XCTAssertEqual(response.ordinaryUsageAllowed, true)
    }
}

private final class FakeStore: RathHandoffProfileStore {
    let profile: Profile
    var loadCount = 0
    var readCount = 0
    var saveCount = 0
    init(profile: Profile) { self.profile = profile }
    func loadProfiles() throws -> [Profile] { loadCount += 1; return [profile] }
    func readAuth(for profileID: UUID) throws -> Data { readCount += 1; return Data([1, 2, 3]) }
    func saveAuth(_ data: Data, for profileID: UUID) throws { saveCount += 1 }
}

private final class FakePolicyStore: RathHandoffPolicyStore {
    var data: Data?
    func readHandoffPolicy() throws -> Data? { data }
    func saveHandoffPolicy(_ data: Data) throws { self.data = data }
}

private final class FakeClient: RathHandoffAccountClient {
    static let rotatedFixture = Data([4, 5, 6])
    var snapshot: UsageSnapshot
    var calls = 0
    var fails = false
    init(snapshot: UsageSnapshot) { self.snapshot = snapshot }
    func refreshForHandoff(auth: Data) async throws -> (UsageSnapshot, Data?) {
        calls += 1
        if fails { throw ProfileError.appServerError("fixture upstream error") }
        return (snapshot, Self.rotatedFixture)
    }
}
