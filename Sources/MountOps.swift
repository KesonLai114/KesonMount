import Foundation

/// 所有真正会改动系统挂载表的地方，共用这一条串行队列。
///
/// 之前启动自动挂载、看门狗重连、用户点击、reconcile 清理各跑各的后台队列，
/// 只靠一个「busy」UI 标记互相看不见：清理任务会在别人挂载到一半时把卷卸掉，
/// 或者同一共享被挂两次（系统自动加 `-1` 后缀，用户在别处配好的路径全废）。
/// 挂载是低频操作，串行换来的是「绝不会有两个人同时动同一块盘」。
enum MountOps {
    static let queue = DispatchQueue(label: "netmount.mount-ops", qos: .userInitiated)

    /// 异步排队执行；`block` 里可以放心调用 MountService.mount / unmount。
    static func run(_ block: @escaping () -> Void) {
        queue.async(execute: block)
    }
}
