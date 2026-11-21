import Foundation
import AppKit
import os

@MainActor
final class ServerManager: ObservableObject {
    enum State: String {
        case stopped, starting, running, failed
    }

    enum FailureReason: String {
        case devecoMissing, noFreePort, launchFailed, unhealthy, exited

        var label: String {
            switch self {
            case .devecoMissing: return NSLocalizedString("deveco CLI not found", comment: "")
            case .noFreePort: return NSLocalizedString("No free local port", comment: "")
            case .launchFailed: return NSLocalizedString("Failed to launch deveco serve", comment: "")
            case .unhealthy: return NSLocalizedString("Server did not become healthy", comment: "")
            case .exited: return NSLocalizedString("Server exited unexpectedly", comment: "")
            }
        }
    }

    @Published var state: State = .stopped
    @Published var projectDirectory: URL
    @Published private(set) var recentProjects: [URL] = []
    @Published var logTail = ""
    @Published var errorMessage: String?
    @Published private(set) var failureReason: FailureReason?

    private(set) var port: UInt16 = 4096

    /// Handle to the managed server's process group. Replaces `Process` so
    /// `stop()` can terminate the deveco launcher *and* its Node children.
    private var serverProcess: ProcessGroupLauncher.Launched?
    private var monitorTask: Task<Void, Never>?
    private var outputPipe: Pipe?
    private var logHandle: FileHandle?
    private var healthTask: Task<Void, Never>?
    private var startupActivity: NSObjectProtocol?

    var candidateURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    var baseURL: URL? {
        state == .running ? candidateURL : nil
    }

