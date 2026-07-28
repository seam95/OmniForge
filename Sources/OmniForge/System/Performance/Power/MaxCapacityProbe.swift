import Foundation
import IOKit.ps

/// Reads the smoothed "Maximum Capacity" value System Information shows for the
/// internal battery. Refreshed off the hot path (cached for 5 minutes).
final class MaxCapacityProbe: MaxCapacityProbing {
    static let shared = MaxCapacityProbe()

    private var cachedPercent: Int?
    private var lastRefresh = Date.distantPast

    var percent: Int? { cachedPercent }

    func refreshIfStale() {
        guard Date().timeIntervalSince(lastRefresh) > 300 else { return }
        refresh()
    }

    private func refresh() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            cachedPercent = nil
            return
        }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [AnyObject],
              let firstSource = sources.first else {
            cachedPercent = nil
            return
        }
        let raw = IOPSGetPowerSourceDescription(snapshot, firstSource)?.takeUnretainedValue()
        guard let desc = raw as? [String: Any] else {
            cachedPercent = nil
            return
        }
        // IOPS "Max Capacity" is the smoothed health percent (0...100) shown in
        // System Information. Absent on desktops / machines without a battery.
        if let value = desc["Max Capacity"] as? Int {
            cachedPercent = value
        } else if let number = desc["Max Capacity"] as? NSNumber {
            cachedPercent = number.intValue
        } else {
            cachedPercent = nil
        }
        lastRefresh = Date()
    }
}
