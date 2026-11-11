import Foundation

/// Starts the bundled AkShare bridge when the app opens and reuses an already-running bridge.
///
/// The bridge needs a Python 3 that can import AkShare. On launch the manager
/// prefers an interpreter that already has it; if none does, it creates a
/// private virtual environment under Application Support, installs AkShare
/// there and reports progress
/// through `onProgress`. A leftover bridge on the port that is outdated or
/// lacks AkShare is shut down and replaced instead of blocking the app.
@MainActor final class LocalBridgeManager {
    private var process: Process?
    private var logHandle: FileHandle?
    private(set) var failureMessage = "本地行情服务尚未就绪。"
    /// Status text for the main window while the bridge is prepared.
    var onProgress: ((String) -> Void)?
    /// Shared so concurrent callers (refresh, detail windows, connection test)
    /// never run two installs at once.
    private var pythonPreparation: Task<String?, Never>?

    private static let apiVersion = 19
    private static let port = 8767

    private enum Health: Equatable { case ready, stale, missingAkShare, unavailable }

    func ensureRunning() async -> Bool {
        let ensureStarted = ProcessInfo.processInfo.systemUptime
        switch await health() {
        case .ready:
            DebugLog.write("本地桥接服务版本校验通过，复用服务；health=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - ensureStarted))s")
            return true
        case .stale, .missingAkShare:
            DebugLog.write("端口 \(Self.port) 上的行情服务版本过旧或缺少 AkShare，尝试关闭后重启")
            guard await terminateLeftoverBridge() else {
                failureMessage = "检测到旧版行情服务且无法自动关闭。请完全退出旧版 A 股盯盘后重新打开新版。"
                DebugLog.write(failureMessage)
                return false
            }
        case .unavailable: break
        }
        guard let script = Bundle.main.url(forResource: "akshare_server", withExtension: "py") else { DebugLog.write("应用资源中找不到 akshare_server.py"); return false }
        guard let python = await preparedPython() else { DebugLog.write(failureMessage); return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script.path]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        process.environment = Self.childEnvironment()

        let logURL = AppFiles.folder.appendingPathComponent("akshare-service.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            try? handle.seekToEnd()
            logHandle = handle
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        do {
            try process.run()
            self.process = process
            DebugLog.write("已启动本地行情服务 pid=\(process.processIdentifier), python=\(python)")
        } catch {
            failureMessage = "启动本地服务失败：\(error.localizedDescription)"
            DebugLog.write("启动行情服务进程失败：\(error.localizedDescription)")
            return false
        }
        onProgress?("正在启动本地 AkShare 行情服务…")

        for _ in 0..<30 {
            switch await health() {
            case .ready:
                DebugLog.write("本地行情服务版本校验通过；启动+health=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - ensureStarted))s")
                return true
            case .stale, .missingAkShare:
                failureMessage = "行情服务启动后仍未通过校验（版本或 AkShare 不可用），详情见调试日志。"
                DebugLog.write(failureMessage)
                return false
            case .unavailable: break
            }
            if !process.isRunning {
                failureMessage = "本地服务启动后退出（状态码 \(process.terminationStatus)）。详情见调试日志。"
                DebugLog.write(failureMessage)
                return false
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        let healthy = await health() == .ready
        if !healthy { failureMessage = "等待本地行情服务启动超时。详情见调试日志。"; DebugLog.write(failureMessage) }
        return healthy
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        try? logHandle?.close()
        logHandle = nil
        process = nil
    }

    private func health() async -> Health {
        guard let url = URL(string: "http://127.0.0.1:\(Self.port)/health") else { return .unavailable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return .unavailable }
        guard (200..<300).contains(http.statusCode),
              let health = try? JSONDecoder().decode(HealthResponse.self, from: data),
              health.status == "ok", health.service == "astock-monitor-akshare", health.api_version == Self.apiVersion else { return .stale }
        return health.akshare == false ? .missingAkShare : .ready
    }

    private struct HealthResponse: Decodable { let status: String; let service: String?; let api_version: Int?; let akshare: Bool? }

    // MARK: - Python with AkShare

    private func preparedPython() async -> String? {
        if let pythonPreparation { return await pythonPreparation.value }
        let task = Task { await self.findOrInstallPython() }
        pythonPreparation = task
        let result = await task.value
        // A failed attempt may be retried on the next refresh.
        if result == nil { pythonPreparation = nil }
        return result
    }

    /// Private virtual environment owned by the app. Installing here avoids
    /// Homebrew's externally-managed-environment protection (PEP 668) and never
    /// changes the user's own Python packages.
    private static var venvFolder: URL { AppFiles.folder.appendingPathComponent("python-venv", isDirectory: true) }
    private static var venvPython: String { venvFolder.appendingPathComponent("bin/python3").path }

    private func findOrInstallPython() async -> String? {
        let systemPythons = pythonCandidates()
        var candidates = systemPythons
        if FileManager.default.isExecutableFile(atPath: Self.venvPython) { candidates.insert(Self.venvPython, at: 0) }
        guard !candidates.isEmpty else {
            failureMessage = "找不到 Python 3。请安装 Python 3（或 Xcode 命令行工具）后重启应用。"
            return nil
        }
        onProgress?("正在检查 Python 与 AkShare…")
        for python in candidates {
            let status = await Self.run(python, ["-c", "import akshare"], logName: "akshare-check.log", timeout: 60)
            if status == 0 {
                DebugLog.write("使用已安装 AkShare 的 Python：\(python)")
                return python
            }
        }
        DebugLog.write("候选 Python 均未安装 AkShare：\(candidates.joined(separator: ", "))；开始在应用专用虚拟环境中安装")
        var lastStep = ""
        for base in systemPythons {
            onProgress?("正在自动安装 AkShare 行情依赖（首次运行，约需 1–5 分钟）…")
            let venvPath = Self.venvFolder.path
            lastStep = "创建虚拟环境（\(base)）"
            guard await Self.run(base, ["-m", "venv", "--clear", venvPath], logName: "akshare-install.log", timeout: 120) == 0 else {
                DebugLog.write("\(lastStep)失败，换下一个 Python")
                continue
            }
            lastStep = "升级 pip（\(base)）"
            _ = await Self.run(Self.venvPython, ["-m", "pip", "install", "--upgrade", "pip"], logName: "akshare-pip.log", timeout: 5 * 60)
            lastStep = "安装 AkShare（\(base)）"
            let status = await Self.run(Self.venvPython, ["-m", "pip", "install", "--upgrade", "akshare"], logName: "akshare-install.log", timeout: 15 * 60)
            if status == 0, await Self.run(Self.venvPython, ["-c", "import akshare"], logName: "akshare-check.log", timeout: 60) == 0 {
                DebugLog.write("AkShare 自动安装完成：venv=\(venvPath), base=\(base)")
                return Self.venvPython
            }
            DebugLog.write("\(lastStep)失败（状态码 \(status)），换下一个 Python")
        }
        failureMessage = "自动安装 AkShare 失败（最后一步：\(lastStep)）。请检查网络后点刷新重试；安装日志见 ~/Library/Application Support/AStockMonitor/akshare-install.log"
        return nil
    }

    private func pythonCandidates() -> [String] {
        [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/python3",
            "/usr/bin/python3"
        ].filter { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func childEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.merging([
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/Applications/Xcode.app/Contents/Developer/usr/bin:/usr/bin:/bin:/usr/sbin",
            "PYTHONUNBUFFERED": "1",
            "PIP_DISABLE_PIP_VERSION_CHECK": "1"
        ]) { _, new in new }
    }

    /// Run a helper process off the main thread, logging its output under
    /// Application Support. Returns the exit status, or -1 if it could not start
    /// or was stopped at the timeout.
    private static func run(_ executable: String, _ arguments: [String], logName: String, timeout: TimeInterval) async -> Int32 {
        let logURL = AppFiles.folder.appendingPathComponent(logName)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: logURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = childEnvironment()
        process.standardOutput = handle ?? FileHandle.nullDevice
        process.standardError = handle ?? FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                try? handle?.close()
                continuation.resume(returning: finished.terminationReason == .exit ? finished.terminationStatus : -1)
            }
            do {
                try process.run()
            } catch {
                try? handle?.close()
                continuation.resume(returning: -1)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    // MARK: - Leftover bridge

    /// Stop a bridge left on the port by an earlier build or a crashed copy.
    /// Only processes whose command line runs akshare_server.py are signalled.
    private func terminateLeftoverBridge() async -> Bool {
        let pids = await Self.output("/usr/sbin/lsof", ["-nP", "-t", "-iTCP:\(Self.port)", "-sTCP:LISTEN"])
            .split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        var signalled = false
        for pid in pids {
            let command = await Self.output("/bin/ps", ["-o", "command=", "-p", String(pid)])
            guard command.contains("akshare_server.py") else {
                DebugLog.write("端口 \(Self.port) 被其他程序占用（pid=\(pid)），不做处理")
                continue
            }
            kill(pid, SIGTERM)
            signalled = true
            DebugLog.write("已关闭残留行情服务 pid=\(pid)")
        }
        guard signalled else { return false }
        for _ in 0..<20 {
            if await health() == .unavailable { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return await health() == .unavailable
    }

    private static func output(_ executable: String, _ arguments: [String]) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do { try process.run() } catch { continuation.resume(returning: "") }
        }
    }
}