    private static let directoryKey = "projectDirectory"
    private static let recentsKey = "recentProjectPaths"
    private static let maxRecents = 8

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.directoryKey) {
            projectDirectory = URL(fileURLWithPath: saved)
        } else {
            projectDirectory = FileManager.default.homeDirectoryForCurrentUser
        }
        let paths = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        recentProjects = paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(url)
    }

    /// Switches the managed project and restarts the server if needed.
    func openProject(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        projectDirectory = url
        UserDefaults.standard.set(url.path, forKey: Self.directoryKey)
        rememberRecent(url)
        if state != .stopped {
            stop()
            Task { @MainActor [weak self] in self?.start() }
        }
    }

    private func rememberRecent(_ url: URL) {
        var recents = recentProjects.filter { $0.path != url.path }
        recents.insert(url, at: 0)
        if recents.count > Self.maxRecents {
            recents = Array(recents.prefix(Self.maxRecents))
        }
        recentProjects = recents
        UserDefaults.standard.set(recents.map(\.path), forKey: Self.recentsKey)
    }

    func start() {
        if serverProcess != nil {
            if state == .starting {
                // A previous boot may still be finishing; let a foreground
                // event re-probe instead of silently doing nothing.
                recheckHealthIfNeeded()
                return
            }
            if state == .failed {
                // A failed/unhealthy boot can leave a live child behind.
                // Retry means "replace it", not "do nothing".
                stop()
            } else {
                return
            }
        }
        beginStartupActivity()
        state = .starting
        errorMessage = nil
        failureReason = nil
        logTail = ""

        // GUI apps are launched by launchd with a minimal PATH, so `env deveco`
        // does not work; resolve the binary explicitly instead.
        guard let executable = Self.resolveDevecoExecutable() else {
            state = .failed
            failureReason = .devecoMissing
            errorMessage = """
            Could not find the deveco CLI. Install it globally, or set its full path in Settings → Server.
            """
            endStartupActivity()
            return
        }

        // Pick a free port so a leftover server from an earlier run (or a
        // second app instance) cannot collide or answer the health check.
        let basePort = UInt16(max(1024, min(AppSettings.basePort, 65_000)))
        guard let port = Self.firstFreePort(from: basePort) else {
            state = .failed
            failureReason = .noFreePort
            errorMessage = "No free local port available to start deveco serve."
            endStartupActivity()
            return
        }
        self.port = port

        let support = Self.applicationSupportDirectory()
        let dataDirectory = support.appendingPathComponent("deveco-data", isDirectory: true)
        let logURL = support.appendingPathComponent("server.log")
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        // deveco's launcher is a `#!/usr/bin/env node` script, so the child
        // needs Node.js on PATH even though GUI apps get a minimal PATH.
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_DATA_HOME"] = dataDirectory.path
        var pathPrefix: [String] = [executable.deletingLastPathComponent().path]
        if let nodeDir = Self.resolveNodeDirectory() {
            pathPrefix.append(nodeDir)
        }
        environment["PATH"] = pathPrefix.joined(separator: ":")
            + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")

        // stdout/stderr 汇入同一个 Pipe，由本进程读取后写入日志文件并更新 logTail。
        let output = Pipe()
        outputPipe = output
        logHandle = try? FileHandle(forWritingTo: logURL)

        let config = ProcessGroupLauncher.Configuration(
            executable: executable,
            arguments: ["serve", "--port", String(port), "--hostname", "127.0.0.1"],
            environment: environment,
            workingDirectory: projectDirectory,
            stdout: output.fileHandleForWriting,
            stderr: output.fileHandleForWriting
        )

        do {
            serverProcess = try ProcessGroupLauncher.launch(config)
            Log.server.info("deveco serve launched on port \(self.port) (project: \(self.projectDirectory.path, privacy: .public))")
        } catch {
            serverProcess = nil
            cleanUpIO()
            state = .failed
            failureReason = .launchFailed
            errorMessage = error.localizedDescription
            Log.server.error("launch failed: \(error.localizedDescription, privacy: .public)")
            endStartupActivity()
            return // 不再启动健康检查
        }

        // NEVER call `availableData` here: it blocks until the child writes,
        // and this Task inherits @MainActor from ServerManager — that is the
        // "enable server → app freezes" bug. A readabilityHandler is invoked
        // by Foundation on a background queue only when bytes are available.
        let reader = output.fileHandleForReading
        reader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(data: data, encoding: .utf8)
                ?? String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.appendLog(text) }
        }

        // 监控子进程退出
        let launchedPID = serverProcess!.pid
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                let status = waitpid(launchedPID, nil, WNOHANG)
                if status == launchedPID || (status == -1 && errno == ECHILD) {
                    await MainActor.run { self?.handleTermination() }
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        healthTask = Task { [weak self] in
            await self?.waitForHealth()
        }
    }

    func stop() {
        healthTask?.cancel()
        healthTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        endStartupActivity()
        guard let serverProcess else {
            cleanUpIO()
            return
        }
        // 先标记为已停止，避免终止处理器闪现"服务器意外退出"。
        state = .stopped
        // 终止整个进程组（deveco 启动器 + Node 服务），避免孤儿进程占端口。
        serverProcess.terminate()
        self.serverProcess = nil
        cleanUpIO()
    }

    private func isServerAlive(_ launched: ProcessGroupLauncher.Launched) -> Bool {
        kill(launched.pid, 0) == 0 || errno == EPERM
    }

    private func waitForHealth() async {
        for _ in 0..<80 {
            if Task.isCancelled {
                endStartupActivity()
                return
            }
            // 进程在健康检查期间退出则交给 monitorTask 报失败。
            guard let launched = serverProcess, isServerAlive(launched) else {
                endStartupActivity()
                return
            }
            if await probeHealth(), isServerAlive(launched) {
                markRunning()
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard state == .starting else { return }
        state = .failed
        failureReason = .unhealthy
        errorMessage = "deveco serve did not become healthy. \(logTail.suffix(400))"
        endStartupActivity()
    }

    /// A short, uncached probe. `URLSession.shared.data(from:)` can inherit
    /// long default timeouts when the app is being throttled in the
    /// background; the explicit timeout keeps startup feedback responsive.
    private func probeHealth() async -> Bool {
        var request = URLRequest(url: candidateURL.appendingPathComponent("global/health"))
        request.timeoutInterval = 1.2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Called when the app becomes active. App Nap can suspend the boot task
    /// while the app is in the background even though the server is already
    /// healthy, leaving the UI stuck on "Starting…".
    func recheckHealthIfNeeded() {
        guard state == .starting || state == .failed else { return }
        guard let launched = serverProcess, isServerAlive(launched) else { return }
        Task { [weak self] in
            guard let self else { return }
            guard await self.probeHealth(), self.state == .starting || self.state == .failed else { return }
            self.markRunning()
        }
    }

    private func markRunning() {
        // 只有在启动中或显式复查态才能置为 running，防止失败态被误改。
        guard state == .starting || state == .failed else { return }
        Log.server.info("health check passed — server ready")
        state = .running
        errorMessage = nil
        failureReason = nil
        endStartupActivity()
        clearPendingRestoreBackupIfNeeded()
    }

    private func beginStartupActivity() {
        guard startupActivity == nil else { return }
        startupActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Starting deveco server"
        )
    }

    private func endStartupActivity() {
        guard let startupActivity else { return }
        ProcessInfo.processInfo.endActivity(startupActivity)
        self.startupActivity = nil
    }

    private func handleTermination() {
        // 只有我们主动终止时才跳过错误提示；monitorTask 感知到退出后调用。
        guard state != .stopped else { return }
        serverProcess = nil
        monitorTask?.cancel()
        monitorTask = nil
        cleanUpIO()
        endStartupActivity()
        state = .failed
        failureReason = .exited
        Log.server.error("deveco serve exited unexpectedly")
        if logTail.contains("node: No such file or directory") {
            errorMessage = """
            deveco serve could not find Node.js. Set the Node.js path in Settings → Server. \
            Auto-detected: \(Self.resolveNodeDirectory() ?? "not found").
            """
        } else {
            errorMessage = "deveco serve exited. \(Self.redact(String(logTail.suffix(400))))"
        }
    }

    nonisolated private static func runDitto(_ arguments: [String], domain: String, timeout: TimeInterval = 120) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        task.arguments = arguments
        let errorPipe = Pipe()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = errorPipe.fileHandleForWriting
        try task.run()
        errorPipe.fileHandleForWriting.closeFile()

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if task.isRunning {
            task.terminate()
            usleep(200_000)
            if task.isRunning { kill(task.processIdentifier, SIGKILL) }
            throw NSError(domain: domain, code: 124,
                          userInfo: [NSLocalizedDescriptionKey: "ditto timed out after \(Int(timeout))s"])
        }
        guard task.terminationStatus == 0 else {
            let detail = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: domain, code: Int(task.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "ditto exited with status \(task.terminationStatus). \(detail)"])
        }
    }

    private func cleanUpIO() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe?.fileHandleForWriting.closeFile()
        outputPipe?.fileHandleForReading.closeFile()
        outputPipe = nil
        try? logHandle?.close()
        logHandle = nil
    }

    /// 写入日志前抹掉常见凭据形态（API key / Bearer token / Authorization 头），
    /// 避免 server.log 与诊断报告把密钥带出去。
    nonisolated static func redact(_ text: String) -> String {
        var result = text
        // sk-xxx / Bearer xxx 形式的密钥
        result = result.replacingOccurrences(
            of: #"(?i)(sk-[A-Za-z0-9_\-]{8,})"#,
            with: "sk-***REDACTED***",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)(Bearer\s+)[A-Za-z0-9._\-]+"#,
            with: "$1***REDACTED***",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)(Authorization\s*[:=]\s*)[^\s,;]+"#,
            with: "$1***REDACTED***",
            options: .regularExpression
        )
        return result
    }

    private func appendLog(_ text: String) {
        let safe = Self.redact(text)
        // Unbounded string concatenation on a chatty server is a slow memory
        // leak that eventually stalls the main thread. Trim every append.
        logTail = String((logTail + safe).suffix(20_000))
        logHandle?.write(Data(safe.utf8))
    }

    /// One-clipboard support bundle: versions, paths, state, and the server
    /// log tail — enough to diagnose a report without asking follow-ups.
    func diagnosticsReport() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let devecoPath = AppSettings.devecoPath.isEmpty
            ? (Self.resolveDevecoExecutable()?.path ?? "not found")
            : AppSettings.devecoPath
        let node = Self.resolveNodeDirectory() ?? "not found"
        return """
        DevEco Code Desktop \(version) (build \(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Server state: \(state.rawValue)
        Endpoint: \(state == .running ? candidateURL.absoluteString : "not running") (port \(port))
        Project: \(projectDirectory.path)
        deveco binary: \(devecoPath)
        Node directory: \(node)
        Data directory: \(Self.dataDirectory.path)
        Log file: \(Self.logFileURL.path)
        Last error: \(Self.redact(errorMessage ?? "none"))

        --- server log tail ---
        \(logTail.isEmpty ? "(empty)" : Self.redact(String(logTail.suffix(800))))
        """
    }

    // MARK: - Deveco executable discovery

    /// The log file the managed server writes to; exposed for Settings'
    /// "Reveal in Finder" action.
    nonisolated static var logFileURL: URL {
        URL(fileURLWithPath: applicationSupportDirectory().path)
            .appendingPathComponent("server.log")
    }

    /// The deveco data directory (XDG_DATA_HOME target) the server writes to.
    nonisolated static var dataDirectory: URL {
        URL(fileURLWithPath: applicationSupportDirectory().path)
            .appendingPathComponent("deveco-data", isDirectory: true)
    }

    /// Zips the deveco data directory (sessions DB, logs) to the given URL.
    nonisolated static func backupData(to destination: URL) throws {
        let dataDir = dataDirectory
        guard FileManager.default.fileExists(atPath: dataDir.path) else {
            throw NSError(domain: "backup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Nothing to back up yet — the data folder does not exist."])
        }
        try Self.runDitto(
            ["-c", "-k", "--sequesterRsrc", "--keepParent", dataDir.path, destination.path],
            domain: "backup"
        )
    }

    /// Replaces the deveco data directory with the contents of a backup zip.
    /// Stops the server first, then restarts it with the restored data.
    nonisolated func restoreData(from archive: URL) throws {
        let support = Self.applicationSupportDirectory()
        let dataDir = support.appendingPathComponent("deveco-data", isDirectory: true)
        let staging = support.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        do {
            try Self.runDitto(["-x", "-k", archive.path, staging.path], domain: "restore")
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }

        // 归档含 deveco-data 目录（--keepParent），严格校验顶层条目，
        // 防止恶意/损坏归档把任意目录注入我们的数据目录。
        let contents = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey])
        guard contents.count == 1,
              let restored = contents.first,
              (try? restored.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              restored.lastPathComponent == "deveco-data" else {
            try? FileManager.default.removeItem(at: staging)
            throw NSError(domain: "restore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Backup archive does not contain a single deveco-data folder."])
        }

        // 原子替换：先把旧目录改名保留，新数据就位并验证后才删除备份。
        let backupURL = support.appendingPathComponent("deveco-data.pre-restore-\(UUID().uuidString)", isDirectory: true)
        var didRenameOld = false
        do {
            if FileManager.default.fileExists(atPath: dataDir.path) {
                try FileManager.default.moveItem(at: dataDir, to: backupURL)
                didRenameOld = true
            }
            do {
                try FileManager.default.moveItem(at: restored, to: dataDir)
            } catch {
                // 新数据移动失败，立刻恢复旧数据。
                if didRenameOld {
                    try? FileManager.default.moveItem(at: backupURL, to: dataDir)
                }
                try? FileManager.default.removeItem(at: staging)
                throw error
            }
            // 新数据已就位；保留旧目录作为回滚副本，等下一次成功启动再清理。
            try? FileManager.default.removeItem(at: staging)
            UserDefaults.standard.set(backupURL.path, forKey: "pendingRestoreBackup")
        } catch {
            if didRenameOld && !FileManager.default.fileExists(atPath: dataDir.path) {
                try? FileManager.default.moveItem(at: backupURL, to: dataDir)
            }
            throw error
        }
    }

    /// 服务健康后清理由 restoreData 保留的旧数据备份。
    func clearPendingRestoreBackupIfNeeded() {
        guard let path = UserDefaults.standard.string(forKey: "pendingRestoreBackup"),
              state == .running else { return }
        let url = URL(fileURLWithPath: path)
        if url.path.hasPrefix(Self.applicationSupportDirectory().path) {
            try? FileManager.default.removeItem(at: url)
        }
        UserDefaults.standard.removeObject(forKey: "pendingRestoreBackup")
    }

    nonisolated static func resolveDevecoExecutable() -> URL? {
        let override = AppSettings.devecoPath
        if !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        // The resolved path is cached in the same key the override uses, so
        // "Auto-detect" in Settings just clears the key and calls this again.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.npm-global/bin/deveco",
            "\(home)/.local/bin/deveco",
            "\(home)/bin/deveco",
            "/opt/homebrew/bin/deveco",
            "/usr/local/bin/deveco",
            "/usr/bin/deveco",
        ]
        if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            AppSettings.devecoPath = match
            return URL(fileURLWithPath: match)
        }

        // 从当前进程继承的 PATH 里查找（不加载 .zshrc/.zprofile）。
        // 使用登录 shell（-l）会执行用户启动脚本中的任意代码，GUI 应用不该这样做。
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "command -v deveco"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty, !path.contains("\n"),
            FileManager.default.isExecutableFile(atPath: path) else { return nil }
        AppSettings.devecoPath = path
        return URL(fileURLWithPath: path)
    }

    /// Directory containing the Node.js runtime deveco needs at runtime.
    /// Cached like the deveco path; an override lives in the same key.
    nonisolated static func resolveNodeDirectory() -> String? {
        let key = "nodeExecutablePath"
        let override = UserDefaults.standard.string(forKey: key) ?? ""
        if !override.isEmpty {
            let dir = (override as NSString).deletingLastPathComponent
            if FileManager.default.isExecutableFile(atPath: override) {
                return dir
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidateFiles: [String] = []

        // User-local versioned installs: ~/opt/node-v*/bin, ~/.nvm/versions/node/*/bin
        for base in ["\(home)/opt", "\(home)/.nvm/versions/node"] {
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: base) {
                for entry in entries.sorted(by: >) where entry.hasPrefix("node-v") {
                    candidateFiles.append("\(base)/\(entry)/bin/node")
                }
            }
        }
        candidateFiles.append(contentsOf: [
            "\(home)/.local/bin/node",
            "\(home)/.npm-global/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ])
        if let match = candidateFiles.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            UserDefaults.standard.set(match, forKey: key)
            return (match as NSString).deletingLastPathComponent
        }

        // Fall back to a plain sh PATH lookup (no profile scripts), then cache.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "command -v node"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty, !path.contains("\n"),
            FileManager.default.isExecutableFile(atPath: path) else { return nil }
        UserDefaults.standard.set(path, forKey: key)
        return (path as NSString).deletingLastPathComponent
    }

    /// Accepts deveco's product agreement non-interactively
    /// (`deveco auth consent --accept`). deveco blocks all model calls until
    /// this is done, and fresh data directories start unaccepted.
    nonisolated static func acceptProductAgreement() -> Bool {
        guard let executable = resolveDevecoExecutable() else { return false }
        let task = Process()
        task.executableURL = executable
        task.arguments = ["auth", "consent", "--accept"]
        var environment = ProcessInfo.processInfo.environment
        var pathPrefix = [executable.deletingLastPathComponent().path]
        if let nodeDir = resolveNodeDirectory() {
            pathPrefix.append(nodeDir)
        }
        environment["PATH"] = pathPrefix.joined(separator: ":")
            + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        task.environment = environment
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return false
        }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    // MARK: - Port selection

    private static func firstFreePort(from start: UInt16) -> UInt16? {
        for offset in 0..<100 {
            let candidate = start + UInt16(offset)
            if isPortFree(candidate) { return candidate }
        }
        return nil
    }

    private static func isPortFree(_ port: UInt16) -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(descriptor, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    nonisolated private static func applicationSupportDirectory() -> URL {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let directory = urls[0].appendingPathComponent("DevEcoCodeDesktop", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
