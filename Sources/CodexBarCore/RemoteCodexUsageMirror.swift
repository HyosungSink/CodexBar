import Foundation

/// Mirrors rollout JSONL files from Codex Desktop's currently connected SSH hosts.
///
/// The mirror deliberately excludes every non-JSONL file under the remote Codex home,
/// so credentials, configuration, memories, and other account data never enter CodexBar.
/// Rsync's delta protocol and `--inplace` preserve both network and scanner incrementality.
enum RemoteCodexUsageMirror {
    struct Configuration: Sendable, Equatable {
        let hosts: [String]
        let mirrorRoot: URL

        var sessionRoots: [URL] {
            let configured = self.hosts.map { host in
                self.hostRoot(host: host).appendingPathComponent("sessions", isDirectory: true)
            }
            let existingHostRoots = (try? FileManager.default.contentsOfDirectory(
                at: self.mirrorRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            let existing = existingHostRoots.compactMap { hostRoot -> URL? in
                let sessions = hostRoot.appendingPathComponent("sessions", isDirectory: true)
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: sessions.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue ? sessions : nil
            }
            var seen: Set<String> = []
            return (configured + existing).filter { seen.insert($0.standardizedFileURL.path).inserted }
                .sorted { $0.path < $1.path }
        }

        func hostRoot(host: String) -> URL {
            self.mirrorRoot.appendingPathComponent(Self.hostDirectoryName(host), isDirectory: true)
        }

        private static func hostDirectoryName(_ host: String) -> String {
            let slug = host.unicodeScalars.map { scalar -> Character in
                let isSafe = CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                return isSafe ? Character(String(scalar)) : "-"
            }
            .prefix(48)
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in host.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return String(slug) + "-" + String(hash, radix: 16)
        }
    }

    private static let defaultMinimumRefreshInterval: TimeInterval = 30
    private static let hardProcessTimeout: TimeInterval = 15

    static func configuration(
        codexHome: URL,
        cacheRoot: URL?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main) -> Configuration?
    {
        guard self.isEnabled(environment: environment, bundle: bundle) else { return nil }
        let explicitHosts = self.explicitHosts(environment["CODEXBAR_REMOTE_CODEX_HOSTS"])
        let stateURL = codexHome.appendingPathComponent(".codex-global-state.json", isDirectory: false)
        let discoveredHosts = (try? Data(contentsOf: stateURL)).map(self.hosts(fromGlobalState:)) ?? []
        let hosts = RemoteSessionFetcher.sanitizedHosts(explicitHosts + discoveredHosts)
            .filter(Self.isRsyncSafeHost)
        let root = (cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CodexBar", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("CodexBar", isDirectory: true))
            .appendingPathComponent("remote-codex-usage", isDirectory: true)
        let configuration = Configuration(hosts: hosts, mirrorRoot: root)
        guard !hosts.isEmpty || !configuration.sessionRoots.isEmpty else { return nil }
        return configuration
    }

    static func synchronizeIfNeeded(
        configuration: Configuration,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        force: Bool = false,
        checkCancellation: CostUsageScanner.CancellationCheck? = nil)
    {
        guard let rsync = self.findExecutable(
            named: "rsync",
            candidates: ["/usr/bin/rsync", "/opt/homebrew/bin/rsync", "/usr/local/bin/rsync"],
            environment: environment),
            let ssh = self.findExecutable(
                named: "ssh",
                candidates: ["/usr/bin/ssh", "/bin/ssh"],
                environment: environment)
        else {
            CostUsageScanner.log.warning("Remote Codex usage sync skipped because ssh or rsync was not found")
            return
        }

        let minimumInterval = self.minimumRefreshInterval(environment: environment)
        for host in configuration.hosts {
            do {
                try checkCancellation?()
                let hostRoot = configuration.hostRoot(host: host)
                try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
                let stampURL = hostRoot.appendingPathComponent(".last-successful-sync", isDirectory: false)
                if !force, self.isFresh(stampURL: stampURL, minimumInterval: minimumInterval) {
                    continue
                }

                try checkCancellation?()
                let arguments = self.rsyncArguments(ssh: ssh, host: host, destination: hostRoot)
                let succeeded = self.runSynchronously(
                    executable: rsync,
                    arguments: arguments,
                    environment: environment,
                    timeout: self.hardProcessTimeout) == 0

                if succeeded {
                    _ = FileManager.default.createFile(atPath: stampURL.path, contents: Data())
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: stampURL.path)
                } else {
                    CostUsageScanner.log.warning(
                        "Remote Codex usage sync failed",
                        metadata: ["host": host])
                }
            } catch is CancellationError {
                return
            } catch {
                CostUsageScanner.log.warning(
                    "Remote Codex usage sync failed",
                    metadata: ["host": host, "error": error.localizedDescription])
            }
        }
    }

    package static func hosts(fromGlobalState data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let connections = root["codex-managed-remote-connections"] as? [[String: Any]] ?? []
        let projects = root["remote-projects"] as? [[String: Any]] ?? []
        let autoConnect = root["remote-connection-auto-connect-by-host-id"] as? [String: Any] ?? [:]

        var aliasByHostID: [String: String] = [:]
        for connection in connections {
            guard let hostID = connection["hostId"] as? String else { continue }
            let alias = (connection["alias"] as? String) ?? (connection["displayName"] as? String)
            if let alias, !alias.isEmpty {
                aliasByHostID[hostID] = alias
            }
        }

        var activeHostIDs = Set(autoConnect.compactMap { entry -> String? in
            entry.value as? Bool == true ? entry.key : nil
        })
        if let selected = root["selected-project"] as? [String: Any],
           selected["type"] as? String == "remote",
           let projectID = selected["projectId"] as? String,
           let project = projects.first(where: { $0["id"] as? String == projectID }),
           let hostID = project["hostId"] as? String
        {
            activeHostIDs.insert(hostID)
        }

        return activeHostIDs.compactMap { hostID in
            aliasByHostID[hostID] ?? self.alias(fromHostID: hostID)
        }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    package static func rsyncArguments(
        ssh: String,
        host: String,
        destination: URL) -> [String]
    {
        [
            "-rltz",
            "--partial",
            "--inplace",
            "--delete",
            "--prune-empty-dirs",
            "--include=/sessions/***",
            "--include=/archived_sessions/***",
            "--exclude=*",
            "--timeout=8",
            "-e", "\(ssh) -o BatchMode=yes -o ConnectTimeout=3",
            "\(host):.codex/",
            destination.path + "/",
        ]
    }

    private static func isEnabled(environment: [String: String], bundle: Bundle) -> Bool {
        if let explicit = environment["CODEXBAR_REMOTE_CODEX_USAGE"]?.lowercased() {
            return ["1", "true", "yes", "on"].contains(explicit)
        }
        return bundle.object(forInfoDictionaryKey: "CodexBarRemoteCodexUsageEnabled") as? Bool == true
    }

    private static func explicitHosts(_ value: String?) -> [String] {
        value?.split(separator: ",").map(String.init) ?? []
    }

    private static func alias(fromHostID hostID: String) -> String? {
        guard let separator = hostID.lastIndex(of: ":") else { return nil }
        let alias = String(hostID[hostID.index(after: separator)...])
        return alias.isEmpty ? nil : alias
    }

    private static func isRsyncSafeHost(_ host: String) -> Bool {
        host.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == "." || scalar == "_" || scalar == "-" || scalar == "@"
        }
    }

    private static func minimumRefreshInterval(environment: [String: String]) -> TimeInterval {
        guard let raw = environment["CODEXBAR_REMOTE_CODEX_REFRESH_SECONDS"],
              let value = TimeInterval(raw)
        else { return self.defaultMinimumRefreshInterval }
        return max(0, value)
    }

    private static func isFresh(stampURL: URL, minimumInterval: TimeInterval) -> Bool {
        guard minimumInterval > 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: stampURL.path),
              let date = attributes[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(date) < minimumInterval
    }

    private static func findExecutable(
        named name: String,
        candidates: [String],
        environment: [String: String]) -> String?
    {
        let pathCandidates = (environment["PATH"] ?? "/usr/bin:/bin")
            .split(separator: ":")
            .map { String($0) + "/" + name }
        return (pathCandidates + candidates).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runSynchronously(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval) -> Int32?
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        let processGroup: pid_t? = setpgid(process.processIdentifier, process.processIdentifier) == 0
            ? process.processIdentifier
            : nil
        guard completed.wait(timeout: .now() + timeout) == .success else {
            SubprocessRunner.terminateProcess(process, processGroup: processGroup)
            return nil
        }
        return process.terminationStatus
    }
}
