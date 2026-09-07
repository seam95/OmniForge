import Foundation
import OmniForgeSMC

// 特权风扇 Helper 入口：launchd 按 plist 拉起，经 MachServices 监听 XPC。

let delegate = FanHelperDelegate()
let listener = NSXPCListener(machServiceName: kFanHelperMachServiceName)
listener.delegate = delegate
listener.resume()

// 终止信号处理：归还全部风扇并退出测试模式。
// 信号处理器内调用非 async-signal-safe API 并不严格合规，但此处是
// 防风扇滞留手动模式的最后防线，实践收益大于理论风险（极端情形由
// SMC 测试模式的易失性兜底：重启即恢复系统温控）。
signal(SIGTERM) { _ in FanHelperService.cleanupAndExit() }
signal(SIGINT) { _ in FanHelperService.cleanupAndExit() }

RunLoop.current.run()
