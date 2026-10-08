import Foundation
import Testing
@testable import CodexBarCore

@Suite(CodexCredentialFixtures())
struct ManagedCodexFreshCredentialResolverTests {
    @Test
    func `resolver never falls back to credential-hydrating account loading`() throws {
        let fixture = try Self.fixture()
        let store = FallbackProbeStore(accounts: [fixture.account])
        let resolver = ManagedCodexAccountCredentialResolver(
            store: store,
            managedHomeRoot: fixture.root,
            now: { fixture.now },
            snapshotReader: { _ in Self.snapshot(fixture) })

        guard case .ready = resolver.resolve(accountID: fixture.account.id, minimumValidity: 0) else {
            Issue.record("Expected metadata-only account observation to resolve")
            return
        }
        #expect(store.hydratingReadCount == 0)
        #expect(store.metadataReadCount == 2)
    }

    @Test
    func `native snapshot diagnostics and reflection redact the bearer`() {
        let canary = "CA1_SECRET_CANARY_snapshot_diagnostics"
        let snapshot = NativeCodexAccessSnapshot(
            accessToken: canary,
            expiresAt: Date(timeIntervalSince1970: 1_700_003_600),
            nativeDefaultAccountID: "acct-synthetic")

        #expect(!snapshot.description.contains(canary))
        #expect(!snapshot.debugDescription.contains(canary))
        #expect(!String(describing: snapshot).contains(canary))
        #expect(!String(reflecting: snapshot).contains(canary))
        #expect(Array(snapshot.customMirror.children).isEmpty)
    }

    @Test
    func `resolver returns a redacted access-only credential for a stable fresh managed account`() throws {
        let fixture = try Self.fixture()
        let canary = "CA1_SECRET_CANARY_fresh_access"
        let resolver = Self.resolver(fixture: fixture) { _ in
            NativeCodexAccessSnapshot(
                accessToken: canary,
                expiresAt: fixture.now.addingTimeInterval(3600),
                nativeDefaultAccountID: fixture.account.effectiveWorkspaceAccountID)
        }

        let resolution = resolver.resolve(accountID: fixture.account.id, minimumValidity: 120)

        guard case let .ready(credential) = resolution else {
            Issue.record("Expected a fresh stable account to resolve")
            return
        }
        #expect(credential.expiresAt == fixture.now.addingTimeInterval(3600))
        if !credential.access.withAccessToken({ $0 == canary }) {
            Issue.record("Expected access projection to preserve the synthetic value")
        }
        #expect(!String(describing: credential).contains(canary))
        #expect(!String(reflecting: credential).contains(canary))
        #expect(!String(describing: credential.access).contains(canary))
        #expect(!String(reflecting: credential.access).contains(canary))
    }

    @Test
    func `resolver rejects an unknown managed account before reading a credential`() throws {
        let fixture = try Self.fixture()
        let resolver = Self.resolver(fixture: fixture) { _ in
            Issue.record("Unknown accounts must not read credentials")
            return Self.snapshot(fixture)
        }

        let resolution = resolver.resolve(accountID: UUID(), minimumValidity: 0)

        guard case .accountNotFound = resolution else {
            Issue.record("Expected unknown UUID to stay distinguishable")
            return
        }
    }

    @Test
    func `resolver rejects an account home outside its managed root`() throws {
        let fixture = try Self.fixture(homePath: CodexCredentialFixtures.root.path)
        let resolver = Self.resolver(fixture: fixture) { _ in
            Issue.record("Untrusted homes must not read credentials")
            return Self.snapshot(fixture)
        }

        let resolution = resolver.resolve(accountID: fixture.account.id, minimumValidity: 0)

        guard case let .unsupported(reason) = resolution else {
            Issue.record("Expected outside root to be unsupported")
            return
        }
        #expect(reason == .untrustedManagedHome)
    }

