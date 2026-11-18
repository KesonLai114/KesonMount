import Foundation

/// 调试环境变量统一入口。
///
/// 1.6.0 及以前叫 `NETMOUNT_*`；改名 KesonMount 后统一用 `KESONMOUNT_*`。
/// 旧变量继续认，新变量优先，这样写好的脚本和自检命令不会突然失效。
enum AppEnvironment {
    private static let legacyPrefix = "NETMOUNT_"
    private static let prefix = "KESONMOUNT_"

    static let dictionary: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in env where key.hasPrefix(legacyPrefix) {
            let newKey = prefix + String(key.dropFirst(legacyPrefix.count))
            if env[newKey] == nil { env[newKey] = value }
        }
        return env
    }()

    static func value(_ name: String) -> String? { dictionary[prefix + name] }
    static func flag(_ name: String) -> Bool { value(name) == "1" }
}
