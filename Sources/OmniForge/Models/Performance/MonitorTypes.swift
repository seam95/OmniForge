import Foundation

// MARK: - 监控基础类型

/// 采样错误类型：直接暴露，不静默回退
enum MetricSamplingError: Error, Equatable {
    case unsupported(String)
    case systemCall(String)
    case invalidData(String)
}

/// 指标问题记录
enum MetricIssue: Equatable {
    case unsupported(String)
    case failed(String)
}

/// 可监控的指标枚举
enum MonitorMetric: String, CaseIterable, Hashable, Codable {
    case cpu, gpu, memory, network, disk, power, peripheralBattery
    case cpuTemperature, gpuTemperature, batteryTemperature
}

/// 监控面板分区
enum MonitorSection: String, CaseIterable, Hashable, Codable {
    case system, network, disk, power
}

/// 进程排行指标类型 — 一次只能展开一种
enum ProcessMetricKind: String, CaseIterable, Hashable, Codable {
    case cpu, gpu, memory, network, energy
}

/// 菜单栏指标间距
enum MenuBarMetricSpacing: String, CaseIterable, Codable {
    case standard, compact
}

/// 测速状态
enum SpeedTestState: Equatable {
    case idle
    case running(progress: Double)
    case finished(downBytesPerSec: Double, upBytesPerSec: Double)
    case failed(String)
}

/// 温度单位
enum TemperatureUnit: String, CaseIterable, Equatable, Codable {
    case celsius, fahrenheit
}

/// 内存压力等级
enum MemoryPressure: UInt32, Equatable, Codable {
    case unknown = 0
    case normal = 1
    case warning = 2
    case critical = 4
}

/// CPU 使用率读数 — 总量与系统/用户拆分（占比 0...1）
struct CPUUsageReading: Equatable {
    /// 非空闲总占比（busy/total，含 nice），语义同原 cpuUsage
    var total: Double
    /// 用户态占比（deltaUser/deltaTotal）
    var user: Double
    /// 系统态占比（(deltaSystem+deltaNice)/deltaTotal；nice 并入系统，user+system==total）
    var system: Double
}

extension MemoryPressure {
    init(kernelLevel: Int32) {
        switch kernelLevel {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }
}

/// 菜单栏内存显示样式
enum MemoryMenuBarStyle: String, CaseIterable, Codable {
    case percent, used, pressure
}

/// 菜单栏预测（密度预设）
enum MenuBarPreset: String, CaseIterable, Codable {
    case dense, standard
}

// MARK: - 子读数类型

/// 温度读数
struct TemperatureReading: Equatable {
    let value: Double
    let unit: TemperatureUnit
}

/// 内存读数
struct MemoryReading: Equatable {
    let used: UInt64
    let total: UInt64
    let pressure: MemoryPressure
}

/// 网络读数
struct NetworkReading: Equatable {
    let downBytesPerSec: Double?
    let upBytesPerSec: Double?
    let totalDown: UInt64
    let totalUp: UInt64
}

/// SMART 读数（diskutil SMARTStatus + VendorSpecificSMARTKeys）
struct DiskSMARTReading: Equatable {
    var status: String?
    var totalReadBytes: UInt64?
    var totalWrittenBytes: UInt64?
    var temperatureCelsius: Double?
    var healthPercent: Int?
    var powerCycles: UInt64?
    var powerOnHours: UInt64?
    var unsafeShutdowns: UInt64?
    var mediaErrors: UInt64?

    var hasDetails: Bool {
        status != nil || totalReadBytes != nil || totalWrittenBytes != nil
            || temperatureCelsius != nil || healthPercent != nil
            || powerCycles != nil || powerOnHours != nil
            || unsafeShutdowns != nil || mediaErrors != nil
    }
}

/// 单个已挂载卷读数
struct DiskDeviceReading: Equatable, Identifiable {
    var id: String
    var name: String
    var mountPath: String
    var bsdName: String? = nil
    var wholeDisk: String? = nil
    var ioCounterID: String? = nil
    var totalBytes: UInt64
    var freeBytes: UInt64
    var usedBytes: UInt64
    var isInternal: Bool
    var isRemovable: Bool = false
    var isEjectable: Bool = false
    var fileSystem: String? = nil
    var smart: DiskSMARTReading? = nil
    var readBytesPerSec: Double?
    var writeBytesPerSec: Double?
    var totalReadBytes: UInt64?
    var totalWrittenBytes: UInt64?

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    var ejectBSDName: String? { wholeDisk ?? bsdName }

