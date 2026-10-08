import Foundation
#if canImport(Glibc)
import Glibc

/// The Swift Glibc module does not import `<malloc.h>`.
@_silgen_name("mallopt")
private func glibcMallopt(_ parameter: Int32, _ value: Int32) -> Int32
private let glibcMallocArenaMaxParameter: Int32 = -8 // M_ARENA_MAX

@_silgen_name("malloc_trim")
private func glibcMallocTrim(_ pad: Int) -> Int32
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

/// Hands free heap pages back to the kernel while `codexbar serve` runs.
///
/// A refresh briefly needs a few hundred megabytes for provider output and usage logs. glibc keeps most of that
/// in its heaps after the memory is freed, so an idle server stayed near its peak instead of its working set.
final class CLIServeHeapTrimmer: @unchecked Sendable {
    static let defaultInterval: TimeInterval = 30

    private let interval: TimeInterval
    private let trim: (@Sendable () -> Void)?
    private let queue = DispatchQueue(label: "com.steipete.codexbar.serve.heap-trimmer", qos: .utility)
    private let lock = NSLock()
    private var timer: (any DispatchSourceTimer)?

    /// `trim` defaults to glibc's `malloc_trim`; without glibc there is nothing to trim and `start()` does nothing.
    init(
        interval: TimeInterval = CLIServeHeapTrimmer.defaultInterval,
        trim: (@Sendable () -> Void)? = CLIServeHeapTrimmer.glibcTrim)
    {
        self.interval = interval
        self.trim = trim
    }

    func start() {
        guard let trim = self.trim else { return }
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + self.interval, repeating: self.interval)
        timer.setEventHandler { trim() }
        self.lock.withLock {
            self.timer?.cancel()
            self.timer = timer
        }
        timer.resume()
    }

    func stop() {
        self.lock.withLock {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    static var glibcTrim: (@Sendable () -> Void)? {
        #if canImport(Glibc)
        return { _ = glibcMallocTrim(0) }
        #else
        return nil
        #endif
    }
}
