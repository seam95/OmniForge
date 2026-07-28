import Foundation

enum BatteryTimeSupport {
    static func remainingSeconds(timeToEmptyMinutes: Int?,
                                 externalConnected: Bool,
                                 isCharging: Bool) -> TimeInterval? {
        guard !externalConnected, !isCharging,
              let minutes = timeToEmptyMinutes,
              (1..<(7 * 24 * 60)).contains(minutes) else { return nil }
        return TimeInterval(minutes * 60)
    }
}
