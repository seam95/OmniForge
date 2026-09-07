import Foundation

/// SMC 键值读取边界；供采样器注入使用（主应用与特权 Helper 共享）。
public protocol SMCReading: AnyObject {
    func value(forKey key: String) -> Double?
}
