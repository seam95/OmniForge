import XCTest
@testable import OmniForge

final class ShelfShakeDetectorTests: XCTestCase {

    /// Zigzag: left-right-left-right with ample travel in a short window.
    private func zigzagSamples(start: TimeInterval = 10,
                               startX: CGFloat = 0,
                               amplitude: CGFloat = 80,
                               step: TimeInterval = 0.05) -> [ShelfShakeSample] {
        // 5 samples → 4 segments; with alternating direction → 3 reversals.
        // travel = 4 * amplitude (if each step is full amplitude).
        var samples: [ShelfShakeSample] = []
        var x = startX
        var t = start
        var sign: CGFloat = 1
        for i in 0..<5 {
            samples.append(ShelfShakeSample(t: t, x: x))
            if i < 4 {
                x += sign * amplitude
                sign = -sign
                t += step
            }
        }
        return samples
    }

    func test_shouldSummon_true_forStrongZigzag() {
        let samples = zigzagSamples()
        let now = samples.last!.t
        XCTAssertTrue(ShelfShakeDetector.shouldSummon(samples: samples, now: now, lastSummon: 0))
    }

    func test_shouldSummon_false_whenTooFewSamples() {
        let samples = [
            ShelfShakeSample(t: 1.0, x: 0),
            ShelfShakeSample(t: 1.05, x: 100),
            ShelfShakeSample(t: 1.10, x: 0),
            ShelfShakeSample(t: 1.15, x: 100),
        ]
        XCTAssertFalse(ShelfShakeDetector.shouldSummon(samples: samples, now: 1.15, lastSummon: 0))
    }

    func test_shouldSummon_false_whenTravelTooLow() {
        // Small amplitude: 4 * 20 = 80 < 220
        let samples = zigzagSamples(amplitude: 20)
        let now = samples.last!.t
        XCTAssertFalse(ShelfShakeDetector.shouldSummon(samples: samples, now: now, lastSummon: 0))
    }

    func test_shouldSummon_false_whenNotEnoughReversals() {
        // Monotonic travel: lots of distance, zero reversals.
        let samples = (0..<6).map { i in
            ShelfShakeSample(t: 10 + TimeInterval(i) * 0.05, x: CGFloat(i) * 100)
        }
        XCTAssertFalse(ShelfShakeDetector.shouldSummon(samples: samples, now: 10.25, lastSummon: 0))
    }

    func test_shouldSummon_false_withinCooldown() {
        let samples = zigzagSamples(start: 10)
        let now = samples.last!.t
        // lastSummon only 0.5s ago (< 1s cooldown)
        XCTAssertFalse(ShelfShakeDetector.shouldSummon(samples: samples, now: now, lastSummon: now - 0.5))
    }

    func test_shouldSummon_true_afterCooldown() {
        let samples = zigzagSamples(start: 10)
        let now = samples.last!.t
        XCTAssertTrue(ShelfShakeDetector.shouldSummon(samples: samples, now: now, lastSummon: now - 1.01))
    }

    func test_shouldSummon_ignoresSamplesOutsideWindow() {
        // Old zigzag outside 0.5s + one recent sample → not enough in window.
        var samples = zigzagSamples(start: 1.0)
        samples.append(ShelfShakeSample(t: 2.0, x: 0))
        samples.append(ShelfShakeSample(t: 2.05, x: 100))
        XCTAssertFalse(ShelfShakeDetector.shouldSummon(samples: samples, now: 2.05, lastSummon: 0))
    }

    func test_shouldSummon_false_whenDirectionsBelowThreshold() {
        // dx of 5 < directionThreshold 6 → no counted directions/reversals.
        let samples = zigzagSamples(amplitude: 5)
        let now = samples.last!.t
        XCTAssertFalse(ShelfShakeDetector.shouldSummon(samples: samples, now: now, lastSummon: 0))
    }
}
