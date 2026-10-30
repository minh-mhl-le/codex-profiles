import Darwin
import Foundation
import CoreFoundation

/// Optional upstream capabilities remain unknown when absent or conflicting.
/// Diagnostic spend controls must never override the explicit ordinary-usage gate.
struct RathUsageGate {
    struct IndividualLimit: Codable, Equatable {
        let limit: String?
        let used: String?
        let remainingPercent: Double?
        let resetsAt: Double?
    }
    let ordinaryUsageAllowed: Bool?
    let rateLimitReachedType: String?
    let spendControlReached: Bool?
    let individualLimit: IndividualLimit?

    static func parse(_ root: [String: Any]) -> Self {
        let legacy = root["rateLimits"] as? [String: Any]
        let codex = (root["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any]
        let locations = [root, codex, legacy].compactMap { $0 }
        func boolean(_ value: Any?) -> Bool? {
            guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return value.boolValue
        }
        let rawPermissions = locations.compactMap { $0["ordinaryUsageAllowed"] }
        let permissions = rawPermissions.compactMap(boolean)
        let rawReached = locations.compactMap { $0["rateLimitReachedType"] }
        let reachedValues = rawReached.compactMap { $0 as? String }
        let reached = reachedValues.first
        let safeReached = reached.flatMap { value in
            value.count <= 64 && value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil ? value : nil
        }
        let reachedConsistent = rawReached.isEmpty || (
            reachedValues.count == rawReached.count && Set(reachedValues).count == 1 && safeReached != nil
        )
        let permission = permissions.count == rawPermissions.count && Set(permissions).count == 1 && reachedConsistent
            ? permissions.first : nil
        let spend = locations.compactMap { boolean($0["spendControlReached"]) }.first
        let individual = locations.compactMap { $0["individualLimit"] as? [String: Any] }.first
        func amount(_ key: String) -> String? {
            guard let value = individual?[key] as? String, value.count <= 64,
                  value.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil else { return nil }
            return value
        }
        func number(_ key: String) -> Double? {
            guard let value = individual?[key] as? Double, value.isFinite else { return nil }
            return value
        }
        return Self(ordinaryUsageAllowed: permission, rateLimitReachedType: safeReached,
                    spendControlReached: spend,
                    individualLimit: individual.map { _ in .init(limit: amount("limit"), used: amount("used"),
                        remainingPercent: number("remainingPercent"), resetsAt: number("resetsAt")) })
    }
}

protocol RathHandoffPolicyStore {
    func readHandoffPolicy() throws -> Data?
    func saveHandoffPolicy(_ data: Data) throws
}

/// Consent and the profile allowlist live in the app's Keychain, not mutable defaults.
struct RathHandoffPolicy {
    private struct StoredPolicy: Codable {
        let schemaVersion: Int
        let enabled: Bool
        let profileIDs: [String]
    }

    static let maximumProfiles = 32
    let enabled: Bool
    let profileIDs: Set<UUID>

    static func load(store: any RathHandoffPolicyStore) throws -> Self {
        guard let data = try store.readHandoffPolicy() else {
            return Self(enabled: false, profileIDs: [])
        }
        guard data.count <= 4096 else { throw RathHandoffError.unavailable }
        let stored = try JSONDecoder().decode(StoredPolicy.self, from: data)
        guard stored.schemaVersion == 1, stored.profileIDs.count <= maximumProfiles else {
            throw RathHandoffError.unavailable
        }
        let values = stored.profileIDs
        let ids = values.compactMap(UUID.init(uuidString:))
        guard ids.count == values.count, Set(ids).count == ids.count else {
            throw RathHandoffError.unavailable
        }
        return Self(enabled: stored.enabled, profileIDs: Set(ids))
    }

    func save(to store: any RathHandoffPolicyStore) throws {
        guard profileIDs.count <= Self.maximumProfiles else { throw RathHandoffError.unavailable }
        let stored = StoredPolicy(schemaVersion: 1, enabled: enabled,
                                  profileIDs: profileIDs.map(\.uuidString).sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(stored)
        guard data.count <= 4096 else { throw RathHandoffError.unavailable }
        try store.saveHandoffPolicy(data)
    }
}

enum RathHandoffError: String, Error {
    case invalidRequest = "invalid_request"
    case pipeRequired = "pipe_required"
    case disabled
    case profileNotAllowed = "profile_not_allowed"
    case identityMismatch = "identity_mismatch"
    case unavailable
}

struct RathHandoffRequest {
    enum Operation: String { case pool, usage, auth }
    let operation: Operation
    let profileID: UUID?
    let jobID: UUID

    init(arguments: [String]) throws {
        if arguments.count == 4, arguments[0] == "--rath-handoff", arguments[1] == "pool",
           arguments[2] == "--job", let jobID = UUID(uuidString: arguments[3]) {
            self.operation = .pool
            self.profileID = nil
            self.jobID = jobID
            return
        }
        guard arguments.count == 6,
              arguments[0] == "--rath-handoff",
              let operation = Operation(rawValue: arguments[1]), operation != .pool,
              arguments[2] == "--profile", let profileID = UUID(uuidString: arguments[3]),
              arguments[4] == "--job", let jobID = UUID(uuidString: arguments[5]) else {
            throw RathHandoffError.invalidRequest
        }
        self.operation = operation
        self.profileID = profileID
        self.jobID = jobID
    }
}

protocol RathHandoffProfileStore {
    func loadProfiles() throws -> [Profile]
    func readAuth(for profileID: UUID) throws -> Data
    func saveAuth(_ data: Data, for profileID: UUID) throws
}
extension ProfileStore: RathHandoffProfileStore {}
extension KeychainStore: RathHandoffPolicyStore {}

protocol RathHandoffAccountClient {
    func refreshForHandoff(auth: Data) async throws -> (UsageSnapshot, Data?)
}
extension AppServerClient: RathHandoffAccountClient {
    func refreshForHandoff(auth: Data) async throws -> (UsageSnapshot, Data?) {
        try await readAccountAndUsage(auth: auth, refreshToken: true)
    }
}

/// Deliberately excludes names, email addresses, upstream account IDs, and arbitrary errors.
struct RathHandoffResponse: Encodable {
    struct Window: Encodable {
        let usedPercent: Double?
        let resetsAt: Double?
        let windowDurationMinutes: Int?
    }
    let schemaVersion = 1
    let profileId: UUID
    let jobId: UUID
    let observedAt: Double
    let windows: [Window]
    let ordinaryUsageAllowed: Bool?
    let rateLimitReachedType: String?
    let spendControlReached: Bool?
    let individualLimit: RathUsageGate.IndividualLimit?
    let authPayloadBase64: String?

    func machineData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var bytes = try encoder.encode(self)
        bytes.append(0x0a)
        return bytes
    }
}

struct RathHandoffService {
    let policy: RathHandoffPolicy
    let store: any RathHandoffProfileStore
    let client: any RathHandoffAccountClient

    struct PoolResponse: Encodable {
        let schemaVersion = 1
        let jobId: UUID
        let profiles: [RathHandoffResponse]
        let unavailableProfileIds: [UUID]
    }

    func pool(jobID: UUID) async throws -> PoolResponse {
        guard policy.enabled else { throw RathHandoffError.disabled }
        // Bound Keychain/network work even if local preferences are corrupted.
        guard policy.profileIDs.count <= 32 else { throw RathHandoffError.unavailable }
        var profiles: [RathHandoffResponse] = []
        var unavailable: [UUID] = []
        for id in policy.profileIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let request = try RathHandoffRequest(arguments: ["--rath-handoff", "usage", "--profile", id.uuidString,
                                                           "--job", jobID.uuidString])
            do { profiles.append(try await perform(request)) }
            catch { unavailable.append(id) }
        }
        return PoolResponse(jobId: jobID, profiles: profiles, unavailableProfileIds: unavailable)
    }

    func perform(_ request: RathHandoffRequest) async throws -> RathHandoffResponse {
        guard policy.enabled else { throw RathHandoffError.disabled }
        guard request.operation != .pool, let requestedID = request.profileID else { throw RathHandoffError.invalidRequest }
        guard policy.profileIDs.contains(requestedID) else { throw RathHandoffError.profileNotAllowed }
        do {
            guard let profile = try store.loadProfiles().first(where: { $0.id == requestedID }) else {
                throw RathHandoffError.profileNotAllowed
            }
            let auth = try store.readAuth(for: profile.id)
            guard !auth.isEmpty, auth.count <= 262_144 else { throw RathHandoffError.unavailable }
            let (snapshot, rotatedAuth) = try await client.refreshForHandoff(auth: auth)
            // Email alone cannot distinguish workspaces under the same login. Require
            // a previously saved upstream account ID, and compare email when available.
            guard let expected = profile.accountID, !expected.isEmpty,
                  let actual = snapshot.accountID, expected == actual,
                  profile.email == nil || profile.email?.lowercased() == snapshot.email?.lowercased() else {
                throw RathHandoffError.identityMismatch
            }
            let freshAuth = rotatedAuth ?? auth
            guard !freshAuth.isEmpty, freshAuth.count <= 262_144 else { throw RathHandoffError.unavailable }
            if let rotatedAuth, rotatedAuth != auth { try store.saveAuth(rotatedAuth, for: profile.id) }
            guard snapshot.error == nil, !snapshot.isLoading, !snapshot.buckets.isEmpty, snapshot.buckets.count <= 32,
                  let observedAt = snapshot.lastRefreshed,
                  abs(observedAt.timeIntervalSinceNow) < 60,
                  snapshot.buckets.allSatisfy({ bucket in
                      (bucket.usedPercent.map { $0.isFinite && (0...100).contains($0) } ?? true)
                        && (bucket.resetsAt.map { $0.timeIntervalSince1970.isFinite } ?? true)
                        && (bucket.windowDurationMinutes.map { $0 > 0 } ?? true)
                  }) else { throw RathHandoffError.unavailable }
            // Unknown or conflicting support for the explicit gate must never authorize auth.
            let reached = snapshot.rateLimitReachedType?.lowercased()
            let explicitLimitReached = reached.map { !$0.isEmpty && $0 != "none" } ?? false
            guard request.operation != .auth || (snapshot.ordinaryUsageAllowed == true && !explicitLimitReached) else {
                throw RathHandoffError.unavailable
            }
            return RathHandoffResponse(
                profileId: profile.id, jobId: request.jobID,
                observedAt: observedAt.timeIntervalSince1970,
                windows: snapshot.buckets.map {
                    .init(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt?.timeIntervalSince1970,
                          windowDurationMinutes: $0.windowDurationMinutes)
                },
                ordinaryUsageAllowed: snapshot.ordinaryUsageAllowed,
                rateLimitReachedType: snapshot.rateLimitReachedType,
                spendControlReached: snapshot.spendControlReached,
                individualLimit: snapshot.individualLimit,
                authPayloadBase64: request.operation == .auth ? freshAuth.base64EncodedString() : nil)
        } catch let error as RathHandoffError {
            throw error
        } catch {
            // Never expose Keychain, file paths, auth bytes or upstream error text.
            throw RathHandoffError.unavailable
        }
    }
}

enum RathHandoffCLI {
    static func stdoutIsPipe() -> Bool {
        var info = stat()
        return fstat(STDOUT_FILENO, &info) == 0 && (info.st_mode & S_IFMT) == S_IFIFO
    }

    @MainActor
    static func run(arguments: [String]) async -> Int32 {
        do {
            let request = try RathHandoffRequest(arguments: arguments)
            guard stdoutIsPipe() else { throw RathHandoffError.pipeRequired }
            let policy = try RathHandoffPolicy.load(store: KeychainStore())
            guard policy.enabled else { throw RathHandoffError.disabled }
            // No profile metadata or auth Keychain access until consent and pipe checks pass.
            let service = RathHandoffService(policy: policy, store: ProfileStore(), client: AppServerClient())
            let bytes: Data
            if request.operation == .pool {
                let response = try await service.pool(jobID: request.jobID)
                bytes = try JSONEncoder().encode(response) + Data([0x0a])
            } else {
                bytes = try await service.perform(request).machineData()
            }
            guard bytes.count <= 1_048_576 else { throw RathHandoffError.unavailable }
            // One response, no human-readable output on the credential channel.
            try FileHandle.standardOutput.write(contentsOf: bytes)
            return 0
        } catch {
            let safeError = (error as? RathHandoffError) ?? .unavailable
            try? FileHandle.standardError.write(contentsOf: Data("{\"error\":\"\(safeError.rawValue)\",\"schemaVersion\":1}\n".utf8))
            return 1
        }
    }
}
