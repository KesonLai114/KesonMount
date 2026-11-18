import Foundation

/// `kesonmount://` 深链接。
///
/// 菜单栏 App 的一大痛点是「只有自己能指挥自己」：想从快捷指令、Raycast、
/// 定时脚本、或者别的工具里挂一块盘，只能靠写死的三个全局快捷键。
/// 注册一个 URL scheme 之后，这些都变成一行 `open "kesonmount://mount?id=…"`。
///
/// 解析写成纯函数（不碰 AppKit、不碰状态），可以直接进单元测试——
/// 这条路径的输入来自外部，必须当成不可信数据：认不出来就返回 nil，
/// 绝不「猜一个动作」执行。
enum DeepLink {

    enum Command: Equatable {
        case show
        case refresh
        case mountAll
        case unmountAll
        case mount(UUID)
        case unmount(UUID)
        case reconnect(UUID)
    }

    static let scheme = "kesonmount"
    /// 1.6.0 及以前注册的是 netmount://，老脚本和快捷指令继续可用。
    static let legacyScheme = "netmount"

    /// 支持的形式（大小写不敏感，kesonmount:// 与旧 netmount:// 等价）：
    ///   kesonmount://show
    ///   kesonmount://refresh
    ///   kesonmount://mountAll
    ///   kesonmount://unmountAll
    ///   kesonmount://mount?id=<UUID>
    ///   kesonmount://unmount?id=<UUID>
    ///   kesonmount://reconnect?id=<UUID>
    static func parse(_ raw: String) -> Command? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let comps = URLComponents(string: trimmed),
              [scheme, legacyScheme].contains(comps.scheme?.lowercased() ?? "") else { return nil }

        // `kesonmount://mountAll` 里 host 是动作名；`kesonmount:mountAll` 里在 path 上
        let hostPart = (comps.host ?? "").lowercased()
        let action = hostPart.isEmpty
            ? comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            : hostPart

        switch action {
        case "", "show", "open":
            return .show
        case "refresh":
            return .refresh
        case "mountall":
            return .mountAll
        case "unmountall":
            return .unmountAll
        case "mount", "unmount", "reconnect":
            guard let value = comps.queryItems?
                    .first(where: { $0.name.lowercased() == "id" })?.value,
                  let id = UUID(uuidString: value) else { return nil }
            switch action {
            case "mount": return .mount(id)
            case "unmount": return .unmount(id)
            default: return .reconnect(id)
            }
        default:
            return nil
        }
    }
}
