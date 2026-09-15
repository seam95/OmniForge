import Darwin
import Foundation

/// 有界子进程执行结果：两路输出 + 退出码 + 截断标志。
struct BoundedProcessOutput: Sendable, Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    /// 任一输出流达到字节上限被截断，内容不完整；调用方不得把截断结果当完整列表。
    let truncated: Bool

    /// 退出码 0 且未截断。
    var succeeded: Bool { exitCode == 0 && !truncated }
}

/// 小型结构化进程执行边界（审查 R05）：
/// - 并发排空 stdout/stderr（readabilityHandler），消除「先等待再排空」的管道等待环；
/// - 输出每流有字节上限，达上限后继续丢弃式排空（防子进程写阻塞）并标记截断；
/// - 超时 SIGKILL 终止并回收，不无限期占用调用线程；
/// - 异步版支持 Task 取消（取消同样终止子进程）。
enum BoundedProcessRunner {
    struct Options: Sendable {
        /// 超时秒数：到点 SIGKILL 子进程并返回其退出码。
        var timeout: TimeInterval = 10
        /// 单流输出字节上限（stdout / stderr 各自计算）。
        var maxOutputBytesPerStream: Int = 4 * 1024 * 1024
    }

    // MARK: - 异步入口

    /// 异步执行：等待期间不阻塞线程；外层 Task 取消时终止子进程并抛 CancellationError。
    static func run(
        executable: URL,
        arguments: [String],
        options: Options = Options()
    ) async throws -> BoundedProcessOutput {
        let session = try LaunchSession(
            executable: executable,
            arguments: arguments,
            options: options
        )
        let runningProcess = session.process
        return try await withTaskCancellationHandler {
            // 超时守护：到点 SIGKILL（EOF 与退出随之发生，等待完成）。
            let timeoutTask = Task { [weak runningProcess] in
                try? await Task.sleep(nanoseconds: UInt64(options.timeout * 1_000_000_000))
                guard !Task.isCancelled, let process = runningProcess, process.isRunning else { return }
                kill(process.processIdentifier, SIGKILL)
            }
            defer { timeoutTask.cancel() }

            await session.waitForExit()
            try Task.checkCancellation()
            return session.collectOutput()
        } onCancel: {
            // 取消：SIGKILL 保证等待完成，主体随后抛取消错误。
            if runningProcess.isRunning {
                kill(runningProcess.processIdentifier, SIGKILL)
            }
        }
    }

    // MARK: - 同步入口

    /// 同步执行（供既有同步协议实现内部使用）：
    /// 同样并发排空与超时回收，调用线程最多阻塞到超时上限。
    /// 启动失败返回 nil。
    static func runBlocking(
        executable: URL,
        arguments: [String],
        options: Options = Options()
    ) -> BoundedProcessOutput? {
        let session: LaunchSession
        do {
            session = try LaunchSession(
                executable: executable,
                arguments: arguments,
                options: options
            )
        } catch {
            return nil
        }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + options.timeout)
        let timedProcess = session.process
        timer.setEventHandler { [weak timedProcess] in
            guard let process = timedProcess, process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }
        timer.resume()
        defer { timer.cancel() }

        session.waitBlockingForExit()
        return session.collectOutput()
    }

    // MARK: - 会话（两入口共享的排空与回收核心）

    /// 一次运行的资源与状态：进程、两路输出汇（含 EOF 信令）。
    private final class LaunchSession: @unchecked Sendable {
        let process: Process
        private let outSink: OutputSink
        private let errSink: OutputSink
        private let pipes: [Pipe]
        private let eofGroup = DispatchGroup()

        init(executable: URL, arguments: [String], options: Options) throws {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            let outPipe = Pipe()
            let errPipe = Pipe()
            outSink = OutputSink(maxBytes: options.maxOutputBytesPerStream, eofGroup: eofGroup)
            errSink = OutputSink(maxBytes: options.maxOutputBytesPerStream, eofGroup: eofGroup)
            pipes = [outPipe, errPipe]
            Self.installDrainHandler(on: outPipe, sink: outSink)
            Self.installDrainHandler(on: errPipe, sink: errSink)

            process.standardOutput = outPipe
            process.standardError = errPipe
            try process.run()
            self.process = process
        }

        /// 排空 handler：EOF 摘除自身并通知 sink（驱动 DispatchGroup leave）。
        private static func installDrainHandler(on pipe: Pipe, sink: OutputSink) {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    sink.reachEOF()
                } else {
                    sink.append(data)
                }
            }
        }

        /// 等待退出与两路 EOF（子进程退出后写端由系统关闭，EOF 必然到达；
        /// 超时/取消路径 SIGKILL 同样保证）。阻塞等待派发到全局队列，不占调用线程。
        func waitForExit() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { [self] in
                    eofGroup.wait()
                    process.waitUntilExit()
                    continuation.resume()
                }
            }
        }

        /// 同步等待退出与两路 EOF。
        func waitBlockingForExit() {
            eofGroup.wait()
            process.waitUntilExit()
        }

        /// 收集结果并关闭父端读句柄。
        func collectOutput() -> BoundedProcessOutput {
            for pipe in pipes {
                pipe.fileHandleForReading.readabilityHandler = nil
                try? pipe.fileHandleForReading.close()
            }
            return BoundedProcessOutput(
                exitCode: process.terminationStatus,
                stdout: outSink.text,
                stderr: errSink.text,
                truncated: outSink.truncated || errSink.truncated
            )
        }
    }

    /// 单流有界输出汇：达上限后丢弃式排空并标记截断；EOF 经 DispatchGroup 信令。
    private final class OutputSink: @unchecked Sendable {
        private let lock = NSLock()
        private let maxBytes: Int
        private let eofGroup: DispatchGroup
        private var buffer = Data()
        private(set) var truncated = false
        private var reachedEOF = false

        init(maxBytes: Int, eofGroup: DispatchGroup) {
            self.maxBytes = maxBytes
            self.eofGroup = eofGroup
            eofGroup.enter()
        }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            guard !reachedEOF else { return }
            let remaining = maxBytes - buffer.count
            if chunk.count > remaining {
                if remaining > 0 { buffer.append(chunk.prefix(remaining)) }
                truncated = true
            } else {
                buffer.append(chunk)
            }
        }

        /// EOF（幂等）：驱动 DispatchGroup leave。
        func reachEOF() {
            lock.lock()
            guard !reachedEOF else {
                lock.unlock()
                return
            }
            reachedEOF = true
            lock.unlock()
            eofGroup.leave()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: buffer, encoding: .utf8) ?? ""
        }
    }
}
