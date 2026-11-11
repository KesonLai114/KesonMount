import Foundation

/// 版本信息。
///
/// 以前用户要确认自己装的是哪一版，只能自己去翻 App 包里的 Info.plist——
/// 很不现实。现在界面、菜单栏、关于面板统一用这里，版本号直接摆在明面上。
enum AppInfo {

    /// 发布版本，例如 1.4.0
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "1.4.0"
    }

    /// 构建号，例如 6
    static var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "6"
    }

    /// 界面显示用：1.4.0（构建 6）
    static var full: String {
        "\(version)（构建 \(build)）"
    }

    /// 短形式：v1.4.0
    static var short: String {
        "v\(version)"
    }
}
