import Foundation

/// A deliberately access-only view of a native Codex OAuth credential.
///
/// This type does not promise secure memory or zeroization. It prevents accidental serialization,
/// reflection, diagnostics, and equality-based handling of the bearer value at this boundary.
public struct EphemeralAccessCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    private let accessToken: String

    init(accessToken: String) {
        self.accessToken = accessToken
    }

    public var description: String {
        "EphemeralAccessCredential(redacted)"
    }

    public var debugDescription: String {
        self.description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [(label: String?, value: Any)]())
    }

    /// Limit the bearer value's exposure to the immediate caller that must construct an authorized request.
    public func withAccessToken<Result>(_ body: (String) throws -> Result) rethrows -> Result {
        try body(self.accessToken)
    }
}

public struct ManagedCodexAccessCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public let access: EphemeralAccessCredential
    public let expiresAt: Date

    public var description: String {
        "ManagedCodexAccessCredential(redacted, expiresAt: \(self.expiresAt))"
    }

    public var debugDescription: String {
        self.description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [(label: String?, value: Any)]())
    }
}

struct NativeCodexAccessSnapshot: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let accessToken: String
    let expiresAt: Date?
    let nativeDefaultAccountID: String?
    let nativeOwnerEmail: String?

    var description: String {
        "NativeCodexAccessSnapshot(redacted)"
    }

    var debugDescription: String {
        self.description
    }

    var customMirror: Mirror {
        Mirror(self, children: [(label: String?, value: Any)]())
    }

    static func read(home: URL) throws -> Self {
        let credentials = try CodexOAuthCredentialsStore.load(env: ["CODEX_HOME": home.path])
        guard credentials.source == .codexHome, !credentials.isAPIKey else {
            throw NativeCodexAccessSnapshotError.unsupportedCredential
        }
        return Self(
            accessToken: credentials.accessToken,
            expiresAt: credentials.expiresAt,
            nativeDefaultAccountID: credentials.accountId,
            nativeOwnerEmail: CodexNativeCredentialOwnerIdentity.normalizedEmail(
                fromIDToken: credentials.idToken))
    }
}

private enum NativeCodexAccessSnapshotError: Error {
    case unsupportedCredential
}

public enum ManagedCodexCredentialRenewalReason: String, Equatable, Sendable {
    case expiryUnknown
    case expired
    case insufficientLifetime
}

public enum ManagedCodexCredentialTemporaryReason: String, Equatable, Sendable {
    case credentialUnavailable
    case credentialUnreadable
    case accountChanged
}

public enum ManagedCodexCredentialUnsupportedReason: String, Equatable, Sendable {
    case untrustedManagedHome
    case unsupportedCredentialSource
    case workspaceScope
    case bindingEvidenceInsufficient
    case invalidMinimumValidity
}

public enum ManagedCodexCredentialResolution: Sendable {
    case ready(ManagedCodexAccessCredential)
    case renewalRequired(ManagedCodexCredentialRenewalReason)
    case temporarilyUnavailable(ManagedCodexCredentialTemporaryReason)
    /// Reserved for a future caller-directed reauthentication flow; the fresh-only resolver does not emit this state.
    case reauthRequired
    case accountNotFound
    case unsupported(ManagedCodexCredentialUnsupportedReason)
}

public struct ManagedCodexCredentialResolverPolicy: Sendable {
    /// A request larger than one day cannot be satisfied safely by this fresh-only resolver.
    public static let maximumMinimumValidity: TimeInterval = 24 * 60 * 60
    public let authorityMinimumValidity: TimeInterval
    public let clockSkew: TimeInterval

    public init(authorityMinimumValidity: TimeInterval = 60, clockSkew: TimeInterval = 30) {
        self.authorityMinimumValidity = authorityMinimumValidity
        self.clockSkew = clockSkew
    }
}

