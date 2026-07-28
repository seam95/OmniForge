import XCTest
@testable import OmniForge

final class ProcessUsageRankRowTests: XCTestCase {
    func test_shareFraction() {
        XCTAssertEqual(ProcessUsageShare.fraction(value: 25, maxValue: 50), 0.5, accuracy: 0.0001)
        XCTAssertEqual(ProcessUsageShare.fraction(value: 10, maxValue: 0), 0)
        XCTAssertEqual(ProcessUsageShare.fraction(value: 80, maxValue: 40), 1.0, accuracy: 0.0001)
    }

    func test_shareFraction_clampsNegativeAndBelowZeroValue() {
        XCTAssertEqual(ProcessUsageShare.fraction(value: -5, maxValue: 10), 0, accuracy: 0.0001)
        XCTAssertEqual(ProcessUsageShare.fraction(value: 0, maxValue: 10), 0, accuracy: 0.0001)
    }

    func test_valueText_cpuGpuEnergyPercent() {
        let proc = ProcessUsage(pid: 1, name: "X", value: 12.34)
        XCTAssertEqual(ProcessUsageFormatting.valueText(for: proc, kind: .cpu), "12.3%")
        XCTAssertEqual(ProcessUsageFormatting.valueText(for: proc, kind: .gpu), "12.3%")
        XCTAssertEqual(ProcessUsageFormatting.valueText(for: proc, kind: .energy), "12.3%")
    }

    func test_valueText_memoryBytes() {
        let proc = ProcessUsage(pid: 2, name: "Mem", value: 1_048_576)
        XCTAssertEqual(
            ProcessUsageFormatting.valueText(for: proc, kind: .memory),
            MetricFormat.bytes(UInt64(1_048_576))
        )
    }

    func test_valueText_networkDownUp() {
        let proc = ProcessUsage(
            pid: 3,
            name: "Net",
            value: 1500,
            networkDownBytesPerSec: 1_500,
            networkUpBytesPerSec: 500
        )
        let expectedDown = MetricFormat.bytesPerSec(1_500 as Double)
        let expectedUp = MetricFormat.bytesPerSec(500 as Double)
        XCTAssertEqual(
            ProcessUsageFormatting.valueText(for: proc, kind: .network),
            "↓\(expectedDown) ↑\(expectedUp)"
        )
    }

    func test_valueText_networkMissingRatesUsesPlaceholder() {
        let proc = ProcessUsage(pid: 4, name: "Net", value: 0)
        XCTAssertEqual(
            ProcessUsageFormatting.valueText(for: proc, kind: .network),
            "↓-- ↑--"
        )
    }

    func test_iconHeuristic_terminalAndDefault() {
        XCTAssertEqual(ProcessUsageIcon.systemImage(forProcessName: "Terminal"), "terminal")
        XCTAssertEqual(ProcessUsageIcon.systemImage(forProcessName: "zsh"), "terminal")
        XCTAssertEqual(ProcessUsageIcon.systemImage(forProcessName: "SomeApp"), "app")
    }
}