    var canEject: Bool {
        !isInternal && (isEjectable || isRemovable) && ejectBSDName != nil
    }
}

/// 物理盘读数（同 wholeDisk 多卷聚合）
struct PhysicalDiskReading: Equatable, Identifiable {
    var id: String
    var name: String
    var wholeDisk: String?
    var isInternal: Bool
    var primaryMountPath: String
    var totalBytes: UInt64
    var freeBytes: UInt64
    var usedBytes: UInt64
    var fileSystem: String?
    var smart: DiskSMARTReading?
    var readBytesPerSec: Double?
    var writeBytesPerSec: Double?
    var totalReadBytes: UInt64?
    var totalWrittenBytes: UInt64?
    var volumes: [DiskDeviceReading]
    var isRemovable: Bool
    var isEjectable: Bool

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    var ejectBSDName: String? { wholeDisk ?? volumes.first?.ejectBSDName }

    var canEject: Bool {
        !isInternal && (isEjectable || isRemovable) && ejectBSDName != nil
    }
}

/// 磁盘读数（多卷 + 兼容聚合字段，供菜单栏/告警使用）
struct DiskReading: Equatable {
    var devices: [DiskDeviceReading] = []
    var physicalDisks: [PhysicalDiskReading] = []
    /// 兼容聚合字段：unique IO 汇总速率
    var readBytesPerSec: Double
    var writeBytesPerSec: Double
    var totalRead: UInt64
    var totalWritten: UInt64
    /// 优先 internal root 卷
    var freeSpace: UInt64?
    var totalSpace: UInt64?
}

/// 电源读数
struct PowerReading: Equatable {
    var isCharging = false
    var chargePercent: Int?
    var batteryLevel: Double?
    var cycleCount: UInt64?
    var healthPercent: Double?
    var timeRemaining: TimeInterval?
    var batteryWatts: Double?
    var adapterWatts: Double?
    var adapterMaxWatts: Double?
    var systemWatts: Double?
    var externalConnected = false
    var hasBattery = false
    var batteryTemperature: Double?
}

/// 外设电池设备
struct PeripheralBatteryDevice: Equatable, Identifiable {
    let id: String
    let name: String
    let level: Double
    let isCharging: Bool
}

// MARK: - 菜单栏指标项

/// 菜单栏可显示的指标
enum MenuBarMetric: String, CaseIterable, Hashable, Codable {
    case cpu, gpu, memory, network, disk, power, battery
    case cpuTemperature, gpuTemperature, batteryTemperature
    case peripheralBattery, date

    static let defaultOrder: [MenuBarMetric] = [
        .cpu, .gpu, .memory, .network, .disk, .power,
        .battery, .cpuTemperature, .gpuTemperature,
        .batteryTemperature, .peripheralBattery, .date
    ]

    /// 设置页/菜单栏指标展示名。CPU/GPU 保留术语，其余走本地化。
    func title(in strings: Strings) -> String {
        switch self {
        case .cpu: return strings.menubarMetricCPU
        case .gpu: return strings.menubarMetricGPU
        case .memory: return strings.menubarMetricMemory
        case .network: return strings.menubarMetricNetwork
        case .disk: return strings.menubarMetricDisk
        case .power: return strings.menubarMetricPower
        case .battery: return strings.menubarMetricBattery
        case .cpuTemperature: return strings.menubarMetricCPUTemperature
        case .gpuTemperature: return strings.menubarMetricGPUTemperature
        case .batteryTemperature: return strings.menubarMetricBatteryTemperature
        case .peripheralBattery: return strings.menubarMetricPeripheralBattery
        case .date: return strings.menubarMetricDate
        }
    }
}

// MARK: - 监控需求掩码

/// 当前需要采集哪些指标：面板打开或菜单栏启用时设置
struct MonitorDemand: Equatable {
    var system = false
    var network = false
    var disk = false
    var power = false
    var cpu = false
    var gpu = false
    var memory = false
    var battery = false
    var peripheralBattery = false
    var cpuTemperature = false
    var gpuTemperature = false
    var batteryTemperature = false

    static let none = MonitorDemand()
}