/// Read-only resolver for native OAuth credentials owned by a managed Codex home.
///
/// It never starts Codex, refreshes tokens, writes auth files, or retains a credential cache.
public struct ManagedCodexAccountCredentialResolver: Sendable {
    private let store: any ManagedCodexAccountMetadataLoading
    private let managedHomeRoot: URL
    private let policy: ManagedCodexCredentialResolverPolicy
    private let now: @Sendable () -> Date
    private let snapshotReader: @Sendable (URL) throws -> NativeCodexAccessSnapshot

    public init(
        store: any ManagedCodexAccountMetadataLoading,
        managedHomeRoot: URL,
        policy: ManagedCodexCredentialResolverPolicy = .init(),
        now: @escaping @Sendable () -> Date = Date.init)
    {
        self.init(
            store: store,
            managedHomeRoot: managedHomeRoot,
            policy: policy,
            now: now,
            snapshotReader: NativeCodexAccessSnapshot.read)
    }

    init(
        store: any ManagedCodexAccountMetadataLoading,
        managedHomeRoot: URL,
        policy: ManagedCodexCredentialResolverPolicy = .init(),
        now: @escaping @Sendable () -> Date = Date.init,
        snapshotReader: @escaping @Sendable (URL) throws -> NativeCodexAccessSnapshot)
    {
        self.store = store
        self.managedHomeRoot = managedHomeRoot
        self.policy = policy
        self.now = now
        self.snapshotReader = snapshotReader
    }

    public func resolve(accountID: UUID, minimumValidity: TimeInterval) -> ManagedCodexCredentialResolution {
        guard let requiredLifetime = self.requiredLifetime(minimumValidity) else {
            return .unsupported(.invalidMinimumValidity)
        }
        let first: ManagedCodexAccount
        do {
            guard let account = try self.store.loadAccountMetadata().account(id: accountID) else {
                return .accountNotFound
            }
            first = account
        } catch {
            return .temporarilyUnavailable(.credentialUnavailable)
        }
        guard let home = self.trustedHome(for: first) else {
            return .unsupported(.untrustedManagedHome)
        }
        guard self.isUsableAuthFile(at: home.appendingPathComponent("auth.json", isDirectory: false)) else {
            return .temporarilyUnavailable(.credentialUnavailable)
        }

        let snapshot: NativeCodexAccessSnapshot
        do {
            snapshot = try self.snapshotReader(home)
        } catch is NativeCodexAccessSnapshotError {
            return .unsupported(.unsupportedCredentialSource)
        } catch let error as CodexOAuthCredentialsError {
            switch error {
            case .notFound, .unreadable, .decodeFailed, .missingTokens:
                return .temporarilyUnavailable(.credentialUnreadable)
            case .nativeRefreshRequired, .readOnlySource:
                return .unsupported(.unsupportedCredentialSource)
            }
        } catch {
            return .temporarilyUnavailable(.credentialUnreadable)
        }

        guard !snapshot.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .temporarilyUnavailable(.credentialUnreadable)
        }
        guard self.isOwnerCompatible(account: first, snapshot: snapshot) else {
            return .unsupported(.bindingEvidenceInsufficient)
        }
        guard self.isWorkspaceCompatible(account: first, snapshot: snapshot) else {
            return first.effectiveWorkspaceAccountID == nil
                ? .unsupported(.bindingEvidenceInsufficient)
                : .unsupported(.workspaceScope)
        }
        guard let expiry = snapshot.expiresAt else {
            return .renewalRequired(.expiryUnknown)
        }
        let remaining = expiry.timeIntervalSince(self.now())
        if remaining <= 0 {
            return .renewalRequired(.expired)
        }
        guard remaining > requiredLifetime else {
            return .renewalRequired(.insufficientLifetime)
        }

        do {
            guard let second = try self.store.loadAccountMetadata().account(id: accountID) else {
                return .temporarilyUnavailable(.accountChanged)
            }
            guard self.observationIdentity(of: first) == self.observationIdentity(of: second) else {
                return .temporarilyUnavailable(.accountChanged)
            }
        } catch {
            return .temporarilyUnavailable(.accountChanged)
        }

