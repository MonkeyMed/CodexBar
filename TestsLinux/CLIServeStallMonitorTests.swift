import Commander
import Foundation
import Testing
@testable import CodexBarCLI

struct CLIServeStallMonitorTests {
    private final class StallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stalls: [TimeInterval] = []

        func record(_ stalledFor: TimeInterval) {
            self.lock.withLock { self.stalls.append(stalledFor) }
        }

        var count: Int {
            self.lock.withLock { self.stalls.count }
        }

        var isEmpty: Bool {
            self.lock.withLock { self.stalls.isEmpty }
        }
    }

    @Test
    func `reports a stall once heartbeats stop`() async {
        let recorder = StallRecorder()
        let monitor = CLIServeStallMonitor(stallThreshold: 0.2, checkInterval: 0.05) { recorder.record($0) }
        defer { monitor.stop() }

        monitor.startWatching()

        #expect(await Self.waitUntil { recorder.count == 1 })
    }

    @Test
    func `stays quiet while heartbeats keep arriving`() {
        let recorder = StallRecorder()
        let monitor = CLIServeStallMonitor(stallThreshold: 0.5, checkInterval: 0.05) { recorder.record($0) }
        defer { monitor.stop() }

        monitor.startWatching()
        // Beat from this thread so parallel tests that occupy the cooperative pool cannot delay the heartbeats.
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            monitor.heartbeat()
            Thread.sleep(forTimeInterval: 0.02)
        }

        #expect(recorder.isEmpty)
    }

    @Test
    func `stopped monitor does not report`() async throws {
        let recorder = StallRecorder()
        let monitor = CLIServeStallMonitor(stallThreshold: 0.2, checkInterval: 0.05) { recorder.record($0) }

        monitor.startWatching()
        monitor.stop()
        try await Task.sleep(for: .seconds(0.6))

        #expect(recorder.isEmpty)
    }

    @Test
    func `stall timeout is off unless requested`() {
        func decode(_ raw: String?) -> TimeInterval? {
            CodexBarCLI.decodeServeStallTimeout(from: ParsedValues(
                positional: [],
                options: raw.map { ["stallTimeout": [$0]] } ?? [:],
                flags: []))
        }

        #expect(decode(nil) == 0)
        #expect(decode("0") == 0)
        #expect(decode("120") == 120)
        #expect(decode("soon") == nil)
        #expect(decode("-1") == nil)
        #expect(decode("inf") == nil)
    }

    @Test
    func `check interval follows short thresholds`() {
        #expect(CLIServeStallMonitor.checkInterval(forThreshold: 120) == 5)
        #expect(CLIServeStallMonitor.checkInterval(forThreshold: 8) == 2)
    }

    @Test
    func `serve help documents the stall timeout option`() {
        let serve = CodexBarCLI.serveHelp(version: "0.0.0")

        #expect(serve.contains("--stall-timeout <seconds>"))
        #expect(serve.contains("off by"))
        #expect(CodexBarCLI.rootHelp(version: "0.0.0").contains("--stall-timeout <seconds>"))
    }

    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }
}
