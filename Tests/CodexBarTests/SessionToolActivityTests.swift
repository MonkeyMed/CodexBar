import Foundation
import Testing
@testable import CodexBarCore

struct SessionToolActivityTests {
    @Test
    func `native operations are owned deduplicated and distinct from orchestration`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = Self.record(id: "command", type: "CommandExecution", extra: ["exit_code": 1])
        let mcp = Self.record(id: "mcp", type: "McpToolCall", extra: [
            "server": "example", "tool": "read", "result": ["isError": true],
        ])
        let foreign = Self.record(id: "parent", type: "CommandExecution", owner: "parent")
        let modelCall: [String: Any] = [
            "type": "response_item", "payload": [
                "type": "function_call",
                "name": "exec",
                "call_id": "model",
            ],
        ]
        try fixture.write([command, command, mcp, foreign, modelCall])
        let snapshot = try await SessionToolActivityStore().load(source: fixture.source)
        #expect(snapshot.operations.count == 2)
        #expect(snapshot.operations.first { $0.id.itemID == "command" }?.outcome == .nonzeroExit)
        #expect(snapshot.operations.first { $0.id.itemID == "mcp" }?.outcome == .toolError)
        #expect(snapshot.operations.first { $0.id.itemID == "mcp" }?.name == "example/read")
        #expect(!snapshot.isPartial)
    }

    @Test
    func `a later terminal observation updates the same operation rather than counting twice`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([
            Self.record(id: "background", type: "CommandExecution", extra: ["status": "in_progress"]),
            Self.record(id: "background", type: "CommandExecution", extra: [
                "status": "completed", "exit_code": 0, "duration": ["secs": 15, "nanos": 0],
            ]),
        ])
        let snapshot = try await SessionToolActivityStore().load(source: fixture.source)
        #expect(snapshot.operations.count == 1)
        #expect(snapshot.operations.first?.outcome == .completed)
        #expect(snapshot.operations.first?.durationMilliseconds == 15000)
        #expect(snapshot.operations.first?.recordOffset != 0)
    }

    @Test
    func `large escaped output before metadata retains timing outcome and byte offsets`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let output = String(repeating: "quote\" slash\\ braces{} Unicode你好\n", count: 70000)
        // Explicit field order puts metadata after a multi-megabyte string, unlike a truncated
        // prefix reader.
        let encoded = try JSONSerialization.data(
            withJSONObject: [output],
            options: [.fragmentsAllowed])
        let string = try #require(String(bytes: encoded.dropFirst().dropLast(), encoding: .utf8))
        let line = """
        {"timestamp":"2026-05-10T12:00:00Z","type":"event_msg","payload":{"type":"item_completed",
        "thread_id":"owned","turn_id":"turn","item":{"type":"CommandExecution","id":"large",
        "aggregated_output":\(string),"command":["echo","example"],"exit_code":2,"status":"completed",
        "duration":{"secs":12,"nanos":500000000}}}}
        """.replacingOccurrences(of: "\n", with: "") + "\n"
        try Data(line.utf8).write(to: fixture.url)
        let store = SessionToolActivityStore()
        let snapshot = try await store.load(source: fixture.source)
        let operation = try #require(snapshot.operations.first)
        #expect(operation.durationMilliseconds == 12500)
        #expect(operation.timing == .native)
        #expect(operation.outcome == .nonzeroExit)
        #expect(operation.recordOffset == 0)
        #expect(operation.recordLength == line.utf8.count)
        #expect(!snapshot.isPartial)
        let details = try await store.details(operation: operation, snapshot: snapshot)
        #expect(details.input == "echo example")
        #expect(details.output?.hasPrefix("quote\" slash\\ braces{} Unicode你好") == true)
        #expect(details.isTruncated)
    }

    @Test
    func `oversized detail records expose a labeled bounded raw preview`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([Self.record(id: "huge", type: "CommandExecution", extra: [
            "command": ["echo", "synthetic"], "exit_code": 0,
            "aggregated_output": String(repeating: "你好", count: 800_000),
        ])])
        let store = SessionToolActivityStore()
        let snapshot = try await store.load(source: fixture.source)
        let operation = try #require(snapshot.operations.first)
        let details = try await store.details(operation: operation, snapshot: snapshot)
        #expect(details.outputIsRawRecord && details.isTruncated)
        #expect(details.input == "echo synthetic")
        #expect(details.output?.hasPrefix("{") == true)
        #expect((details.output?.utf8.count ?? 0) <= 32771)
        #expect(operation.recordLength > 4 * 1024 * 1024)
    }

    @Test
    func `duration validation distinguishes zero missing booleans and recorded intervals`() {
        #expect(SessionToolActivityParser.duration(["secs": 0, "nanos": 0]) == 0)
        #expect(SessionToolActivityParser.duration(["secs": 1, "nanos": 250_000_000]) == 1250)
        #expect(SessionToolActivityParser.duration(["secs": true, "nanos": 0]) == nil)
        #expect(SessionToolActivityParser.duration(["secs": -1, "nanos": 0]) == nil)
        #expect(SessionToolActivityParser.duration(["secs": 1, "nanos": 1_000_000_000]) == nil)
        #expect(SessionToolActivityParser.duration(["secs": 1.5, "nanos": 0]) == nil)
        #expect(SessionToolActivityParser.duration(["secs": "1", "nanos": 0]) == nil)
        #expect(SessionToolActivityParser.duration(["secs": Int.max, "nanos": 0]) == nil)
        #expect(SessionToolActivityParser.interval(["started_at_ms": 1, "completed_at_ms": 1]) == 0)
        #expect(SessionToolActivityParser
            .interval(["started_at_ms": 0, "completed_at_ms": 0]) == nil)
        #expect(SessionToolActivityParser
            .interval(["started_at_ms": 10, "completed_at_ms": 9]) == nil)
    }

    @Test
    func `parallel durations are independent and missing results are unknown`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = Self.record(id: "one", type: "FileChange", extra: [:])
        let second = Self.record(id: "two", type: "DynamicToolCall", extra: ["tool": "example"])
        let failed = Self.record(id: "failed", type: "CommandExecution", extra: ["status": "failed"])
        try fixture.write([first, second, failed])
        let snapshot = try await SessionToolActivityStore().load(source: fixture.source)
        #expect(snapshot.operations.count == 3)
        let unknown = snapshot.operations.filter { $0.id.itemID != "failed" }
        #expect(unknown.allSatisfy { $0.durationMilliseconds == nil && $0.outcome == .unknown })
        #expect(unknown.allSatisfy { !$0.needsAttention && !$0.isSlow })
        #expect(snapshot.operations.first { $0.id.itemID == "failed" }?.outcome == .toolError)
        #expect(snapshot
            .operations(in: Date(timeIntervalSince1970: 0)..<Date(timeIntervalSince1970: 1))
            .isEmpty)
    }

    @Test
    func `native timing wins over interval and incomplete trailing records are reported`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var record = Self.record(id: "timed", type: "CommandExecution", extra: [
            "duration": ["secs": 3, "nanos": 0], "exit_code": 0,
        ])
        var payload = try #require(record["payload"] as? [String: Any])
        payload["started_at_ms"] = 1000
        payload["completed_at_ms"] = 9000
        record["payload"] = payload
        try fixture.write([record])
        let handle = try FileHandle(forWritingTo: fixture.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"payload\":".utf8))
        try handle.close()
        let snapshot = try await SessionToolActivityStore().load(source: fixture.source)
        #expect(snapshot.operations.first?.durationMilliseconds == 3000)
        #expect(snapshot.operations.first?.timing == .native)
        #expect(snapshot.isPartial)
    }

    @Test
    func `append invalidates cache and rejects stale detail offsets`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([Self.record(
            id: "first",
            type: "CommandExecution",
            extra: ["exit_code": 0])])
        let store = SessionToolActivityStore()
        let first = try await store.load(source: fixture.source)
        #expect(try await store.load(source: fixture.source) == first)
        try fixture.write([
            Self.record(id: "first", type: "CommandExecution", extra: ["exit_code": 0]),
            Self.record(id: "second", type: "CommandExecution", extra: ["exit_code": 0]),
        ])
        await #expect(throws: SessionToolActivityError.sourceChanged) {
            try await store.details(operation: #require(first.operations.first), snapshot: first)
        }
        let second = try await store.load(source: fixture.source)
        #expect(second.operations.count == 2)
    }

    @Test
    func `declines namespaces turn identities and malformed lines remain distinguishable`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var otherTurn = Self.record(id: "same", type: "McpToolCall", extra: [
            "server": "other", "tool": "read", "status": "declined",
        ])
        var payload = try #require(otherTurn["payload"] as? [String: Any])
        payload["turn_id"] = "other-turn"
        otherTurn["payload"] = payload
        try fixture.write([
            Self.record(id: "same", type: "McpToolCall", extra: ["server": "one", "tool": "read"]),
            otherTurn,
        ])
        let handle = try FileHandle(forWritingTo: fixture.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{invalid}\n".utf8))
        try handle.close()
        let snapshot = try await SessionToolActivityStore().load(source: fixture.source)
        #expect(snapshot.operations.count == 2)
        #expect(snapshot.operations.filter { $0.outcome == .declined }.count == 1)
        #expect(snapshot.ignoredRecordCount == 1)
        #expect(snapshot.isPartial)
    }

    @Test
    func `nested MCP content does not obscure errors and numeric booleans stay unknown`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([
            Self.record(id: "large-mcp", type: "McpToolCall", extra: [
                "server": "one", "tool": "image",
                "arguments": ["input": String(repeating: "input", count: 50000)],
                "result": [
                    "content": [["type": "image", "data": String(repeating: "a", count: 2_000_000)]],
                    "isError": true,
                ],
                "duration": ["secs": 1, "nanos": 5],
            ]),
            Self.record(id: "numeric", type: "DynamicToolCall", extra: ["success": 0]),
        ])
        let snapshot = try await SessionToolActivityStore().load(source: fixture.source)
        #expect(snapshot.operations.count == 2)
        #expect(snapshot.operations.first { $0.id.itemID == "large-mcp" }?.outcome == .toolError)
        #expect(snapshot.operations.first { $0.id.itemID == "large-mcp" }?.durationMilliseconds == 1000.000005)
        #expect(snapshot.operations.first { $0.id.itemID == "numeric" }?.outcome == .unknown)
        #expect(!snapshot.isPartial)
    }

    @Test
    func `replacement and completed tails rebuild the index without stale operations`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let record = Self.record(id: "tail", type: "CommandExecution", extra: ["exit_code": 0])
        let bytes = try JSONSerialization.data(withJSONObject: record)
        try bytes.write(to: fixture.url)
        let store = SessionToolActivityStore()
        let incomplete = try await store.load(source: fixture.source)
        #expect(incomplete.operations.isEmpty && incomplete.isPartial)
        let handle = try FileHandle(forWritingTo: fixture.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([10]))
        try handle.close()
        let complete = try await store.load(source: fixture.source)
        #expect(complete.operations.count == 1 && !complete.isPartial)
        try fixture.write([Self.record(id: "new", type: "CommandExecution", extra: ["exit_code": 0])])
        let replaced = try await store.load(source: fixture.source)
        #expect(replaced.operations.map(\.id.itemID) == ["new"])
        await #expect(throws: SessionToolActivityError.sourceChanged) {
            try await store.details(operation: #require(complete.operations.first), snapshot: complete)
        }
    }

    @Test
    func `missing native identity or time marks partial coverage without assigning foreign history`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var missing = Self.record(id: "missing-time", type: "CommandExecution")
        missing.removeValue(forKey: "timestamp")
        var unowned = Self.record(id: "unowned", type: "McpToolCall")
        var payload = try #require(unowned["payload"] as? [String: Any])
        payload.removeValue(forKey: "thread_id")
        unowned["payload"] = payload
        try fixture.write([missing, unowned, Self.record(id: "parent", type: "CommandExecution", owner: "parent")])
        let snapshot = try await SessionToolActivityStore().load(source: fixture.source)
        #expect(snapshot.operations.isEmpty)
        #expect(snapshot.ignoredRecordCount == 2)
        #expect(snapshot.isPartial)
    }

    @Test
    func `projection bounds nesting and rejects unsupported metadata size`() {
        var deep = SessionToolJSONProjection()
        for byte in String(repeating: "{\"payload\":", count: 100).utf8 {
            deep.consume(byte)
        }
        #expect(deep.invalid)
        #expect(deep.finish() == nil)
        var large = SessionToolJSONProjection()
        let json = "{\"command\":[" + Array(repeating: "\"small\"", count: 30000).joined(separator: ",") + "]}"
        for byte in json.utf8 {
            large.consume(byte)
        }
        #expect(large.overflowed)
        #expect(large.finish() == nil)
    }

    @Test
    func `cancelled load does not scan or publish a snapshot`() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write([])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SessionToolActivityStore().load(source: fixture.source)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    private static func record(
        id: String,
        type: String,
        owner: String = "owned",
        extra: [String: Any] = [:]) -> [String: Any]
    {
        var item: [String: Any] = ["type": type, "id": id]
        item.merge(extra) { _, new in new }
        return [
            "timestamp": "2026-05-10T12:00:00Z", "type": "event_msg",
            "payload": [
                "type": "item_completed",
                "thread_id": owner,
                "turn_id": "turn",
                "item": item,
            ],
        ]
    }

    private struct Fixture {
        let root: URL
        var url: URL {
            self.root.appendingPathComponent("rollout.jsonl")
        }

        var source: SessionToolActivitySource {
            .init(fileURL: self.url, sessionID: "owned")
        }

        init() throws {
            self.root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(
                at: self.root,
                withIntermediateDirectories: true)
        }

        func write(_ records: [[String: Any]]) throws {
            var bytes = Data()
            for record in records {
                try bytes.append(JSONSerialization.data(
                    withJSONObject: record,
                    options: [.sortedKeys]))
                bytes.append(10)
            }
            try bytes.write(to: self.url, options: [.atomic])
        }

        func remove() { try? FileManager.default.removeItem(at: self.root) }
    }
}