        return .ready(ManagedCodexAccessCredential(
            access: EphemeralAccessCredential(accessToken: snapshot.accessToken),
            expiresAt: expiry))
    }

    private func requiredLifetime(_ callerMinimum: TimeInterval) -> TimeInterval? {
        guard callerMinimum.isFinite, callerMinimum >= 0,
              callerMinimum <= ManagedCodexCredentialResolverPolicy.maximumMinimumValidity,
              self.policy.authorityMinimumValidity.isFinite,
              self.policy.authorityMinimumValidity >= 0,
              self.policy.authorityMinimumValidity
              <= ManagedCodexCredentialResolverPolicy.maximumMinimumValidity,
              self.policy.clockSkew.isFinite, self.policy.clockSkew >= 0
        else {
            return nil
        }
        let minimum = max(callerMinimum, self.policy.authorityMinimumValidity)
        guard minimum <= TimeInterval.greatestFiniteMagnitude - self.policy.clockSkew else {
            return nil
        }
        return minimum + self.policy.clockSkew
    }

    private func isOwnerCompatible(account: ManagedCodexAccount, snapshot: NativeCodexAccessSnapshot) -> Bool {
        guard let selected = CodexIdentityResolver.normalizeEmail(account.email),
              let native = snapshot.nativeOwnerEmail
        else { return false }
        return selected == native
    }

    private func isWorkspaceCompatible(account: ManagedCodexAccount, snapshot: NativeCodexAccessSnapshot) -> Bool {
        guard let native = Self.normalizeAccountID(snapshot.nativeDefaultAccountID) else { return false }
        guard let selected = account.effectiveWorkspaceAccountID else { return true }
        return selected == native
    }

    private func trustedHome(for account: ManagedCodexAccount) -> URL? {
        let lexicalRoot = self.managedHomeRoot.standardizedFileURL
        let lexicalHome = URL(fileURLWithPath: account.managedHomePath, isDirectory: true).standardizedFileURL
        guard Self.isDescendant(lexicalHome, of: lexicalRoot) else { return nil }

        let canonicalRoot = lexicalRoot.resolvingSymlinksInPath().standardizedFileURL
        let canonicalHome = lexicalHome.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isDescendant(canonicalHome, of: canonicalRoot),
              self.isDirectory(canonicalRoot), self.isDirectory(canonicalHome),
              self.hasNoSymlinkComponents(from: lexicalRoot, to: lexicalHome)
        else {
            return nil
        }
        return canonicalHome
    }

    private func isUsableAuthFile(at url: URL) -> Bool {
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else {
            return false
        }
        return true
    }

    private func isDirectory(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

    private func hasNoSymlinkComponents(from root: URL, to home: URL) -> Bool {
        let rootComponents = root.pathComponents
        let homeComponents = home.pathComponents
        guard homeComponents.starts(with: rootComponents) else { return false }
        var component = root
        for name in homeComponents.dropFirst(rootComponents.count) {
            component.appendPathComponent(name, isDirectory: true)
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: component.path)) == nil,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: component.path),
                  attributes[.type] as? FileAttributeType != .typeSymbolicLink
            else {
                return false
            }
        }
        return true
    }

    private func observationIdentity(of account: ManagedCodexAccount) -> ObservationIdentity {
        ObservationIdentity(
            accountID: account.id,
            email: account.email,
            workspaceAccountID: account.effectiveWorkspaceAccountID,
            canonicalHomePath: URL(fileURLWithPath: account.managedHomePath, isDirectory: true)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path)
    }

    private static func isDescendant(_ candidate: URL, of parent: URL) -> Bool {
        let parentComponents = parent.pathComponents
        let candidateComponents = candidate.pathComponents
        return candidateComponents.count > parentComponents.count && candidateComponents.starts(with: parentComponents)
    }

    private static func normalizeAccountID(_ value: String?) -> String? {
        ManagedCodexAccount.normalizeWorkspaceAccountID(value)
    }

    private struct ObservationIdentity: Equatable {
        let accountID: UUID
        let email: String
        let workspaceAccountID: String?
        let canonicalHomePath: String
    }
}
