import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Native behavior proof for the shared managed-home deletion guards.
///
/// These tests drive only production components on the path under test — the real
/// `FileManagedCodexAccountStore` (JSON document + flock on disk), the real
/// `ManagedCodexHomeFactory`, the real `ManagedCodexAccountService`, and the real
/// `CodexDisplacedLivePreservationExecutor` — against synthetic account homes.
/// No injected store, no Keychain, no network. Set CODEXBAR_SHARED_HOME_PROOF_DIR
/// to also write a JSON receipt of the observed filesystem/store state.
@Suite(.serialized, CodexCredentialFixtures())
@MainActor
struct CodexSharedHomeRetentionNativeProofTests {
    @Test
    func `real managed account removal preserves a home still referenced by a sibling record`() async throws {
        let container = try CodexAccountPromotionTestContainer(suiteName: "shared-home-removal-native-proof")
        defer { container.tearDown() }
        var receipt: [String: Any] = ["scenario": "removeManagedAccount"]

        let sibling = try container.createManagedAccount(
            persistedEmail: "sibling@example.com",
            authAccountID: "acct-sibling")
        let sharedHomeURL = URL(fileURLWithPath: sibling.managedHomePath, isDirectory: true)
        let removed = ManagedCodexAccount(
            id: UUID(),
            email: "removed@example.com",
            providerAccountID: "acct-removed",
            workspaceLabel: nil,
            workspaceAccountID: "acct-removed",
            authFingerprint: nil,
            managedHomePath: sibling.managedHomePath,
            createdAt: Date().timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970,
            lastAuthenticatedAt: Date().timeIntervalSince1970)
        try container.persistAccounts([removed, sibling])
        let authBefore = try container.managedAuthData(for: sibling)
        receipt["recordsBefore"] = ["removed@example.com", "sibling@example.com"]
        receipt["sharedHomePath"] = sharedHomeURL.path

        let service = ManagedCodexAccountService(
            store: container.fileStore,
            homeFactory: container.homeFactory,
            loginRunner: ProofManagedCodexLoginRunner(),
            identityReader: ProofManagedCodexIdentityReader(),
            workspaceResolver: ProofManagedCodexWorkspaceResolver(),
            workspaceSelector: ProofManagedCodexWorkspaceSelector())

        try await service.removeManagedAccount(id: removed.id)

        #expect(FileManager.default.fileExists(atPath: sharedHomeURL.path))
        #expect(try container.managedAuthData(for: sibling) == authBefore)
        let reloaded = try FileManagedCodexAccountStore(
            fileURL: container.managedStoreURL,
            fileManager: .default).loadAccounts()
        #expect(reloaded.accounts.map(\.id) == [sibling.id])
        receipt["afterFirstRemoval"] = [
            "sharedHomeExists": FileManager.default.fileExists(atPath: sharedHomeURL.path),
            "authBytesUnchanged": true,
            "remainingRecord": "sibling@example.com",
        ]

        // Removing the last record referencing the home must still release it.
        try await service.removeManagedAccount(id: sibling.id)
        #expect(FileManager.default.fileExists(atPath: sharedHomeURL.path) == false)
        receipt["afterLastRemoval"] = ["sharedHomeExists": false]

        Self.writeReceipt(receipt)
    }

