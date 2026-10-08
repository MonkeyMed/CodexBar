import Foundation
import Testing
@testable import CodexBarCore

#if os(Linux)
@Suite(.serialized)
struct ProcessExitReleaseLinuxTests {
    private struct LaunchedChild {
        let isProcessAlive: () -> Bool
        let pipes: Set<String>
    }

    @Test
    func `RPC child teardown releases the process and its output pipes`() async throws {
        let child = try Self.launch(executable: "/bin/cat", arguments: []) { process, stdin in
            RPCChildProcessTeardown.terminate(process: process, stdin: stdin)
        }

        #expect(await Self.waitUntil { !child.isProcessAlive() }, "Process stayed alive after teardown")
        #expect(
            await Self.waitUntil { Self.openPipes().isDisjoint(with: child.pipes) },
            "Output pipe descriptors stayed open after teardown")
    }

    @Test
    func `process requested for release while running is released after it exits`() async throws {
        let child = try Self.launch(executable: "/bin/sleep", arguments: ["0.3"]) { process, stdin in
            #expect(process.isRunning)
            ProcessExitRelease.afterExit(process)
            stdin.close()
        }

        #expect(await Self.waitUntil { !child.isProcessAlive() }, "Process stayed alive after it exited")
        #expect(
            await Self.waitUntil { Self.openPipes().isDisjoint(with: child.pipes) },
            "Output pipe descriptors stayed open after the process exited")
    }

    /// Mirrors the RPC clients: the caller only keeps the pipes and process for the duration of `body`.
    private static func launch(
        executable: String,
        arguments: [String],
        body: (Process, RPCChildProcessInput) -> Void) throws -> LaunchedChild
    {
        let stdin = RPCChildProcessInput()
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = stdin.pipe
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let pipes = Set([stdout, stderr].compactMap { self.pipeName(of: $0.fileHandleForReading.fileDescriptor) })
        try #require(pipes.count == 2)
        body(process, stdin)
        return LaunchedChild(isProcessAlive: { [weak process] in process != nil }, pipes: pipes)
    }

    private static func pipeName(of fileDescriptor: Int32) -> String? {
        let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(fileDescriptor)")
        return target.flatMap { $0.hasPrefix("pipe:") ? $0 : nil }
    }

    private static func openPipes() -> Set<String> {
        let descriptors = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []
        return Set(descriptors.compactMap { Int32($0) }.compactMap(self.pipeName(of:)))
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
#endif
