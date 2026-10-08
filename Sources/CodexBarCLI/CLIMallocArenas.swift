import Foundation
#if canImport(Glibc)
import Glibc

/// The Swift Glibc module does not import `<malloc.h>`.
@_silgen_name("mallopt")
private func glibcMallopt(_ parameter: Int32, _ value: Int32) -> Int32
private let glibcMallocArenaMaxParameter: Int32 = -8 // M_ARENA_MAX
#endif

extension CodexBarCLI {
    static let defaultGlibcMallocArenaLimit: Int32 = 2

    /// Explicit glibc tuning from the environment wins over the built-in limit.
    static func glibcMallocArenaLimit(environment: [String: String]) -> Int32? {
        if environment["MALLOC_ARENA_MAX"] != nil { return nil }
        if environment["GLIBC_TUNABLES"]?.contains("glibc.malloc.arena_max") == true { return nil }
        return self.defaultGlibcMallocArenaLimit
    }

    /// glibc creates up to eight malloc arenas per core, and each arena keeps the high-water mark of the transient
    /// allocations made on its threads. A long-running `codexbar serve` spreads its refresh work across short-lived
    /// worker threads, so its memory grew to several times what a single refresh needs. Call before any other
    /// thread allocates.
    static func configureGlibcMallocArenasIfNeeded() {
        #if canImport(Glibc)
        guard let limit = self.glibcMallocArenaLimit(environment: ProcessInfo.processInfo.environment) else { return }
        _ = glibcMallopt(glibcMallocArenaMaxParameter, limit)
        #endif
    }
}
