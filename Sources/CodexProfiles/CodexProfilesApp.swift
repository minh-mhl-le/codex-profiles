import AppKit
import Combine
import Darwin
import Foundation
import Security
import ServiceManagement
import SwiftUI

enum AppMetadata {
    static let version = "0.1.2"
}

enum DemoScenario: String {
    case empty
    case usage
    case switchTarget = "switch"

    static var current: DemoScenario? {
        ProcessInfo.processInfo.environment["CODEX_PROFILES_DEMO"].flatMap(DemoScenario.init(rawValue:))
    }
}

// MARK: - Models

struct Profile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var email: String?
    var planType: String?
    var accountID: String? = nil
    let createdAt: Date
}

struct UsageBucket: Identifiable, Equatable {
    let id: String
    let name: String
    let usedPercent: Double?
    let resetsAt: Date?
    let windowDurationMinutes: Int?
}

struct UsageSnapshot: Equatable {
    var email: String?
    var planType: String?
    var accountID: String? = nil
    var buckets: [UsageBucket] = []
    var lastRefreshed: Date?
    var error: String?
    var isLoading = false
}

struct ProfileRenameRequest: Identifiable {
    let id: UUID
}

enum ProfileError: LocalizedError {
    case noActiveAuth
    case missingProfile
    case keychain(OSStatus)
    case invalidResponse(String)
    case appServerUnavailable
    case appServerError(String)
    case appServerTimedOut
    case accountMismatch(expected: String, actual: String)
    case activeTasksUnknown
    case activeTasksRunning(Int)
    case appDidNotExit
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .noActiveAuth:
            return "No active Codex auth file was found at ~/.codex/auth.json."
        case .missingProfile:
            return "The selected Codex profile is no longer available."
        case .keychain(let status):
            return "macOS Keychain error (\(status))."
        case .invalidResponse(let message):
            return "Codex returned an unexpected response: \(message)"
        case .appServerUnavailable:
            return "The Codex App Server executable could not be found."
        case .appServerError(let message):
            return message
        case .appServerTimedOut:
            return "Codex did not respond in time. Try opening Codex once, then refresh again."
        case .accountMismatch(let expected, let actual):
            return "The signed-in account (\(actual)) does not match the saved profile (\(expected)). The switch was cancelled."
        case .activeTasksUnknown:
            return "Could not verify whether Codex has an active task. Switching is blocked for safety."
        case .activeTasksRunning(let count):
            return "Codex has \(count) active task\(count == 1 ? "" : "s"). Finish or interrupt it, then try again."
        case .appDidNotExit:
            return "Codex did not exit cleanly. No credentials were switched."
        case .verificationFailed:
            return "The target account could not be verified. The previous account was restored."
        }
    }
}

// MARK: - Local storage

final class KeychainStore {
    private let service = "com.codexprofiles.auth"

    func save(_ data: Data, for profileID: UUID) throws {
        let account = profileID.uuidString
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw ProfileError.keychain(status) }
    }

    func read(for profileID: UUID) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw ProfileError.keychain(status)
        }
        return data
    }

    func delete(for profileID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProfileError.keychain(status)
        }
    }
}

final class ProfileStore {
    private let fileManager = FileManager.default
    private let keychain = KeychainStore()

    private var applicationSupport: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Profiles", isDirectory: true)
    }

    private var metadataURL: URL {
        applicationSupport.appendingPathComponent("profiles.json")
    }

    private var currentIDURL: URL {
        applicationSupport.appendingPathComponent("current-profile")
    }

    var liveAuthURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    init() {
        try? fileManager.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: applicationSupport.path)
    }

    func loadProfiles() throws -> [Profile] {
        guard fileManager.fileExists(atPath: metadataURL.path) else { return [] }
        let data = try Data(contentsOf: metadataURL)
        return try JSONDecoder().decode([Profile].self, from: data)
    }

    func saveProfiles(_ profiles: [Profile]) throws {
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: metadataURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
    }

    func currentProfileID() -> UUID? {
        guard let value = try? String(contentsOf: currentIDURL, encoding: .utf8) else { return nil }
        return UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func setCurrentProfileID(_ id: UUID) throws {
        try id.uuidString.write(to: currentIDURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: currentIDURL.path)
    }

    func readLiveAuth() throws -> Data {
        guard fileManager.fileExists(atPath: liveAuthURL.path) else { throw ProfileError.noActiveAuth }
        return try Data(contentsOf: liveAuthURL)
    }

    func saveAuth(_ data: Data, for profileID: UUID) throws {
        try keychain.save(data, for: profileID)
    }

    func readAuth(for profileID: UUID) throws -> Data {
        try keychain.read(for: profileID)
    }

    func deleteAuth(for profileID: UUID) throws {
        try keychain.delete(for: profileID)
    }

    func deleteAll(profiles: [Profile]) throws {
        for profile in profiles {
            try? keychain.delete(for: profile.id)
        }
        try? fileManager.removeItem(at: metadataURL)
        try? fileManager.removeItem(at: currentIDURL)
    }

    func installLiveAuth(_ data: Data) throws {
        let parent = liveAuthURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appendingPathComponent(".auth.json.codexprofiles-\(UUID().uuidString)")
        try data.write(to: temporaryURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)

        if fileManager.fileExists(atPath: liveAuthURL.path) {
            _ = try fileManager.replaceItemAt(liveAuthURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: liveAuthURL)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: liveAuthURL.path)
    }

    func hasLiveAuth() -> Bool {
        fileManager.fileExists(atPath: liveAuthURL.path)
    }
}

// MARK: - App Server integration

private struct AppServerResult {
    let account: [String: Any]?
    let rateLimits: [String: Any]?
    let refreshedAuth: Data?
}

final class CodexBinaryResolver {
    func resolve() -> URL? {
        let candidates: [URL] = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
                .map { $0.appendingPathComponent("Contents/Resources/codex") },
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
        ].compactMap { $0 }

        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }
}

final class AppServerClient: @unchecked Sendable {
    private let resolver = CodexBinaryResolver()

