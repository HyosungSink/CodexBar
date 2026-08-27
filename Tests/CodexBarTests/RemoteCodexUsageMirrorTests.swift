import Foundation
import Testing
@testable import CodexBarCore

struct RemoteCodexUsageMirrorTests {
    @Test
    func `discovers only connected and selected Codex remote hosts`() throws {
        let data = try #require(#"""
        {
          "codex-managed-remote-connections": [
            {"hostId":"remote-ssh-discovered:active", "alias":"active-alias"},
            {"hostId":"remote-ssh-discovered:selected", "alias":"selected-alias"},
            {"hostId":"remote-ssh-discovered:idle", "alias":"idle-alias"}
          ],
          "remote-projects": [
            {"id":"project-selected", "hostId":"remote-ssh-discovered:selected"}
          ],
          "remote-connection-auto-connect-by-host-id": {
            "remote-ssh-discovered:active": true,
            "remote-ssh-discovered:idle": false
          },
          "selected-project": {"type":"remote", "projectId":"project-selected"}
        }
        """#.data(using: .utf8))

        #expect(RemoteCodexUsageMirror.hosts(fromGlobalState: data) == ["active-alias", "selected-alias"])
    }

    @Test
    func `rsync plan transfers only rollout jsonl files over batch ssh`() {
        let destination = URL(fileURLWithPath: "/tmp/remote mirror/sessions", isDirectory: true)
        let arguments = RemoteCodexUsageMirror.rsyncArguments(
            ssh: "/usr/bin/ssh",
            host: "Star_Cup_Chen",
            destination: destination)

        #expect(arguments.contains("--inplace"))
        #expect(arguments.contains("--delete"))
        #expect(arguments.contains("--include=/sessions/***"))
        #expect(arguments.contains("--include=/archived_sessions/***"))
        #expect(arguments.contains("--exclude=*"))
        #expect(arguments.contains("/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=3"))
        #expect(arguments.contains("Star_Cup_Chen:.codex/"))
        #expect(arguments.last == "/tmp/remote mirror/sessions/")
    }

    @Test
    func `scanner includes native and additional session plus archive roots`() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let native = base.appendingPathComponent("native/sessions", isDirectory: true)
        let remote = base.appendingPathComponent("remote/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: native,
            codexAdditionalSessionsRoots: [remote])
        let roots = CostUsageScanner.codexSessionsRoots(options: options).map(\.standardizedFileURL.path)

        #expect(roots == [
            native.standardizedFileURL.path,
            native.deletingLastPathComponent().appendingPathComponent("archived_sessions").standardizedFileURL.path,
            remote.standardizedFileURL.path,
            remote.deletingLastPathComponent().appendingPathComponent("archived_sessions").standardizedFileURL.path,
        ])
    }

    @Test
    func `remote mirrored rollout contributes tokens to the native Codex report`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 27)
        let timestamp = env.isoString(for: day)
        let nativeEntries: [[String: Any]] = [
            [
                "type": "session_meta",
                "timestamp": timestamp,
                "payload": ["id": "native-session", "cwd": "/native/project"],
            ],
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-5.6-sol"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "token_count",
                "info": [
                    "model": "gpt-5.6-sol",
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 80,
                        "output_tokens": 10,
                    ],
                ],
            ]],
        ]
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "native.jsonl",
            contents: env.jsonl(nativeEntries))

        let remoteRoot = env.root.appendingPathComponent("remote/sessions", isDirectory: true)
        let remoteDay = remoteRoot.appendingPathComponent("2026/08/27", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDay, withIntermediateDirectories: true)
        let remoteEntries: [[String: Any]] = [
            [
                "type": "session_meta",
                "timestamp": timestamp,
                "payload": ["id": "remote-session", "cwd": "/remote/project"],
            ],
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-5.6-sol"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "token_count",
                "info": [
                    "model": "gpt-5.6-sol",
                    "total_token_usage": [
                        "input_tokens": 200,
                        "cached_input_tokens": 160,
                        "output_tokens": 20,
                    ],
                ],
            ]],
        ]
        try env.jsonl(remoteEntries).write(
            to: remoteDay.appendingPathComponent("remote.jsonl"),
            atomically: true,
            encoding: .utf8)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            codexAdditionalSessionsRoots: [remoteRoot],
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(report.summary?.totalTokens == 330)
        #expect(report.data.first?.inputTokens == 300)
        #expect(report.data.first?.outputTokens == 30)
        #expect(report.data.first?.cacheReadTokens == 240)
    }
}
