import Foundation
import AppKit

enum DebugLog {
    private static let lock = NSLock()
    private static var folder: URL { AppFiles.folder }
    private static var appLogURL: URL { folder.appendingPathComponent("app-debug.log") }
    private static var serviceLogURL: URL { folder.appendingPathComponent("akshare-service.log") }

    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) [app] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: appLogURL.path) { FileManager.default.createFile(atPath: appLogURL.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: appLogURL) else { return }
        try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close()
    }

    static func export() -> URL {
        let destination = folder.appendingPathComponent("AStockMonitor-debug.txt")
        let app = (try? String(contentsOf: appLogURL, encoding: .utf8)) ?? "（应用日志为空）"
        let service = (try? String(contentsOf: serviceLogURL, encoding: .utf8)) ?? "（服务日志为空）"
        let report = "AStockMonitor 调试报告\n生成时间：\(Date().formatted())\nmacOS：\(ProcessInfo.processInfo.operatingSystemVersionString)\n\n===== 应用日志 =====\n\(app)\n===== AkShare 服务日志 =====\n\(service)"
        try? report.write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }
}
