import Foundation
import Combine

/// 网络速度测试（最小可用：下载测速；上传二期）
final class SpeedTest: NSObject {
    private let sessionConfig: URLSessionConfiguration
    private let endpoint: URL
    private var currentTask: URLSessionDataTask?
    /// 递增 generation，避免 cancel/restart 的过期回调改写 state
    private var generation: UInt64 = 0

    @Published private(set) var state: SpeedTestState = .idle

    init(
        sessionConfig: URLSessionConfiguration = .default,
        endpoint: URL = URL(string: "https://example.com")!
    ) {
        self.sessionConfig = sessionConfig
        self.endpoint = endpoint
    }

    /// 启动下载测速；state 依次为 running → finished / failed
    func start() {
        cancel()
        generation &+= 1
        let runID = generation
        state = .running(progress: 0)
        let session = URLSession(configuration: sessionConfig)
        let start = Date()
        let task = session.dataTask(with: endpoint) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                // 仅处理当前 generation，避免 cancel/restart 竞态
                guard self.generation == runID else { return }
                self.currentTask = nil
                if let error {
                    self.state = .failed(error.localizedDescription)
                    return
                }
                let elapsed = max(Date().timeIntervalSince(start), 0.001)
                let bytes = Double(data?.count ?? 0)
                let down = bytes / elapsed
                // 上传可二期；先 down 有值，up = 0
                self.state = .finished(downBytesPerSec: down, upBytesPerSec: 0)
            }
        }
        currentTask = task
        task.resume()
    }

    func startDownload() {
        start()
    }

    func startUpload() {}

    func cancel() {
        generation &+= 1
        currentTask?.cancel()
        currentTask = nil
        if case .running = state {
            state = .idle
        }
    }
}
