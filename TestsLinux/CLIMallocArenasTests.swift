import Foundation
import Testing
@testable import CodexBarCLI

struct CLIMallocArenasTests {
    @Test
    func `malloc arena limit applies when glibc is not tuned explicitly`() {
        #expect(CodexBarCLI.glibcMallocArenaLimit(environment: [:]) == CodexBarCLI.defaultGlibcMallocArenaLimit)
        #expect(CodexBarCLI.glibcMallocArenaLimit(environment: ["GLIBC_TUNABLES": "glibc.malloc.tcache_count=0"])
            == CodexBarCLI.defaultGlibcMallocArenaLimit)
    }

    @Test
    func `explicit glibc arena tuning is left alone`() {
        #expect(CodexBarCLI.glibcMallocArenaLimit(environment: ["MALLOC_ARENA_MAX": "8"]) == nil)
        #expect(CodexBarCLI.glibcMallocArenaLimit(environment: ["GLIBC_TUNABLES": "glibc.malloc.arena_max=4"]) == nil)
    }

    private final class TrimCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var trims = 0

        func increment() {
            self.lock.withLock { self.trims += 1 }
        }

        var count: Int {
            self.lock.withLock { self.trims }
        }
    }

    @Test
    func `heap trimmer trims repeatedly until stopped`() async throws {
        let counter = TrimCounter()
        let trimmer = CLIServeHeapTrimmer(interval: 0.05) { counter.increment() }

        trimmer.start()
        let deadline = ContinuousClock.now + .seconds(10)
        while counter.count < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        trimmer.stop()
        #expect(counter.count >= 3)

        try await Task.sleep(for: .milliseconds(150))
        let countAfterStop = counter.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(counter.count == countAfterStop)
    }

    @Test
    func `heap trimmer without a trim function stays idle`() {
        let trimmer = CLIServeHeapTrimmer(interval: 0.01, trim: nil)
        trimmer.start()
        trimmer.stop()
    }
}