    @Test
    func `resolver rejects a managed home symlink`() throws {
        let root = CodexCredentialFixtures.root.appendingPathComponent("managed-homes", isDirectory: true)
        let realHome = root.appendingPathComponent("real-home", isDirectory: true)
        let linkedHome = root.appendingPathComponent("linked-home", isDirectory: true)
        try FileManager.default.createDirectory(at: realHome, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: realHome.appendingPathComponent("auth.json"))
        try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: realHome)
        let fixture = try Self.fixture(root: root, homePath: linkedHome.path)
        let resolver = Self.resolver(fixture: fixture) { _ in
            Issue.record("Symlink homes must not read credentials")
            return Self.snapshot(fixture)
        }

        let resolution = resolver.resolve(accountID: fixture.account.id, minimumValidity: 0)

        guard case let .unsupported(reason) = resolution else {
            Issue.record("Expected symlink home to be unsupported")
            return
        }
        #expect(reason == .untrustedManagedHome)
    }

    @Test
    func `resolver requires compatible native default workspace`() throws {
        let fixture = try Self.fixture()
        let resolver = Self.resolver(fixture: fixture) { _ in
            NativeCodexAccessSnapshot(
                accessToken: "synthetic-access",
                expiresAt: fixture.now.addingTimeInterval(3600),
                nativeDefaultAccountID: "acct-other")
        }

        let resolution = resolver.resolve(accountID: fixture.account.id, minimumValidity: 0)

        guard case let .unsupported(reason) = resolution else {
            Issue.record("Expected mismatched workspace to be unsupported")
            return
        }
        #expect(reason == .workspaceScope)
    }

    @Test
    func `resolver binds an account without explicit workspace selection to the native default`() throws {
        let fixture = try Self.fixture(workspaceAccountID: nil)
        let resolver = Self.resolver(fixture: fixture) { _ in
            NativeCodexAccessSnapshot(
                accessToken: "synthetic-access",
                expiresAt: fixture.now.addingTimeInterval(3600),
                nativeDefaultAccountID: "acct-native-default")
        }

        let resolution = resolver.resolve(accountID: fixture.account.id, minimumValidity: 0)

        guard case .ready = resolution else {
            Issue.record("An unscoped account should bind to the native default workspace")
            return
        }
    }

    @Test
    func `resolver refuses to bind when native workspace evidence is absent`() throws {
        let fixture = try Self.fixture(workspaceAccountID: nil)
        let resolver = Self.resolver(fixture: fixture) { _ in
            NativeCodexAccessSnapshot(
                accessToken: "synthetic-access",
                expiresAt: fixture.now.addingTimeInterval(3600),
                nativeDefaultAccountID: nil)
        }

        let resolution = resolver.resolve(accountID: fixture.account.id, minimumValidity: 0)

        guard case let .unsupported(reason) = resolution else {
            Issue.record("Missing native workspace evidence must not resolve")
            return
        }
        #expect(reason == .bindingEvidenceInsufficient)
    }

    @Test(arguments: ["missing", "directory", "malformed", "empty-access"])
    func `resolver fails closed for unavailable native credential material`(kind: String) throws {
        let fixture = try Self.fixture()
        switch kind {
        case "missing":
            try FileManager.default.removeItem(at: fixture.authURL)
        case "directory":
            try FileManager.default.removeItem(at: fixture.authURL)
            try FileManager.default.createDirectory(at: fixture.authURL, withIntermediateDirectories: false)
        case "malformed":
            try Data("{".utf8).write(to: fixture.authURL)
        default:
            try JSONSerialization.data(withJSONObject: [
                "tokens": ["access_token": "", "refresh_token": "synthetic-refresh"],
            ]).write(to: fixture.authURL)
        }
        let resolver = ManagedCodexAccountCredentialResolver(
            store: fixture.store,
            managedHomeRoot: fixture.root,
            now: { fixture.now })

        let resolution = resolver.resolve(accountID: fixture.account.id, minimumValidity: 0)

        guard case .temporarilyUnavailable = resolution else {
            Issue.record("Unavailable native material must not resolve or trigger renewal")
            return
        }
    }

    @Test
    func `resolver rejects an auth file symlink`() throws {
        let fixture = try Self.fixture()
        let target = fixture.root.appendingPathComponent("auth-target", isDirectory: false)
        try Data("{}".utf8).write(to: target)
        try FileManager.default.removeItem(at: fixture.authURL)
        try FileManager.default.createSymbolicLink(at: fixture.authURL, withDestinationURL: target)
        let resolver = Self.resolver(fixture: fixture) { _ in
            Issue.record("A symlink auth file must not be read")
            return Self.snapshot(fixture)
        }

        let resolution = resolver.resolve(accountID: fixture.account.id, minimumValidity: 0)

        guard case .temporarilyUnavailable = resolution else {
            Issue.record("Auth symlinks must fail closed")
            return
        }
    }

    @Test(arguments: [nil, -1.0, 120.0])
    func `resolver returns typed renewal outcomes for unavailable lifetime`(expirationOffset: TimeInterval?) throws {
        let fixture = try Self.fixture()
        let resolver = Self.resolver(fixture: fixture) { _ in
            NativeCodexAccessSnapshot(
                accessToken: "synthetic-access",
                expiresAt: expirationOffset.map { fixture.now.addingTimeInterval($0) },
                nativeDefaultAccountID: fixture.account.effectiveWorkspaceAccountID)
        }

        let resolution = resolver.resolve(accountID: fixture.account.id, minimumValidity: 120)

        guard case let .renewalRequired(reason) = resolution else {
            Issue.record("Expected unavailable lifetime to require renewal")
            return
        }
        switch expirationOffset {
        case nil: #expect(reason == .expiryUnknown)
        case let value? where value <= 0: #expect(reason == .expired)
        default: #expect(reason == .insufficientLifetime)
        }
    }

    @Test(arguments: [90.0, 90.001])
    func `resolver requires lifetime beyond the exact authority and skew boundary`(
        expirationOffset: TimeInterval) throws
    {
        let fixture = try Self.fixture()
        let resolver = Self.resolver(fixture: fixture) { _ in
            NativeCodexAccessSnapshot(
                accessToken: "synthetic-access",
                expiresAt: fixture.now.addingTimeInterval(expirationOffset),
                nativeDefaultAccountID: fixture.account.effectiveWorkspaceAccountID)
        }

        let resolution = resolver.resolve(accountID: fixture.account.id, minimumValidity: 0)
        if expirationOffset == 90 {
            guard case let .renewalRequired(reason) = resolution else {
                Issue.record("An exact boundary lifetime must not be returned")
                return
            }
            #expect(reason == .insufficientLifetime)
        } else if case .ready = resolution {
            // Expected: the resolver requires strictly more than the protected lifetime.
        } else {
            Issue.record("A lifetime beyond the protected boundary should resolve")
        }
    }

    @Test
    func `resolver applies the larger caller or authority minimum without overflow`() throws {
        let fixture = try Self.fixture()
        let resolver = Self.resolver(fixture: fixture) { _ in
            NativeCodexAccessSnapshot(
                accessToken: "synthetic-access",
                expiresAt: fixture.now.addingTimeInterval(200),
                nativeDefaultAccountID: fixture.account.effectiveWorkspaceAccountID)
        }

        guard case .ready = resolver.resolve(accountID: fixture.account.id, minimumValidity: 0) else {
            Issue.record("Authority minimum plus skew should accept sufficient lifetime")
            return
        }
        guard case let .renewalRequired(reason) = resolver.resolve(
            accountID: fixture.account.id,
            minimumValidity: 180)
        else {
            Issue.record("Caller minimum must dominate when larger")
            return
        }
        #expect(reason == .insufficientLifetime)
        guard case let .unsupported(reason) = resolver.resolve(
            accountID: fixture.account.id,
            minimumValidity: .greatestFiniteMagnitude)
        else {
            Issue.record("Overflowing minimum validity must fail closed")
            return
        }
        #expect(reason == .invalidMinimumValidity)
        guard case let .unsupported(negativeReason) = resolver.resolve(
            accountID: fixture.account.id,
            minimumValidity: -1)
        else {
            Issue.record("Negative minimum validity must fail closed")
            return
        }
        #expect(negativeReason == .invalidMinimumValidity)
        guard case let .unsupported(nanReason) = resolver.resolve(
            accountID: fixture.account.id,
            minimumValidity: .nan)
        else {
            Issue.record("Non-finite minimum validity must fail closed")
            return
        }
        #expect(nanReason == .invalidMinimumValidity)
    }

    @Test
    func `resolver rechecks the managed home after credential observation`() throws {
        let fixture = try Self.fixture()
        let replacement = fixture.root.appendingPathComponent("replacement-home", isDirectory: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: replacement.appendingPathComponent("auth.json"))
        let replacementAccount = ManagedCodexAccount(
            id: fixture.account.id,
            email: fixture.account.email,
            workspaceAccountID: fixture.account.effectiveWorkspaceAccountID,
            managedHomePath: replacement.path,
            createdAt: fixture.now.timeIntervalSince1970,
            updatedAt: fixture.now.timeIntervalSince1970 + 1,
            lastAuthenticatedAt: fixture.now.timeIntervalSince1970)
        let store = SequencedStore(observations: [[fixture.account], [replacementAccount]])
        let resolver = ManagedCodexAccountCredentialResolver(
            store: store,
            managedHomeRoot: fixture.root,
            policy: .init(authorityMinimumValidity: 60, clockSkew: 30),
            now: { fixture.now },
            snapshotReader: { _ in Self.snapshot(fixture) })

        let resolution = resolver.resolve(accountID: fixture.account.id, minimumValidity: 0)

        guard case let .temporarilyUnavailable(reason) = resolution else {
            Issue.record("A replacement home must prevent returning the earlier credential")
            return
        }
        #expect(reason == .accountChanged)
    }

    @Test
    func `resolver rejects metadata binding changes after a credential observation`() throws {
        let fixture = try Self.fixture()
        let changed = ManagedCodexAccount(
            id: fixture.account.id,
            email: "changed@example.com",
            workspaceAccountID: fixture.account.effectiveWorkspaceAccountID,
            managedHomePath: fixture.account.managedHomePath,
            createdAt: fixture.now.timeIntervalSince1970,
            updatedAt: fixture.now.timeIntervalSince1970 + 1,
            lastAuthenticatedAt: fixture.now.timeIntervalSince1970)
        let store = SequencedStore(observations: [[fixture.account], [changed]])
        let resolver = ManagedCodexAccountCredentialResolver(
            store: store,
            managedHomeRoot: fixture.root,
            now: { fixture.now },
            snapshotReader: { _ in Self.snapshot(fixture) })

        let resolution = resolver.resolve(accountID: fixture.account.id, minimumValidity: 0)

        guard case let .temporarilyUnavailable(reason) = resolution else {
            Issue.record("Changed metadata must invalidate the first observation")
            return
        }
        #expect(reason == .accountChanged)
    }

    @Test
    func `resolver classifies native OAuth and rejects a native API key without external fallback`() throws {
        let fixture = try Self.fixture()
        let access = Self.jwt(payload: ["exp": Int(fixture.now.timeIntervalSince1970 + 3600)])
        try Self.authData(access: access, accountID: fixture.account.effectiveWorkspaceAccountID)
            .write(to: fixture.authURL)
        let native = ManagedCodexAccountCredentialResolver(
            store: fixture.store,
            managedHomeRoot: fixture.root,
            policy: .init(authorityMinimumValidity: 60, clockSkew: 30),
            now: { fixture.now })

        guard case let .ready(credential) = native.resolve(accountID: fixture.account.id, minimumValidity: 0) else {
            Issue.record("Expected isolated native OAuth fixture to resolve")
            return
        }
        #expect(credential.access.withAccessToken { $0 } == access)

        try JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": "synthetic-api-key"])
            .write(to: fixture.authURL)
        let apiKeyResolution = native.resolve(accountID: fixture.account.id, minimumValidity: 0)
        guard case let .unsupported(reason) = apiKeyResolution else {
            Issue.record("Native API keys are outside the CA-1 OAuth contract")
            return
        }
        #expect(reason == .unsupportedCredentialSource)
    }

    private static func resolver(
        fixture: Fixture,
        snapshotReader: @escaping @Sendable (URL) throws -> NativeCodexAccessSnapshot)
        -> ManagedCodexAccountCredentialResolver
    {
        ManagedCodexAccountCredentialResolver(
            store: fixture.store,
            managedHomeRoot: fixture.root,
            policy: .init(authorityMinimumValidity: 60, clockSkew: 30),
            now: { fixture.now },
            snapshotReader: snapshotReader)
    }

    private static func snapshot(_ fixture: Fixture) -> NativeCodexAccessSnapshot {
        NativeCodexAccessSnapshot(
            accessToken: "synthetic-access",
            expiresAt: fixture.now.addingTimeInterval(3600),
            nativeDefaultAccountID: fixture.account.effectiveWorkspaceAccountID)
    }

    private static func fixture(
        root: URL? = nil,
        homePath: String? = nil,
        workspaceAccountID: String? = "acct-default") throws -> Fixture
    {
        let root = root ?? CodexCredentialFixtures.root
            .appendingPathComponent("managed-homes", isDirectory: true)
        let home = homePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? root.appendingPathComponent("managed-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let authURL = home.appendingPathComponent("auth.json")
        if !FileManager.default.fileExists(atPath: authURL.path) {
            try Data("{}".utf8).write(to: authURL)
        }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let account = ManagedCodexAccount(
            id: UUID(),
            email: "resolver@example.com",
            workspaceAccountID: workspaceAccountID,
            managedHomePath: home.path,
            createdAt: now.timeIntervalSince1970,
            updatedAt: now.timeIntervalSince1970,
            lastAuthenticatedAt: now.timeIntervalSince1970)
        return Fixture(
            root: root,
            now: now,
            account: account,
            authURL: authURL,
            store: InMemoryStore(accounts: [account]))
    }

    private static func authData(access: String, accountID: String?) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tokens": [
                "access_token": access,
                "refresh_token": "synthetic-refresh-not-returned",
                "account_id": accountID as Any,
            ],
        ])
    }

    private static func jwt(payload: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let body = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(body).signature"
    }

    private struct Fixture: @unchecked Sendable {
        let root: URL
        let now: Date
        let account: ManagedCodexAccount
        let authURL: URL
        let store: InMemoryStore
    }

    private final class FallbackProbeStore: ManagedCodexAccountStoring, ManagedCodexAccountMetadataLoading,
        @unchecked Sendable
    {
        let accounts: [ManagedCodexAccount]
        private(set) var hydratingReadCount = 0
        private(set) var metadataReadCount = 0

        init(accounts: [ManagedCodexAccount]) {
            self.accounts = accounts
        }

        func loadAccounts() throws -> ManagedCodexAccountSet {
            self.hydratingReadCount += 1
            return ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: self.accounts)
        }

        func loadAccountMetadata() throws -> ManagedCodexAccountSet {
            self.metadataReadCount += 1
            return ManagedCodexAccountSet(
                version: FileManagedCodexAccountStore.currentVersion,
                accounts: self.accounts)
        }

        func storeAccounts(_: ManagedCodexAccountSet) throws {
            Issue.record("A fresh resolver must not persist account metadata")
        }

        func ensureFileExists() throws -> URL {
            Issue.record("A fresh resolver must not create account metadata")
            return URL(fileURLWithPath: "/invalid")
        }
    }

    private final class InMemoryStore: ManagedCodexAccountMetadataLoading, @unchecked Sendable {
        let accounts: [ManagedCodexAccount]

        init(accounts: [ManagedCodexAccount]) {
            self.accounts = accounts
        }

        func loadAccountMetadata() throws -> ManagedCodexAccountSet {
            ManagedCodexAccountSet(version: FileManagedCodexAccountStore.currentVersion, accounts: self.accounts)
        }
    }

    private final class SequencedStore: ManagedCodexAccountMetadataLoading, @unchecked Sendable {
        private var observations: [[ManagedCodexAccount]]

        init(observations: [[ManagedCodexAccount]]) {
            self.observations = observations
        }

        func loadAccountMetadata() throws -> ManagedCodexAccountSet {
            let next = self.observations.removeFirst()
            return ManagedCodexAccountSet(version: FileManagedCodexAccountStore.currentVersion, accounts: next)
        }
    }
}