    @Test
    func `real raced import repair preserves a home still referenced by a foreign-written record`() async throws {
        let container = try CodexAccountPromotionTestContainer(suiteName: "shared-home-race-native-proof")
        defer { container.tearDown() }
        var receipt: [String: Any] = ["scenario": "racedImportRepair"]

        let target = try container.createManagedAccount(
            persistedEmail: "beta@example.com",
            authAccountID: "acct-beta")
        try container.persistAccounts([target])
        let liveAuthData = try container.writeLiveOAuthAuthFile(
            email: "alpha@example.com",
            accountID: "acct-alpha")

        // A shared home holding alpha credentials, referenced by two foreign-written records:
        // the raced record matching the imported identity, plus an unrelated sibling record.
        let placeholder = try container.createManagedAccount(
            persistedEmail: "owner@example.com",
            authEmail: "alpha@example.com",
            authAccountID: "acct-alpha")
        let sharedHomeURL = URL(fileURLWithPath: placeholder.managedHomePath, isDirectory: true)
        let sharedAuthData = try container.managedAuthData(for: placeholder)
        let timestamp = Date().timeIntervalSince1970
        let raced = ManagedCodexAccount(
            id: UUID(),
            email: "alpha@example.com",
            providerAccountID: "acct-alpha",
            workspaceLabel: nil,
            workspaceAccountID: "acct-alpha",
            authFingerprint: CodexAuthFingerprint.fingerprint(data: sharedAuthData),
            managedHomePath: placeholder.managedHomePath,
            createdAt: timestamp,
            updatedAt: timestamp,
            lastAuthenticatedAt: timestamp)
        let sibling = ManagedCodexAccount(
            id: UUID(),
            email: "other@example.com",
            providerAccountID: "acct-other",
            workspaceLabel: nil,
            workspaceAccountID: "acct-other",
            authFingerprint: nil,
            managedHomePath: placeholder.managedHomePath,
            createdAt: timestamp,
            updatedAt: timestamp,
            lastAuthenticatedAt: timestamp)
        receipt["sharedHomePath"] = sharedHomeURL.path

        let builder = PreparedPromotionContextBuilder(
            store: container.fileStore,
            workspaceResolver: container.workspaceResolver,
            snapshotLoader: container.settings,
            authMaterialReader: DefaultCodexAuthMaterialReader(),
            baseEnvironment: container.baseEnvironment,
            fileManager: .default)
        let context = try await builder.build(targetID: target.id)

        // Foreign writer: a second real store instance commits the colliding records through
        // the same on-disk document (external Codex processes do not share ManagedCodexAccountLock).
        let foreignStore = FileManagedCodexAccountStore(
            fileURL: container.managedStoreURL,
            fileManager: .default)
        let foreignSet = try foreignStore.loadAccounts()
        try foreignStore.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: foreignSet.accounts + [raced, sibling]))
        receipt["foreignWrite"] = [
            "raced": "alpha@example.com/acct-alpha",
            "sibling": "other@example.com/acct-other",
        ]

        let executor = CodexDisplacedLivePreservationExecutor(
            store: container.fileStore,
            homeFactory: container.homeFactory,
            fileManager: .default)
        let result = try executor.execute(
            plan: .importNew(reason: .noExistingManagedDestination),
            context: context)

        #expect(result == .alreadyManaged(managedAccountID: raced.id))
        #expect(FileManager.default.fileExists(atPath: sharedHomeURL.path))
        let sharedAuthAfter = try Data(contentsOf: sharedHomeURL.appendingPathComponent("auth.json"))
        #expect(sharedAuthAfter == sharedAuthData)
        let reloaded = try foreignStore.loadAccounts().accounts
        #expect(reloaded.count == 3)
        #expect(reloaded.contains { $0.id == sibling.id && $0.managedHomePath == sharedHomeURL.path })
        let repaired = try #require(reloaded.first { $0.id == raced.id })
        #expect(repaired.managedHomePath != sharedHomeURL.path)
        #expect(try container.managedAuthData(for: repaired) == liveAuthData)
        receipt["outcome"] = [
            "disposition": "alreadyManaged",
            "sharedHomeExists": FileManager.default.fileExists(atPath: sharedHomeURL.path),
            "sharedAuthBytesUnchanged": sharedAuthAfter == sharedAuthData,
            "siblingRecordRetained": true,
            "racedRecordRewiredToFreshHome": repaired.managedHomePath != sharedHomeURL.path,
        ]

        Self.writeReceipt(receipt)
    }

    private static func writeReceipt(_ receipt: [String: Any]) {
        guard let directory = ProcessInfo.processInfo.environment["CODEXBAR_SHARED_HOME_PROOF_DIR"]
        else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        guard let scenario = receipt["scenario"] as? String,
              let data = try? JSONSerialization.data(
                  withJSONObject: receipt,
                  options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try? data.write(
            to: output.appendingPathComponent("\(scenario).json", isDirectory: false),
            options: .atomic)
    }
}

private struct ProofManagedCodexLoginRunner: ManagedCodexLoginRunning {
    func run(homePath _: String, timeout _: TimeInterval) async -> CLILoginRunner.Result {
        CLILoginRunner.Result(outcome: .success, output: "unused")
    }
}

private struct ProofManagedCodexIdentityReader: ManagedCodexIdentityReading {
    func loadAccountIdentity(homePath _: String) throws -> CodexAuthBackedAccount {
        CodexAuthBackedAccount(identity: .unresolved, email: nil, plan: nil)
    }
}

private struct ProofManagedCodexWorkspaceResolver: ManagedCodexWorkspaceResolving {
    func resolveWorkspaceIdentity(
        homePath _: String,
        providerAccountID _: String) async -> CodexOpenAIWorkspaceIdentity?
    {
        nil
    }

    func availableWorkspaceIdentities(homePath _: String) async -> [CodexOpenAIWorkspaceIdentity] {
        []
    }
}

private struct ProofManagedCodexWorkspaceSelector: ManagedCodexWorkspaceSelecting {
    func selectWorkspace(
        email _: String,
        currentWorkspaceID _: String?,
        workspaces _: [CodexOpenAIWorkspaceIdentity]) async -> CodexOpenAIWorkspaceIdentity?
    {
        nil
    }
}
