import Foundation
import Combine

// MARK: - Sampler 协议（所有采样器必须实现）

protocol CPUUsageSampling: AnyObject {
    func sample() throws -> CPUUsageReading?
}

protocol GPUUsageSampling: AnyObject {
    func sample() throws -> Double?
}

protocol MemorySampling: AnyObject {
    func sample() throws -> MemoryReading
}

protocol TemperatureSampling: AnyObject {
    func sampleCPU() throws -> Double?
    func sampleGPU() throws -> Double?
    func sampleBattery() throws -> Double?
}

protocol NetworkSampling: AnyObject {
    func sample(now: TimeInterval) throws -> NetworkReading
}

protocol DiskSampling: AnyObject {
    func sample(now: TimeInterval, refreshMetadata: Bool) throws -> DiskReading
}

protocol PowerSampling: AnyObject {
    func sample() throws -> PowerReading
}

protocol PeripheralBatterySampling: AnyObject {
    func sample(now: TimeInterval) throws -> [PeripheralBatteryDevice]
}

protocol ProcessUsageSampling: AnyObject {
    func sample(_ kind: ProcessMetricKind, limit: Int) throws -> [ProcessUsage]
    func stop(_ kind: ProcessMetricKind)
    /// 提前为 delta 类指标（GPU/网络）建立基线，首次展开即可直接产出数据。
    /// 非 delta 指标（CPU/内存/energy）默认 no-op。
    func primeProcessBaselines(for kinds: [ProcessMetricKind])
    /// 下次 `sample` 能否产出真实数据（而非仅 prime 基线返回空）。
    /// delta 类指标在未建立基线时返回 false；瞬时值指标始终返回 true。
    func hasProcessBaseline(for kind: ProcessMetricKind) -> Bool
}

extension ProcessUsageSampling {
    func primeProcessBaselines(for kinds: [ProcessMetricKind]) {}
    func hasProcessBaseline(for kind: ProcessMetricKind) -> Bool { true }
}

// MARK: - 基础设施协议

/// 通用用户通知投递边界；保持唤醒与系统监控共用。
protocol UserNotificationPosting: AnyObject {
    func post(title: String, body: String, completion: @escaping (Result<Void, Error>) -> Void)
}

protocol MonitorNotificationClient: UserNotificationPosting {
    func requestAuthorization(completion: @escaping (Result<Void, Error>) -> Void)
}

protocol RepeatingScheduling: AnyObject {
    func schedule(every interval: TimeInterval, _ action: @escaping () -> Void) -> AnyCancellable
}

protocol MonitorExecuting: AnyObject {
    func execute(_ action: @escaping () -> Void)
}

protocol MaxCapacityProbing: AnyObject {
    var percent: Int? { get }
    func refreshIfStale()
}

protocol SMCReading: AnyObject {
    func value(forKey key: String) -> Double?
}
