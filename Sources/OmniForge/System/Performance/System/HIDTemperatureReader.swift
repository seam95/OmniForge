import Foundation
import CoreFoundation
import IOKit

protocol HIDTemperatureReading: AnyObject {
    func sampleCPU() -> Double?
    func sampleGPU() -> Double?
    func sampleBattery() -> Double?
}

/// 基于 IOHIDEventSystem 的硬件温度读取器。
/// 在 Apple Silicon 架构下，驱动层（AppleSMCSensorDispatcher）将热传感器发布至
/// IOHIDEventSystem（PrimaryUsagePage=0xFF00, PrimaryUsage=5）。
/// 相比传统 SMC 用户态接口，该通道在 Hardened Runtime 与非沙盒普通用户权限下均可原生稳定访问。
final class HIDTemperatureReader: HIDTemperatureReading {
    static let shared = HIDTemperatureReader()

    private typealias IOHIDEventSystemClientRef = CFTypeRef
    private typealias IOHIDServiceClientRef = CFTypeRef
    private typealias IOHIDEventRef = CFTypeRef

    @_silgen_name("IOHIDEventSystemClientCreate")
    private static func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> IOHIDEventSystemClientRef?

    @_silgen_name("IOHIDEventSystemClientSetMatching")
    private static func IOHIDEventSystemClientSetMatching(_ client: IOHIDEventSystemClientRef, _ matches: CFDictionary) -> Void

    @_silgen_name("IOHIDEventSystemClientCopyServices")
    private static func IOHIDEventSystemClientCopyServices(_ client: IOHIDEventSystemClientRef) -> CFArray?

    @_silgen_name("IOHIDServiceClientCopyProperty")
    private static func IOHIDServiceClientCopyProperty(_ service: IOHIDServiceClientRef, _ key: CFString) -> CFTypeRef?

    @_silgen_name("IOHIDServiceClientCopyEvent")
    private static func IOHIDServiceClientCopyEvent(_ service: IOHIDServiceClientRef, _ type: Int64, _ options: Int32, _ matching: Int64) -> IOHIDEventRef?

    @_silgen_name("IOHIDEventGetFloatValue")
    private static func IOHIDEventGetFloatValue(_ event: IOHIDEventRef, _ field: UInt32) -> Double

    private static let eventTypeTemperature: Int64 = 15
    private static let eventFieldTemperatureLevel: UInt32 = UInt32(15 << 16)

    private var client: IOHIDEventSystemClientRef?
    private var cpuServices: [IOHIDServiceClientRef] = []
    private var gpuServices: [IOHIDServiceClientRef] = []
    private var batteryServices: [IOHIDServiceClientRef] = []
    private var hasDiscovered = false
    private var lock = os_unfair_lock()

    init() {
        discoverServicesIfNeeded()
    }

    private func discoverServicesIfNeeded() {
        guard !hasDiscovered else { return }
        guard let client = Self.IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            hasDiscovered = true
            return
        }
        self.client = client
        let matchingDict: [String: Any] = [
            "PrimaryUsagePage": 0xFF00,
            "PrimaryUsage": 5
        ]
        Self.IOHIDEventSystemClientSetMatching(client, matchingDict as CFDictionary)
        refreshServicesLocked()
        hasDiscovered = true
    }

    private func refreshServicesLocked() {
        guard let client = self.client else { return }
        guard let rawServices = Self.IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClientRef] else {
            return
        }

        cpuServices.removeAll()
        gpuServices.removeAll()
        batteryServices.removeAll()

        for service in rawServices {
            let name = (Self.IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String)
                ?? (Self.IOHIDServiceClientCopyProperty(service, "Transport" as CFString) as? String)
                ?? ""
            let lower = name.lowercased()
            if lower.contains("pacc") || lower.contains("eacc") || lower.contains("cpu") {
                cpuServices.append(service)
            } else if lower.contains("gpu") || lower.contains("gfx") {
                gpuServices.append(service)
            } else if lower.contains("gas gauge") || lower.contains("battery") {
                batteryServices.append(service)
            }
        }
    }

    func sampleCPU() -> Double? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        discoverServicesIfNeeded()
        if let val = readMax(services: cpuServices) {
            return val
        }
        refreshServicesLocked()
        return readMax(services: cpuServices)
    }

    func sampleGPU() -> Double? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        discoverServicesIfNeeded()
        if let val = readMax(services: gpuServices) {
            return val
        }
        refreshServicesLocked()
        return readMax(services: gpuServices)
    }

    func sampleBattery() -> Double? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        discoverServicesIfNeeded()
        if let val = readMax(services: batteryServices) {
            return val
        }
        refreshServicesLocked()
        return readMax(services: batteryServices)
    }

    private func readMax(services: [IOHIDServiceClientRef]) -> Double? {
        var maxValue: Double?
        for service in services {
            autoreleasepool {
                guard let event = Self.IOHIDServiceClientCopyEvent(service, Self.eventTypeTemperature, 0, 0) else {
                    return
                }
                let temp = Self.IOHIDEventGetFloatValue(event, Self.eventFieldTemperatureLevel)
                guard temp > 1.0 && temp < 125.0 else { return }
                if let current = maxValue {
                    if temp > current { maxValue = temp }
                } else {
                    maxValue = temp
                }
            }
        }
        return maxValue
    }
}
