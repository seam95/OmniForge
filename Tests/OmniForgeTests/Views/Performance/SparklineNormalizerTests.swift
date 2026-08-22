import XCTest
@testable import OmniForge

final class SparklineNormalizerTests: XCTestCase {
    private func assertEqual(
        _ result: [Double],
        _ expected: [Double],
        accuracy: Double = 0.0001,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(result.count, expected.count, file: file, line: line)
        for (actual, want) in zip(result, expected) {
            XCTAssertEqual(actual, want, accuracy: accuracy, file: file, line: line)
        }
    }

    func test_emptyValuesReturnsEmpty() {
        XCTAssertTrue(SparklineNormalizer.normalize(values: [], domain: 0...1).isEmpty)
    }

    func test_mapsWithinDomain() {
        assertEqual(SparklineNormalizer.normalize(values: [0.25, 0.5, 1.0], domain: 0...1), [0.25, 0.5, 1.0])
    }

    func test_clampsOutOfDomainValues() {
        assertEqual(SparklineNormalizer.normalize(values: [-0.5, 0.5, 1.5], domain: 0...1), [0, 0.5, 1])
    }

    func test_singleValueMapsToPoint() {
        assertEqual(SparklineNormalizer.normalize(values: [0.8], domain: 0...1), [0.8])
    }

    func test_constantValuesWithZeroSpanUsesMidpoint() {
        // domain 退化为单点 → 除零兜底：全部映射到中点
        assertEqual(SparklineNormalizer.normalize(values: [0.5, 0.5, 0.5], domain: 0.5...0.5), [0.5, 0.5, 0.5])
    }

    func test_customDomain() {
        assertEqual(SparklineNormalizer.normalize(values: [0, 500, 1000], domain: 0...1000), [0, 0.5, 1])
    }
}