    func readAccountAndUsage(auth: Data, codeHome: URL? = nil) async throws -> (UsageSnapshot, Data?) {
        try await Task.detached(priority: .utility) {
            let result = try self.run(auth: auth, codeHome: codeHome, requestUsage: true, waitForLogin: false)
            let snapshot = try Self.snapshot(from: result)
            return (snapshot, result.refreshedAuth)
        }.value
    }

    func login() async throws -> (Data, UsageSnapshot) {
        try await Task.detached(priority: .userInitiated) {
            let result = try self.run(auth: nil, codeHome: nil, requestUsage: false, waitForLogin: true)
            guard let refreshedAuth = result.refreshedAuth else { throw ProfileError.invalidResponse("Login completed without credentials.") }
            return (refreshedAuth, try Self.snapshot(from: result))
        }.value
    }

    func activeTaskCount(auth: Data) async throws -> Int {
        try await Task.detached(priority: .userInitiated) {
            guard let binary = self.resolver.resolve() else { throw ProfileError.appServerUnavailable }
            let home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
            let process = Process()
            process.executableURL = binary
            process.arguments = ["app-server"]
            process.environment = ProcessInfo.processInfo.environment.merging(["CODEX_HOME": home.path]) { _, new in new }
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer {
                if process.isRunning { process.terminate() }
            }

            let reader = JSONLineReader(handle: output.fileHandleForReading, timeout: 15)
            try Self.send(["method": "initialize", "id": 1, "params": ["clientInfo": ["name": "codex_profiles", "title": "Codex Profiles", "version": AppMetadata.version]]], to: input.fileHandleForWriting)
            try Self.send(["method": "initialized", "params": [:]], to: input.fileHandleForWriting)
            try Self.send(["method": "thread/list", "id": 2, "params": ["limit": 200, "archived": false]], to: input.fileHandleForWriting)

            while let message = try reader.nextObject() {
                if let id = message["id"] as? Int, id == 2 {
                    if let error = message["error"] as? [String: Any] {
                        throw ProfileError.appServerError(error["message"] as? String ?? "Unable to inspect Codex tasks.")
                    }
                    let result = message["result"] as? [String: Any]
                    let items = result?["data"] as? [[String: Any]] ?? []
                    let active = items.filter { thread in
                        guard let status = (thread["status"] as? String)?.lowercased() else { return false }
                        return status.contains("running") || status.contains("progress") || status.contains("queued") || status.contains("pending") || status.contains("waiting") || status.contains("review")
                    }
                    return active.count
                }
            }
            throw ProfileError.activeTasksUnknown
        }.value
    }

    private func run(auth: Data?, codeHome: URL?, requestUsage: Bool, waitForLogin: Bool) throws -> AppServerResult {
        guard let binary = resolver.resolve() else { throw ProfileError.appServerUnavailable }

        let temporaryHome: URL
        let ownsTemporaryHome: Bool
        if let codeHome {
            temporaryHome = codeHome
            ownsTemporaryHome = false
        } else {
            temporaryHome = FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-profiles-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
            ownsTemporaryHome = true
        }
        defer {
            if ownsTemporaryHome { try? FileManager.default.removeItem(at: temporaryHome) }
        }

        if let auth {
            let authURL = temporaryHome.appendingPathComponent("auth.json")
            try auth.write(to: authURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
        }
        let configURL = temporaryHome.appendingPathComponent("config.toml")
        try Data("cli_auth_credentials_store = \"file\"\n".utf8).write(to: configURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)

        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server"]
        process.environment = ProcessInfo.processInfo.environment.merging(["CODEX_HOME": temporaryHome.path]) { _, new in new }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        let writer = input.fileHandleForWriting
        let reader = JSONLineReader(handle: output.fileHandleForReading, timeout: waitForLogin ? 300 : 20)
        try Self.send(["method": "initialize", "id": 1, "params": ["clientInfo": ["name": "codex_profiles", "title": "Codex Profiles", "version": AppMetadata.version]]], to: writer)
        try Self.send(["method": "initialized", "params": [:]], to: writer)

        if waitForLogin {
            try Self.send(["method": "account/login/start", "id": 2, "params": ["type": "chatgpt", "useHostedLoginSuccessPage": true, "appBrand": "codex"]], to: writer)
        } else {
            try Self.send(["method": "account/read", "id": 2, "params": ["refreshToken": false]], to: writer)
            if requestUsage {
                try Self.send(["method": "account/rateLimits/read", "id": 3, "params": [:]], to: writer)
            }
        }

        var account: [String: Any]?
        var rateLimits: [String: Any]?
        var loginStarted = false
        var loginCompleted = false
        var loginRateLimitsRequested = false

        while let message = try reader.nextObject() {
            if let method = message["method"] as? String {
                if waitForLogin, method == "account/login/completed" {
                    let params = message["params"] as? [String: Any]
                    let success = params?["success"] as? Bool ?? false
                    guard success else { throw ProfileError.appServerError(params?["error"] as? String ?? "ChatGPT login failed.") }
                    loginCompleted = true
                    try Self.send(["method": "account/read", "id": 4, "params": ["refreshToken": false]], to: writer)
                }
                continue
            }

            guard let id = message["id"] as? Int else { continue }
            if let error = message["error"] as? [String: Any] {
                throw ProfileError.appServerError(error["message"] as? String ?? "Codex App Server request failed.")
            }
            let result = message["result"] as? [String: Any]
            switch id {
            case 2:
                if waitForLogin {
                    if let authURL = result?["authUrl"] as? String, let url = URL(string: authURL) {
                        awaitOpen(url)
                        loginStarted = true
                    }
                } else {
                    account = result?["account"] as? [String: Any]
                }
            case 3:
                rateLimits = result
            case 4:
                account = result?["account"] as? [String: Any]
                if waitForLogin && !loginRateLimitsRequested {
                    try Self.send(["method": "account/rateLimits/read", "id": 5, "params": [:]], to: writer)
                    loginRateLimitsRequested = true
                }
            case 5:
                rateLimits = result
            default:
                break
            }

            if waitForLogin && loginStarted && loginCompleted && account != nil && (rateLimits != nil || !loginRateLimitsRequested) { break }
            if !waitForLogin && account != nil && (!requestUsage || rateLimits != nil) { break }
        }

        guard !waitForLogin || (loginStarted && loginCompleted) else {
            throw ProfileError.appServerError("The ChatGPT login flow did not complete.")
        }

        let refreshedAuthURL = temporaryHome.appendingPathComponent("auth.json")
        let refreshedAuth = try? Data(contentsOf: refreshedAuthURL)
        return AppServerResult(account: account, rateLimits: rateLimits, refreshedAuth: refreshedAuth)
    }

    private func awaitOpen(_ url: URL) {
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    private static func send(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data([0x0a]))
    }

    private static func snapshot(from result: AppServerResult) throws -> UsageSnapshot {
        guard let account = result.account else { throw ProfileError.invalidResponse("No account information was returned.") }
        let email = account["email"] as? String
        let planType = account["planType"] as? String
        var buckets: [UsageBucket] = []

        if let byLimitID = result.rateLimits?["rateLimitsByLimitId"] as? [String: Any] {
            for (id, value) in byLimitID {
                guard let bucket = value as? [String: Any] else { continue }
                buckets.append(contentsOf: Self.buckets(id: id, value: bucket))
            }
        } else if let rateLimits = result.rateLimits?["rateLimits"] as? [String: Any] {
            buckets.append(contentsOf: Self.buckets(id: rateLimits["limitId"] as? String ?? "codex", value: rateLimits))
        }

        buckets.sort { Self.windowRank($0.name) < Self.windowRank($1.name) }
        let accountID = result.rateLimits?["accountId"] as? String ?? account["accountId"] as? String
        return UsageSnapshot(email: email, planType: planType, accountID: accountID, buckets: buckets, lastRefreshed: Date(), error: nil, isLoading: false)
    }

    private static func buckets(id: String, value: [String: Any]) -> [UsageBucket] {
        ["primary", "secondary"].compactMap { window in
            guard let data = value[window] as? [String: Any] else { return nil }
            let percent = data["usedPercent"] as? Double ?? (data["usedPercent"] as? Int).map(Double.init)
            let duration = data["windowDurationMins"] as? Int
            let timestamp = data["resetsAt"] as? Double ?? (data["resetsAt"] as? Int).map(Double.init)
            let name = windowName(duration: duration, fallback: window == "primary" ? value["limitName"] as? String ?? id : "Additional")
            return UsageBucket(id: "\(id)-\(window)", name: name, usedPercent: percent, resetsAt: timestamp.map(Date.init(timeIntervalSince1970:)), windowDurationMinutes: duration)
        }
    }

    private static func windowName(duration: Int?, fallback: String) -> String {
        guard let duration else { return fallback }
        if duration % (24 * 60) == 0 { return "\(duration / (24 * 60))d" }
        if duration % 60 == 0 { return "\(duration / 60)h" }
        return "\(duration)m"
    }

    private static func windowRank(_ name: String) -> Int {
        if name.hasSuffix("h") { return 0 }
        if name.hasSuffix("d") { return 1 }
        return 2
    }
}

private final class JSONLineReader {
    private let handle: FileHandle
    private let deadline: Date
    private var buffer = Data()

