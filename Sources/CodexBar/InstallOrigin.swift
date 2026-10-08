import Foundation

enum InstallOrigin {
    static let caskroomURLs = [
        URL(fileURLWithPath: "/opt/homebrew/Caskroom"),
        URL(fileURLWithPath: "/usr/local/Caskroom"),
    ]

    static func isHomebrewCask(
        appBundleURL: URL,
        caskroomURLs: [URL] = Self.caskroomURLs) -> Bool
    {
        !self.homebrewPrefixes(appBundleURL: appBundleURL, caskroomURLs: caskroomURLs).isEmpty
    }

    static func homebrewPrefix(
        appBundleURL: URL,
        caskroomURLs: [URL] = Self.caskroomURLs) -> URL?
    {
        let prefixes = self.homebrewPrefixes(appBundleURL: appBundleURL, caskroomURLs: caskroomURLs)
        return prefixes.count == 1 ? prefixes[0] : nil
    }

    /// The tap recorded in the owning cask receipt, if determinable. Nil when the app is not a Homebrew
    /// cask install or the receipt cannot be read. `brew upgrade --cask codexbar` resolves through the
    /// same receipt, so the in-app updater is restricted to the tap that owns the install.
    static func homebrewCaskTap(
        appBundleURL: URL,
        caskroomURLs: [URL] = Self.caskroomURLs) -> String?
    {
        guard let prefix = self.homebrewPrefix(appBundleURL: appBundleURL, caskroomURLs: caskroomURLs) else {
            return nil
        }
        let metadata = prefix.appendingPathComponent("Caskroom/codexbar/.metadata")
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: metadata, includingPropertiesForKeys: nil) else { return nil }
        var receiptURLs: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "INSTALL_RECEIPT.json" {
            receiptURLs.append(url)
        }
        let receipt = receiptURLs.max { lhs, rhs in
            (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                < (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ??
                .distantPast
        }
        guard let receipt,
              let data = try? Data(contentsOf: receipt),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let source = json["source"] as? [String: Any],
              let tap = source["tap"] as? String, !tap.isEmpty
        else { return nil }
        return tap
    }

    private static func homebrewPrefixes(appBundleURL: URL, caskroomURLs: [URL]) -> [URL] {
        let resolved = appBundleURL.resolvingSymlinksInPath().standardizedFileURL
        var prefixes: [URL] = []
        let legacyCask = resolved.deletingLastPathComponent().deletingLastPathComponent()
        if resolved.lastPathComponent == "CodexBar.app", legacyCask.lastPathComponent == "codexbar",
           legacyCask.deletingLastPathComponent().lastPathComponent == "Caskroom"
        {
            prefixes.append(legacyCask.deletingLastPathComponent().deletingLastPathComponent())
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return prefixes
        }

        // Cask app artifacts are moved into the app directory. Homebrew leaves a symlink
        // in Caskroom pointing to the installed app, rather than the other way around.
        let linkedPrefixes = caskroomURLs.filter { caskroom in
            let caskURL = caskroom.appendingPathComponent("codexbar", isDirectory: true)
            guard let versions = try? fileManager.contentsOfDirectory(
                at: caskURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { return false }

            return versions.contains { version in
                let artifact = version.appendingPathComponent("CodexBar.app")
                return (try? fileManager.destinationOfSymbolicLink(atPath: artifact.path)) != nil &&
                    artifact.resolvingSymlinksInPath().standardizedFileURL == resolved
            }
        }.map { $0.deletingLastPathComponent() }
        return Array(Set((prefixes + linkedPrefixes).map { $0.resolvingSymlinksInPath().standardizedFileURL }))
    }
}
