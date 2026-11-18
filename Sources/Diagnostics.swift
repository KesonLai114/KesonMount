import Foundation
import OSLog

/// 运行期诊断日志。
///
/// 掉线重挂这类问题都发生在「没人看着的时候」，只靠 `KESONMOUNT_LOG=1` 重启复现
/// 很不现实。这里保留最近若干条决策记录，用户可以在设置里一键导出（自动脱敏），
/// 同时写进系统统一日志，方便用「控制台」查历史。
enum Diagnostics {
    private static let limit = 500
    private static let lock = NSLock()
    private static var lines: [String] = []
    private static let logger = Logger(subsystem: "com.keson.kesonmount", category: "runtime")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static func log(_ message: String) {
        let safe = MountService.redact(message)
        let line = "[\(formatter.string(from: Date()))] \(safe)"
        lock.lock()
        lines.append(line)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        lock.unlock()
        logger.info("\(safe, privacy: .private)")
        // KESONMOUNT_LOG=1 时也打到标准错误：在终端里直接跑二进制排查时，
        // 不必再去翻「控制台」，一行命令就能看到全部决策记录。
        if AppEnvironment.value("LOG") == "1" {
            FileHandle.standardError.write("[诊断] \(safe)\n".data(using: .utf8)!)
        }
    }

    /// 导出用文本：含版本、系统版本、脱敏后的配置摘要和最近日志。
    static func exportText(driveSummary: [String] = []) -> String {
        lock.lock()
        let snapshot = lines
        lock.unlock()
        var out: [String] = [
            "KesonMount诊断报告",
            "版本：\(AppInfo.version)（构建 \(AppInfo.build)）",
            "系统：macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "导出时间：\(Date())",
            "",
            "== 磁盘配置（不含密码）=="
        ]
        out.append(contentsOf: driveSummary)
        out.append("")
        out.append("== 最近 \(snapshot.count) 条运行日志 ==")
        out.append(contentsOf: snapshot)
        return out.joined(separator: "\n")
    }
}