    init(handle: FileHandle, timeout: TimeInterval) {
        self.handle = handle
        deadline = Date().addingTimeInterval(timeout)
    }

    func nextObject() throws -> [String: Any]? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0a) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                return object
            }
            let chunk = try readAvailableChunk()
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }

    private func readAvailableChunk() throws -> Data {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ProfileError.appServerTimedOut }

            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let timeoutMilliseconds = Int32(min(remaining * 1_000, Double(Int32.max)))
            let pollResult = Darwin.poll(&descriptor, 1, max(timeoutMilliseconds, 1))

            if pollResult == 0 { throw ProfileError.appServerTimedOut }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            var bytes = [UInt8](repeating: 0, count: 4_096)
            let byteCount = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(handle.fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if byteCount == 0 { return Data() }
            if byteCount < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return Data(bytes.prefix(byteCount))
        }
    }
}

// MARK: - App orchestration

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var currentProfileID: UUID?
    @Published private(set) var usage: [UUID: UsageSnapshot] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSwitching = false
    @Published private(set) var isAdding = false
    @Published private(set) var popoverOpenGeneration = 0
    @Published var errorMessage: String?
    @Published var noticeMessage: String?
    @Published var switchBlockMessage: String?
    @Published var profileToName: ProfileRenameRequest?

    private let demoScenario: DemoScenario?
    private lazy var store = ProfileStore()
    private let appServer = AppServerClient()
    let settings = SettingsStore.shared
    private var didOpen = false

    init(demoScenario: DemoScenario? = DemoScenario.current) {
        self.demoScenario = demoScenario
        if let demoScenario {
            seedDemoData(for: demoScenario)
        }
    }

    var isDemoMode: Bool { demoScenario != nil }

    var preferredExpandedProfileID: UUID? {
        if demoScenario == .switchTarget {
            return profiles.first(where: { $0.id != currentProfileID })?.id
        }
        return currentProfileID
    }

    var currentProfile: Profile? {
        profiles.first(where: { $0.id == currentProfileID })
    }

    func markPopoverOpened() {
        popoverOpenGeneration += 1
    }

    func prepareForPresentation() {
        guard !isDemoMode else { return }
        do {
            profiles = try store.loadProfiles()
            currentProfileID = store.currentProfileID()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open() async {
        guard !isDemoMode else { return }
        let firstOpen = !didOpen
        do {
            profiles = try store.loadProfiles()
            currentProfileID = store.currentProfileID()
            didOpen = true
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        if settings.refreshOnOpen || firstOpen {
            await refreshUsage()
        }
    }

    func refreshUsage() async {
        guard !isDemoMode else { return }
        guard !isRefreshing, !isSwitching else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        errorMessage = nil
        noticeMessage = nil

        if profiles.isEmpty, let liveAuth = try? store.readLiveAuth() {
            let profile = Profile(id: UUID(), name: "Current account", email: nil, planType: nil, accountID: nil, createdAt: Date())
            try? store.saveAuth(liveAuth, for: profile.id)
            profiles = [profile]
            currentProfileID = profile.id
            try? store.saveProfiles(profiles)
            try? store.setCurrentProfileID(profile.id)
        }

        guard !profiles.isEmpty else { return }

        var liveProfileID: UUID?
        var liveSnapshot: UsageSnapshot?
        if let liveAuth = try? store.readLiveAuth() {
            do {
                let result = try await appServer.readAccountAndUsage(auth: liveAuth)
                let matchedID = try reconcileLiveAccount(snapshot: result.0)
                liveProfileID = matchedID
                liveSnapshot = result.0
                if let refreshedAuth = result.1 {
                    try? store.saveAuth(refreshedAuth, for: matchedID)
                } else {
                    try? store.saveAuth(liveAuth, for: matchedID)
                }
            } catch {
                if profiles.count == 1, let onlyID = profiles.first?.id {
                    liveProfileID = onlyID
                }
            }
        }

        for profile in profiles {
            if profile.id == liveProfileID, let liveSnapshot {
                usage[profile.id] = liveSnapshot
                continue
            }

            let previous = usage[profile.id]
            usage[profile.id] = UsageSnapshot(email: previous?.email ?? profile.email, planType: previous?.planType ?? profile.planType, accountID: previous?.accountID ?? profile.accountID, buckets: previous?.buckets ?? [], lastRefreshed: previous?.lastRefreshed, error: nil, isLoading: true)
            do {
                let auth = try store.readAuth(for: profile.id)
                let (snapshot, refreshedAuth) = try await appServer.readAccountAndUsage(auth: auth)
                if let refreshedAuth, profile.id != currentProfileID || !CodexInspector.isRunning {
                    try? store.saveAuth(refreshedAuth, for: profile.id)
                }
                usage[profile.id] = snapshot
                updateProfileIdentity(profileID: profile.id, snapshot: snapshot)
            } catch {
                usage[profile.id] = UsageSnapshot(email: previous?.email ?? profile.email, planType: previous?.planType ?? profile.planType, accountID: previous?.accountID ?? profile.accountID, buckets: previous?.buckets ?? [], lastRefreshed: previous?.lastRefreshed, error: error.localizedDescription, isLoading: false)
            }
        }
    }

    func addAccount() async {
        guard !isDemoMode else { return }
        guard !isAdding else { return }
        isAdding = true
        defer { isAdding = false }
        errorMessage = nil
        noticeMessage = nil
        do {
            let (auth, snapshot) = try await appServer.login()
            if let existing = profiles.first(where: { matches($0, snapshot) }) {
                try store.saveAuth(auth, for: existing.id)
                updateProfileIdentity(profileID: existing.id, snapshot: snapshot)
                usage[existing.id] = snapshot
                noticeMessage = "Account already saved — credentials refreshed."
            } else {
                let name = snapshot.email?.split(separator: "@").first.map(String.init) ?? "Personal \(profiles.count + 1)"
                let profile = Profile(id: UUID(), name: name, email: snapshot.email, planType: snapshot.planType, accountID: snapshot.accountID, createdAt: Date())
                try store.saveAuth(auth, for: profile.id)
                profiles.append(profile)
                try store.saveProfiles(profiles)
                usage[profile.id] = snapshot
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ profileID: UUID, to name: String) {
        guard !isDemoMode else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].name = trimmed
        try? store.saveProfiles(profiles)
    }

    func remove(_ profileID: UUID) {
        guard !isDemoMode else { return }
        guard profileID != currentProfileID else {
            errorMessage = "Switch to another profile before removing this one."
            return
        }
        profiles.removeAll { $0.id == profileID }
        usage[profileID] = nil
        try? store.deleteAuth(for: profileID)
        try? store.saveProfiles(profiles)
    }

    func deleteAllSavedProfiles() {
        guard !isDemoMode else { return }
        try? store.deleteAll(profiles: profiles)
        profiles = []
        currentProfileID = nil
        usage = [:]
        didOpen = false
    }

    func switchTo(_ targetID: UUID) async {
        guard !isDemoMode else { return }
        guard !isSwitching, targetID != currentProfileID else { return }
        guard let currentID = currentProfileID else { errorMessage = ProfileError.missingProfile.localizedDescription; return }
        isSwitching = true
        defer { isSwitching = false }
        errorMessage = nil
        noticeMessage = nil
        var didQuit = false
        var originalAuth: Data?
        do {
            if CodexInspector.isRunning {
                let liveAuth = try store.readLiveAuth()
                let count = try await appServer.activeTaskCount(auth: liveAuth)
                if count > 0 { throw ProfileError.activeTasksRunning(count) }
            }

            let targetProfile = profiles.first(where: { $0.id == targetID })
            let targetAuth = try store.readAuth(for: targetID)
            let (verifiedTargetAuth, targetSnapshot) = try await verifyTarget(profile: targetProfile, auth: targetAuth)
            updateProfileIdentity(profileID: targetID, snapshot: targetSnapshot)

            let currentAuthBeforeQuit = try store.readLiveAuth()
            originalAuth = currentAuthBeforeQuit
            try store.saveAuth(currentAuthBeforeQuit, for: currentID)
            try await CodexInspector.quitAndWait()
            didQuit = true

            let currentAuthAfterQuit = try store.readLiveAuth()
            originalAuth = currentAuthAfterQuit
            try store.saveAuth(currentAuthAfterQuit, for: currentID)
            try store.saveAuth(verifiedTargetAuth, for: targetID)
            try store.installLiveAuth(verifiedTargetAuth)

            currentProfileID = targetID
            try store.setCurrentProfileID(targetID)
            if settings.openCodexAfterSwitch { CodexInspector.open() }
        } catch {
            if didQuit, let originalAuth {
                try? store.installLiveAuth(originalAuth)
                if settings.openCodexAfterSwitch { CodexInspector.open() }
            }
            if case ProfileError.activeTasksRunning = error {
                switchBlockMessage = error.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func reconcileLiveAccount(snapshot: UsageSnapshot) throws -> UUID {
        let matched = profiles.first(where: { matches($0, snapshot) })
        let profileID: UUID
        if let matched {
            profileID = matched.id
        } else if let anonymousCurrent = profiles.first(where: {
            $0.name == "Current account" && $0.email == nil && $0.accountID == nil
        }) {
            profileID = anonymousCurrent.id
        } else {
            let profile = Profile(id: UUID(), name: snapshot.email?.split(separator: "@").first.map(String.init) ?? "New account", email: snapshot.email, planType: snapshot.planType, accountID: snapshot.accountID, createdAt: Date())
            profiles.append(profile)
            profileID = profile.id
            try store.saveProfiles(profiles)
        }
        currentProfileID = profileID
        try store.setCurrentProfileID(profileID)
        updateProfileIdentity(profileID: profileID, snapshot: snapshot)
        return profileID
    }

    private func verifyTarget(profile: Profile?, auth: Data) async throws -> (Data, UsageSnapshot) {
        do {
            let (snapshot, refreshedAuth) = try await appServer.readAccountAndUsage(auth: auth)
            guard profile == nil || matches(profile!, snapshot) || (profile?.accountID == nil && profile?.email == nil) else {
                throw ProfileError.accountMismatch(expected: identity(of: profile), actual: identity(of: snapshot))
            }
            return (refreshedAuth ?? auth, snapshot)
        } catch let error as ProfileError {
            if case .accountMismatch = error { throw error }
            guard shouldReauthenticate(for: error) else { throw error }
            return try await reauthenticate(profile: profile)
        } catch {
            throw error
        }
    }

    private func reauthenticate(profile: Profile?) async throws -> (Data, UsageSnapshot) {
        let (newAuth, snapshot) = try await appServer.login()
        guard profile == nil || matches(profile!, snapshot) || (profile?.accountID == nil && profile?.email == nil) else {
            throw ProfileError.accountMismatch(expected: identity(of: profile), actual: identity(of: snapshot))
        }
        return (newAuth, snapshot)
    }

    private func shouldReauthenticate(for error: ProfileError) -> Bool {
        guard case .appServerError(let rawMessage) = error else { return false }
        let message = rawMessage.lowercased()
        return ["auth", "token", "credential", "unauthorized", "login", "expired", "refresh"].contains { message.contains($0) }
    }

    private func matches(_ profile: Profile, _ snapshot: UsageSnapshot) -> Bool {
        if let profileAccountID = profile.accountID, let snapshotAccountID = snapshot.accountID {
            return profileAccountID == snapshotAccountID
        }
        if let profileEmail = profile.email, let snapshotEmail = snapshot.email {
            return profileEmail.caseInsensitiveCompare(snapshotEmail) == .orderedSame
        }
        return false
    }

    private func identity(of profile: Profile?) -> String {
        profile?.email ?? profile?.accountID ?? "the saved profile"
    }

    private func identity(of snapshot: UsageSnapshot) -> String {
        snapshot.email ?? snapshot.accountID ?? "the signed-in account"
    }

    private func updateProfileIdentity(profileID: UUID, snapshot: UsageSnapshot) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        if profiles[index].email != snapshot.email || profiles[index].planType != snapshot.planType || profiles[index].accountID != snapshot.accountID {
            profiles[index].email = snapshot.email
            profiles[index].planType = snapshot.planType
            profiles[index].accountID = snapshot.accountID ?? profiles[index].accountID
            try? store.saveProfiles(profiles)
        }
    }

    private func seedDemoData(for scenario: DemoScenario) {
        guard scenario != .empty else { return }

        let personalID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let workID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let schoolID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        let now = Date()

        profiles = [
            Profile(id: personalID, name: "Personal", email: nil, planType: "Plus", createdAt: now),
            Profile(id: workID, name: "Work", email: nil, planType: "Team", createdAt: now),
            Profile(id: schoolID, name: "School", email: nil, planType: "Free", createdAt: now),
        ]
        currentProfileID = personalID
        usage = [
            personalID: Self.demoUsage(fiveHour: 24, weekly: 58, now: now),
            workID: Self.demoUsage(fiveHour: 71, weekly: 36, now: now),
            schoolID: Self.demoUsage(fiveHour: 9, weekly: 82, now: now),
        ]
    }

    private static func demoUsage(fiveHour: Double, weekly: Double, now: Date) -> UsageSnapshot {
        UsageSnapshot(
            buckets: [
                UsageBucket(id: "five-hour", name: "5h", usedPercent: fiveHour, resetsAt: now.addingTimeInterval(75 * 60), windowDurationMinutes: 300),
                UsageBucket(id: "weekly", name: "7d", usedPercent: weekly, resetsAt: now.addingTimeInterval(5 * 24 * 60 * 60), windowDurationMinutes: 10_080),
            ],
            lastRefreshed: now
        )
    }
}

enum CodexInspector {
    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.openai.codex" }
    }

    static func quitAndWait() async throws {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.openai.codex" }) else { return }
        app.terminate()
        for _ in 0..<50 {
            if app.isTerminated || !isRunning { return }
            try? await Task.sleep(for: .milliseconds(100))
        }

        // A task was already checked and found idle. Use a final hard quit only
        // when the app refuses to terminate, then verify it is gone.
        app.forceTerminate()
        for _ in 0..<50 {
            if app.isTerminated || !isRunning { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw ProfileError.appDidNotExit
    }

    static func open() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Settings and icon

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let launchAtLoginKey = "launchAtLogin"
    private let openPanelAtLaunchKey = "openPanelAtLaunch"
    private let refreshOnOpenKey = "refreshOnOpen"
    private let openCodexAfterSwitchKey = "openCodexAfterSwitch"
    private let soundEffectsKey = "soundEffects"
    private let isDemoMode: Bool

    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var openPanelAtLaunch: Bool
    @Published private(set) var refreshOnOpen: Bool
    @Published private(set) var openCodexAfterSwitch: Bool
    @Published private(set) var soundEffects: Bool

    private init() {
        isDemoMode = DemoScenario.current != nil
        if isDemoMode {
            launchAtLogin = false
            openPanelAtLaunch = false
            refreshOnOpen = true
            openCodexAfterSwitch = true
            soundEffects = true
            return
        }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: launchAtLoginKey) == nil {
            defaults.set(false, forKey: launchAtLoginKey)
        }
        if defaults.object(forKey: openPanelAtLaunchKey) == nil {
            defaults.set(true, forKey: openPanelAtLaunchKey)
        }
        if defaults.object(forKey: refreshOnOpenKey) == nil {
            defaults.set(true, forKey: refreshOnOpenKey)
        }
        if defaults.object(forKey: openCodexAfterSwitchKey) == nil {
            defaults.set(true, forKey: openCodexAfterSwitchKey)
        }
        if defaults.object(forKey: soundEffectsKey) == nil {
            defaults.set(true, forKey: soundEffectsKey)
        }
        launchAtLogin = defaults.bool(forKey: launchAtLoginKey)
        openPanelAtLaunch = defaults.bool(forKey: openPanelAtLaunchKey)
        refreshOnOpen = defaults.bool(forKey: refreshOnOpenKey)
        openCodexAfterSwitch = defaults.bool(forKey: openCodexAfterSwitchKey)
        soundEffects = defaults.bool(forKey: soundEffectsKey)
        if !launchAtLogin { try? SMAppService.mainApp.unregister() }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        InteractionFeedback.shared.play()
        guard !isDemoMode else { return }
        launchAtLogin = enabled
        UserDefaults.standard.set(enabled, forKey: launchAtLoginKey)
        if enabled { try? SMAppService.mainApp.register() }
        else { try? SMAppService.mainApp.unregister() }
    }

    func setOpenPanelAtLaunch(_ enabled: Bool) {
        InteractionFeedback.shared.play()
        guard !isDemoMode else { return }
        openPanelAtLaunch = enabled
        UserDefaults.standard.set(enabled, forKey: openPanelAtLaunchKey)
    }

    func setRefreshOnOpen(_ enabled: Bool) {
        InteractionFeedback.shared.play()
        guard !isDemoMode else { return }
        refreshOnOpen = enabled
        UserDefaults.standard.set(enabled, forKey: refreshOnOpenKey)
    }

    func setOpenCodexAfterSwitch(_ enabled: Bool) {
        InteractionFeedback.shared.play()
        guard !isDemoMode else { return }
        openCodexAfterSwitch = enabled
        UserDefaults.standard.set(enabled, forKey: openCodexAfterSwitchKey)
    }

    func setSoundEffects(_ enabled: Bool) {
        InteractionFeedback.shared.play(force: true)
        guard !isDemoMode else { return }
        soundEffects = enabled
        UserDefaults.standard.set(enabled, forKey: soundEffectsKey)
    }
}

@MainActor
final class InteractionFeedback {
    static let shared = InteractionFeedback()

    private var sound: NSSound?

    func play(force: Bool = false) {
        guard force || SettingsStore.shared.soundEffects else { return }
        sound?.stop()
        sound = NSSound(named: NSSound.Name("Pop"))
        sound?.play()
    }
}

enum ProfileSwitchIcon {
    static func image(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.black.setStroke()

        let lineWidth = max(1.5, size * 0.105)
        let headRadius = size * 0.105
        let firstHead = NSPoint(x: size * 0.34, y: size * 0.68)
        let secondHead = NSPoint(x: size * 0.66, y: size * 0.32)

        for center in [firstHead, secondHead] {
            let head = NSBezierPath(ovalIn: NSRect(x: center.x - headRadius, y: center.y - headRadius, width: headRadius * 2, height: headRadius * 2))
            head.lineWidth = lineWidth
            head.stroke()
        }

        let shoulders = NSBezierPath()
        shoulders.move(to: NSPoint(x: size * 0.18, y: size * 0.43))
        shoulders.curve(to: NSPoint(x: size * 0.50, y: size * 0.43), controlPoint1: NSPoint(x: size * 0.25, y: size * 0.61), controlPoint2: NSPoint(x: size * 0.43, y: size * 0.61))
        shoulders.move(to: NSPoint(x: size * 0.50, y: size * 0.20))
        shoulders.curve(to: NSPoint(x: size * 0.82, y: size * 0.20), controlPoint1: NSPoint(x: size * 0.57, y: size * 0.38), controlPoint2: NSPoint(x: size * 0.75, y: size * 0.38))
        shoulders.lineWidth = lineWidth
        shoulders.lineCapStyle = .round
        shoulders.stroke()

        let arrows = NSBezierPath()
        arrows.move(to: NSPoint(x: size * 0.47, y: size * 0.82))
        arrows.curve(to: NSPoint(x: size * 0.76, y: size * 0.65), controlPoint1: NSPoint(x: size * 0.67, y: size * 0.84), controlPoint2: NSPoint(x: size * 0.73, y: size * 0.77))
        arrows.move(to: NSPoint(x: size * 0.69, y: size * 0.73))
        arrows.line(to: NSPoint(x: size * 0.76, y: size * 0.65))
        arrows.line(to: NSPoint(x: size * 0.65, y: size * 0.65))
        arrows.move(to: NSPoint(x: size * 0.53, y: size * 0.18))
        arrows.curve(to: NSPoint(x: size * 0.24, y: size * 0.35), controlPoint1: NSPoint(x: size * 0.33, y: size * 0.16), controlPoint2: NSPoint(x: size * 0.27, y: size * 0.23))
        arrows.move(to: NSPoint(x: size * 0.31, y: size * 0.27))
        arrows.line(to: NSPoint(x: size * 0.24, y: size * 0.35))
        arrows.line(to: NSPoint(x: size * 0.35, y: size * 0.35))
        arrows.lineWidth = lineWidth
        arrows.lineCapStyle = .round
        arrows.lineJoinStyle = .round
        arrows.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

// MARK: - Views

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    let onSettings: () -> Void
    @State private var expandedProfileID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            Divider()

            if model.profiles.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.profiles) { profile in
                            ProfileRow(
                                profile: profile,
                                snapshot: model.usage[profile.id],
                                isCurrent: profile.id == model.currentProfileID,
                                isExpanded: expandedProfileID == profile.id,
                                isSwitching: model.isSwitching,
                                onToggle: {
                                    InteractionFeedback.shared.play()
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        expandedProfileID = expandedProfileID == profile.id ? nil : profile.id
                                    }
                                },
                                onSwitch: {
                                    InteractionFeedback.shared.play()
                                    Task { await model.switchTo(profile.id) }
                                },
                                onRename: {
                                    InteractionFeedback.shared.play()
                                    model.profileToName = ProfileRenameRequest(id: profile.id)
                                },
                                onRemove: {
                                    InteractionFeedback.shared.play()
                                    model.remove(profile.id)
                                }
                            )
                        }
                    }
                }
                .frame(maxHeight: 300)
            }

            if let message = model.noticeMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = model.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack(spacing: 12) {
                Button {
                    InteractionFeedback.shared.play()
                    Task { await model.addAccount() }
                } label: {
                    Label(model.isAdding ? "Waiting for sign-in…" : "Add account", systemImage: model.isAdding ? "person.crop.circle.badge.clock" : "plus")
                }
                .disabled(model.isAdding || model.isSwitching)

                Spacer()

                Button {
                    InteractionFeedback.shared.play()
                    Task { await model.refreshUsage() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh usage")
                .disabled(model.isRefreshing || model.isSwitching)
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 332)
        .onAppear { expandedProfileID = model.preferredExpandedProfileID }
        .onChange(of: model.popoverOpenGeneration) { _ in
            withAnimation(.easeInOut(duration: 0.18)) {
                expandedProfileID = model.preferredExpandedProfileID
            }
        }
        .onChange(of: model.currentProfileID) { newValue in
            withAnimation(.easeInOut(duration: 0.18)) {
                expandedProfileID = newValue
            }
        }
        .sheet(item: $model.profileToName) { request in
            RenameProfileView(model: model, profileID: request.id)
        }
        .alert("Finish the active Codex task first", isPresented: Binding(get: { model.switchBlockMessage != nil }, set: { if !$0 { model.switchBlockMessage = nil } })) {
            Button("Open Codex") {
                model.switchBlockMessage = nil
                CodexInspector.open()
            }
            Button("Cancel", role: .cancel) { model.switchBlockMessage = nil }
        } message: {
            Text(model.switchBlockMessage ?? "Switching is blocked while Codex is working.")
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(nsImage: ProfileSwitchIcon.image(size: 20))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Codex Profiles")
                    .font(.headline)
                Text(model.currentProfile.map { "Active: \($0.name)" } ?? "No active profile")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRefreshing { ProgressView().controlSize(.small) }
            Button {
                InteractionFeedback.shared.play()
                onSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("No saved accounts yet")
                .font(.subheadline.weight(.medium))
            Text("Add an account to keep its login securely in Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Add account") {
                    InteractionFeedback.shared.play()
                    Task { await model.addAccount() }
                }
                    .buttonStyle(.borderedProminent)
                Button("Open Codex") {
                    InteractionFeedback.shared.play()
                    CodexInspector.open()
                }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 8)
    }
}

struct ProfileRow: View {
    let profile: Profile
    let snapshot: UsageSnapshot?
    let isCurrent: Bool
    let isExpanded: Bool
    let isSwitching: Bool
    let onToggle: () -> Void
    let onSwitch: () -> Void
    let onRename: () -> Void
    let onRemove: () -> Void
    @State private var showingRemoveConfirmation = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.22))
                        .frame(width: 25, height: 25)
                        .overlay {
                            Text(String(profile.name.prefix(1)).uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(isCurrent ? .white : .primary)
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(profile.name)
                                .font(.subheadline.weight(.medium))
                            if isCurrent {
                                Text("ACTIVE")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        if !isExpanded { UsageSummaryView(snapshot: snapshot) }
                    }
                    Spacer(minLength: 4)
                }

                Menu {
                    Button("Rename", action: onRename)
                    if !isCurrent {
                        Button("Remove", role: .destructive) { showingRemoveConfirmation = true }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .onTapGesture { InteractionFeedback.shared.play() }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }

            if isExpanded {
                expandedDetails
            }
        }
        .padding(9)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture(perform: onToggle)
        .onHover { isHovering = $0 }
        .background(.quaternary.opacity(isCurrent ? 0.55 : 0.35), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.accentColor.opacity(isHovering ? 0.07 : 0))
                .allowsHitTesting(false)
        }
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .animation(.easeInOut(duration: 0.18), value: isHovering)
        .confirmationDialog("Remove \(profile.name)?", isPresented: $showingRemoveConfirmation, titleVisibility: .visible) {
            Button("Remove Saved Profile", role: .destructive) {
                InteractionFeedback.shared.play()
                onRemove()
            }
            Button("Cancel", role: .cancel) { InteractionFeedback.shared.play() }
        } message: {
            Text("This removes the cached login from Keychain. Codex’s current login is left untouched.")
        }
    }

    @ViewBuilder private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let email = snapshot?.email ?? profile.email {
                Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let plan = snapshot?.planType ?? profile.planType {
                Text(plan.capitalized).font(.caption2).foregroundStyle(.secondary)
            }

            if let snapshot, !snapshot.buckets.isEmpty {
                ForEach(snapshot.buckets) { bucket in UsageBucketView(bucket: bucket) }
            } else if snapshot?.isLoading == true {
                ProgressView().controlSize(.small)
            } else {
                Text("Usage unavailable").font(.caption2).foregroundStyle(.secondary)
            }

            if let error = snapshot?.error {
                Label("Couldn’t refresh: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if let refreshed = snapshot?.lastRefreshed {
                    Text("Updated \(refreshed, style: .time)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isCurrent {
                    Button("Switch", action: onSwitch)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isSwitching)
                }
            }
        }
        .padding(.leading, 33)
    }
}

