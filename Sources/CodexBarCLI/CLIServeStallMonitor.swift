#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

/// Detects a stalled Swift concurrency executor from a thread the executor does not own.
///
/// Every request, refresh, and timeout in `codexbar serve` runs on the cooperative pool. When all of its threads
/// block, the accept loop keeps taking connections but nothing answers them, so the process looks alive to a
/// supervisor while every client gets a closed socket. Failing fast lets the supervisor restart the server, so
/// `serve` only starts the monitor when `--stall-timeout` asks for it.
final class CLIServeStallMonitor: @unchecked Sendable {
    static let maximumCheckInterval: TimeInterval = 5

    private let stallThreshold: TimeInterval
    private let checkInterval: TimeInterval
    private let onStall: @Sendable (TimeInterval) -> Void
    private let lock = NSLock()
    private var lastHeartbeat = DispatchTime.now()
    private var stopped = false
    private var heartbeatTask: Task<Void, Never>?

    /// Without an explicit `checkInterval`, heartbeats and checks run at least four times per threshold.
    init(
        stallThreshold: TimeInterval,
        checkInterval: TimeInterval? = nil,
        onStall: @escaping @Sendable (TimeInterval) -> Void = CLIServeStallMonitor.abortProcess)
    {
        self.stallThreshold = stallThreshold
        self.checkInterval = checkInterval ?? Self.checkInterval(forThreshold: stallThreshold)
        self.onStall = onStall
    }

    static func checkInterval(forThreshold stallThreshold: TimeInterval) -> TimeInterval {
        min(self.maximumCheckInterval, stallThreshold / 4)
    }

    func start() {
        let checkInterval = self.checkInterval
        let task = Task.detached { [weak self] in
            while !Task.isCancelled {
                self?.heartbeat()
                try? await Task.sleep(for: .seconds(checkInterval))
            }
        }
        self.lock.withLock { self.heartbeatTask = task }
        self.startWatching()
    }

    /// Starts only the watcher thread. Tests drive `heartbeat()` themselves to model a stalled executor.
    func startWatching() {
        self.heartbeat()
        let thread = Thread { [self] in self.watch() }
        thread.name = "CodexBar serve stall monitor"
        thread.start()
    }

    func heartbeat() {
        self.lock.withLock { self.lastHeartbeat = DispatchTime.now() }
    }

    func stop() {
        let task = self.lock.withLock {
            self.stopped = true
            return self.heartbeatTask
        }
        task?.cancel()
    }

    private func watch() {
        var lastCheck = DispatchTime.now()
        while true {
            Thread.sleep(forTimeInterval: self.checkInterval)
            let now = DispatchTime.now()
            // A watcher that overslept was frozen together with the executor (SIGSTOP, debugger, VM pause).
            // That is not a stall, so start measuring again from here.
            let wasFrozen = Self.seconds(from: lastCheck, to: now) > self.checkInterval * 3
            lastCheck = now

            let stalledFor: TimeInterval? = self.lock.withLock {
                if self.stopped { return nil }
                if wasFrozen { self.lastHeartbeat = now }
                return Self.seconds(from: self.lastHeartbeat, to: now)
            }
            guard let stalledFor else { return }
            if stalledFor >= self.stallThreshold {
                self.onStall(stalledFor)
                return
            }
        }
    }

    private static func seconds(from start: DispatchTime, to end: DispatchTime) -> TimeInterval {
        guard end.uptimeNanoseconds > start.uptimeNanoseconds else { return 0 }
        return TimeInterval(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// `abort()` rather than `exit()`: the crash report or core dump records where the executor threads are stuck.
    static func abortProcess(stalledFor: TimeInterval) {
        CodexBarCLI.writeStderr(
            "CodexBar server made no progress for \(Int(stalledFor)) seconds; "
                + "aborting so a supervisor can restart it.\n")
        abort()
    }
}
