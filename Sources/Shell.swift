import Foundation

struct ShellResult {
    let status: Int32
    let out: String
    let err: String
    var ok: Bool { status == 0 }
    var message: String {
        let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { return e }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 收集子进程输出。用 `readabilityHandler` 而不是 `readDataToEndOfFile()`：
/// 后者在孙进程继承 stdout 时会永远阻塞、无法取消，每次超时都会泄漏一个读线程。
private final class ShellOutputBuffer {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }

    /// 只 leave 一次：EOF 回调和超时清理可能同时发生
    func finish(_ group: DispatchGroup) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        group.leave()
    }
}

enum Shell {
    /// - Parameter input: 要写进子进程标准输入的内容。传了它，密码/脚本就不会出现在
    ///   argv 里（`ps` 能看到命令行参数，看不到标准输入）。
    /// - Note: 超时会 kill 进程并 `waitUntilExit()` 回收，再关闭所有句柄；
    ///   早期版本只 kill 不回收，假死盘每轮卸载超时都会留下僵尸进程和两个挂起线程。
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 30,
                    input: String? = nil) -> ShellResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        // 传了 input 才接管道；否则接 /dev/null，不然 smbutil 这类命令会一直等标准输入
        var inputPipe: Pipe?
        if input != nil {
            let p = Pipe()
            inputPipe = p
            proc.standardInput = p
        } else {
            proc.standardInput = FileHandle.nullDevice
        }

        do {
            try proc.run()
        } catch {
            return ShellResult(status: -1, out: "", err: error.localizedDescription)
        }

        let outBuffer = ShellOutputBuffer()
        let errBuffer = ShellOutputBuffer()
        let group = DispatchGroup()

        func attach(_ pipe: Pipe, _ buffer: ShellOutputBuffer) {
            group.enter()
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty {
                    h.readabilityHandler = nil
                    buffer.finish(group)
                } else {
                    buffer.append(chunk)
                }
            }
        }
        attach(outPipe, outBuffer)
        attach(errPipe, errBuffer)

        // 必须等 stdout/stderr 的读句柄起来之后再写 stdin。
        // 反过来的话，子进程「边读 stdin 边写 stdout」时会互相等死：
        // 它写满 64KB 输出管道就停下来不再读输入，我们也写不进 64KB 输入管道。
        if let input, let inputPipe {
            DispatchQueue.global(qos: .utility).async {
                try? inputPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                try? inputPipe.fileHandleForWriting.close()
            }
        }

        let cleanup = {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            // 强制收尾：即使某个 EOF 回调还没来，也不能让 group 悬着
            outBuffer.finish(group)
            errBuffer.finish(group)
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            try? inputPipe?.fileHandleForWriting.close()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if proc.isRunning {
            proc.terminate()
            usleep(200_000)
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            // 回收子进程：不 waitUntilExit 会留下僵尸进程，直到 App 退出
            proc.waitUntilExit()
            _ = group.wait(timeout: .now() + 1)
            cleanup()
            Diagnostics.log("命令超时：\(path) \(args.joined(separator: " "))（\(Int(timeout))s）")
            // 超时不回传 stderr：osascript 的报错可能回显带密码的脚本文本
            return ShellResult(status: -2, out: "", err: "命令超时（\(Int(timeout)) 秒）")
        }

        proc.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)
        let outData = outBuffer.snapshot()
        let errData = errBuffer.snapshot()
        cleanup()

        return ShellResult(
            status: proc.terminationStatus,
            out: decode(outData),
            err: decode(errData)
        )
    }

    /// 输出解码：严格 UTF-8 失败时做「有损」解码。
    ///
    /// 不能用 `?? ""`：`mount` 表里只要出现一个非 UTF-8 字节，整段输出就变成空串，
    /// MountScanner 会以为所有盘都没挂，看门狗跟着误判掉线、把好端端的盘重挂一遍。
    private static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}