struct UsageSummaryView: View {
    let snapshot: UsageSnapshot?

    var body: some View {
        if let snapshot, !snapshot.buckets.isEmpty {
            HStack(spacing: 5) {
                ForEach(snapshot.buckets.prefix(2)) { bucket in
                    Text("\(bucket.name) \(bucket.usedPercent.map { "\(Int($0.rounded()))%" } ?? "—")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else if snapshot?.isLoading == true {
            Text("Refreshing…").font(.caption2).foregroundStyle(.secondary)
        } else if snapshot?.error != nil {
            Text("Unavailable").font(.caption2).foregroundStyle(.orange)
        } else {
            Text("No usage yet").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct UsageBucketView: View {
    let bucket: UsageBucket

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(bucket.name).font(.caption)
                Spacer()
                Text(bucket.usedPercent.map { "\(Int($0.rounded()))% used" } ?? "Unavailable")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: (bucket.usedPercent ?? 0) / 100)
                .tint(color(for: bucket.usedPercent))
            if let reset = bucket.resetsAt {
                Text("Resets \(reset, style: .relative)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func color(for used: Double?) -> Color {
        guard let used else { return .secondary }
        if used >= 90 { return .red }
        if used >= 70 { return .orange }
        return .accentColor
    }
}

struct RenameProfileView: View {
    @ObservedObject var model: AppModel
    let profileID: UUID
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name profile").font(.headline)
            TextField("Profile name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onAppear { name = model.profiles.first(where: { $0.id == profileID })?.name ?? "" }
            HStack {
                Spacer()
                Button("Cancel") {
                    InteractionFeedback.shared.play()
                    model.profileToName = nil
                }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    InteractionFeedback.shared.play()
                    model.rename(profileID, to: name)
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 280)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let onDeleteSavedProfiles: () -> Void
    @State private var showingDeleteConfirmation = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at Login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                Toggle("Open panel at launch", isOn: Binding(get: { settings.openPanelAtLaunch }, set: { settings.setOpenPanelAtLaunch($0) }))
                Toggle("Refresh usage when opened", isOn: Binding(get: { settings.refreshOnOpen }, set: { settings.setRefreshOnOpen($0) }))
                Toggle("Open Codex after switching", isOn: Binding(get: { settings.openCodexAfterSwitch }, set: { settings.setOpenCodexAfterSwitch($0) }))
                Toggle("Sound effects", isOn: Binding(get: { settings.soundEffects }, set: { settings.setSoundEffects($0) }))
            }
            Section("Saved data") {
                Button("Delete Saved Profiles…", role: .destructive) {
                    InteractionFeedback.shared.play()
                    showingDeleteConfirmation = true
                }
                Text("Removes cached credentials from Keychain and local metadata. Codex’s active login is not changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: AppMetadata.version)
                Text("An unofficial macOS account switcher for Codex.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("View source on GitHub", destination: URL(string: "https://github.com/minh-mhl-le/codex-profiles")!)
                Text("MIT licensed. Not affiliated with OpenAI.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Quit Codex Profiles") {
                    InteractionFeedback.shared.play()
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .formStyle(.grouped)
        .padding(14)
        .frame(width: 470, height: 390)
        .confirmationDialog("Delete all saved profiles?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Saved Profiles", role: .destructive) {
                InteractionFeedback.shared.play()
                onDeleteSavedProfiles()
            }
            Button("Cancel", role: .cancel) { InteractionFeedback.shared.play() }
        } message: {
            Text("This removes every cached account from Codex Profiles. Your active Codex login remains in place.")
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(model: AppModel) {
        let view = SettingsView(settings: model.settings, onDeleteSavedProfiles: { model.deleteAllSavedProfiles() })
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Codex Profiles Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showSettings() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - App entry point

@MainActor
final class StatusBarController: NSObject {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    init(model: AppModel, onSettings: @escaping () -> Void) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        statusItem.autosaveName = "CodexProfilesStatusItemV1"
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.title = ""
            button.image = ProfileSwitchIcon.image()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = "Codex Profiles — \(model.currentProfile?.name ?? "account switcher")"
            button.setAccessibilityLabel("Codex Profiles")
        }

        // Application-defined behavior keeps the automatic reveal visible while
        // this accessory app remains in the background. The click monitors below
        // preserve the usual click-away dismissal behavior.
        popover.behavior = .applicationDefined
        popover.contentSize = NSSize(width: 332, height: 430)
        popover.contentViewController = NSHostingController(rootView: MenuBarView(model: model, onSettings: onSettings))

        installDismissalMonitors()
        scheduleAutomaticPresentation()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            InteractionFeedback.shared.play()
            popover.performClose(sender)
        } else {
            presentPopover(activate: true, playSound: true)
        }
    }

    private func presentPopover(activate: Bool, playSound: Bool) {
        guard let button = statusItem.button, !popover.isShown else { return }
        if playSound { InteractionFeedback.shared.play() }
        model.prepareForPresentation()
        model.markPopoverOpened()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if activate { NSApp.activate(ignoringOtherApps: true) }
        Task { await model.open() }
    }

    private func scheduleAutomaticPresentation() {
        guard model.settings.openPanelAtLaunch else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.model.settings.openPanelAtLaunch, !self.popover.isShown else { return }
            self.presentPopover(activate: false, playSound: false)

            guard !self.popover.isShown else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.model.settings.openPanelAtLaunch, !self.popover.isShown else { return }
                self.presentPopover(activate: false, playSound: false)
            }
        }
    }

    private func installDismissalMonitors() {
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.dismissPopoverIfNeeded(at: NSEvent.mouseLocation)
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismissPopoverIfNeeded(at: NSEvent.mouseLocation)
            }
        }
    }

    private func dismissPopoverIfNeeded(at point: NSPoint) {
        guard popover.isShown else { return }
        let popoverFrame = popover.contentViewController?.view.window?.frame ?? .zero
        let statusFrame = statusItem.button?.window.map { window in
            window.convertToScreen(statusItem.button?.frame ?? .zero)
        } ?? .zero
        guard !popoverFrame.contains(point), !statusFrame.contains(point) else { return }
        popover.close()
    }
}

@MainActor
final class CodexProfilesAppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusBarController: StatusBarController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = AppModel()
        self.model = model
        settingsWindowController = SettingsWindowController(model: model)
        statusBarController = StatusBarController(model: model) { [weak self] in
            self?.settingsWindowController?.showSettings()
        }
    }
}

@main
struct CodexProfilesApp: App {
    @NSApplicationDelegateAdaptor(CodexProfilesAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
