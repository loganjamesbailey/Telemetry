import XCTest
@testable import TelemetryShared

final class CurveTests: XCTestCase {
    private let points = [
        CurvePoint(tempC: 50, rpm: 1200),
        CurvePoint(tempC: 70, rpm: 3000),
        CurvePoint(tempC: 90, rpm: 7199),
    ]

    private func makeCurve(hybrid: HybridAutoConfig? = nil) -> FanCurve {
        FanCurve(
            name: "test", input: .virtual("CPU Hottest"), points: points,
            hysteresisC: 3, minDwellSeconds: 8, hybridAuto: hybrid
        )
    }

    // MARK: - Interpolation

    func testInterpolationEndsAndMidpoints() {
        XCTAssertEqual(CurveMath.targetRPM(curve: points, tempC: 30), 1200)  // below first
        XCTAssertEqual(CurveMath.targetRPM(curve: points, tempC: 50), 1200)
        XCTAssertEqual(CurveMath.targetRPM(curve: points, tempC: 60), 2100)  // halfway 50→70
        XCTAssertEqual(CurveMath.targetRPM(curve: points, tempC: 70), 3000)
        XCTAssertEqual(CurveMath.targetRPM(curve: points, tempC: 80), 5099.5)
        XCTAssertEqual(CurveMath.targetRPM(curve: points, tempC: 95), 7199)  // above last
    }

    func testDuplicateTemperatureSteps() {
        let dup = [
            CurvePoint(tempC: 60, rpm: 2000),
            CurvePoint(tempC: 60, rpm: 4000),
        ]
        XCTAssertEqual(CurveMath.targetRPM(curve: dup, tempC: 60), 2000)
        XCTAssertEqual(CurveMath.targetRPM(curve: dup, tempC: 60.5), 4000)
    }

    // MARK: - Sanitization

    func testSanitizeSortsClampsAndBounds() {
        var curve = makeCurve()
        curve.points = [
            CurvePoint(tempC: 90, rpm: 20000),   // rpm above max
            CurvePoint(tempC: 40, rpm: 100),     // rpm below min
            CurvePoint(tempC: -5, rpm: 3000),    // temp below 0
        ]
        let s = curve.sanitized(minRPM: 1199, maxRPM: 7199)
        XCTAssertEqual(s.points.map(\.tempC), [0, 40, 90])
        XCTAssertEqual(s.points[0].rpm, 3000)
        XCTAssertEqual(s.points[1].rpm, 1199)
        XCTAssertEqual(s.points[2].rpm, 7199)
    }

    func testSanitizeEnforcesHybridGap() {
        var curve = makeCurve(hybrid: HybridAutoConfig(releaseBelowC: 55, reacquireAboveC: 55))
        curve = curve.sanitized(minRPM: 1199, maxRPM: 7199)
        XCTAssertEqual(curve.hybridAuto?.reacquireAboveC, 57)  // ≥ release + 2
    }

    // MARK: - Runtime: basic control

    func testFirstTickAlwaysSends() {
        var rt = CurveRuntime(curve: makeCurve())
        XCTAssertEqual(rt.step(tempC: 60, now: t(0)), .set(rpm: 2100))
    }

    func testSmallDeltaSuppressed() {
        var rt = CurveRuntime(curve: makeCurve())
        _ = rt.step(tempC: 60, now: t(0))          // 2100
        // 60.4 °C → 2136 RPM: Δ 36 < 50, noise.
        XCTAssertEqual(rt.step(tempC: 60.4, now: t(5)), .none)
    }

    func testSpinUpIsPrompt() {
        var rt = CurveRuntime(curve: makeCurve())
        _ = rt.step(tempC: 60, now: t(0))
        // Big jump up moves immediately after the 2 s send floor.
        XCTAssertEqual(rt.step(tempC: 75, now: t(3)), .set(rpm: 4049.75))
    }

    func testSendIntervalFloorAppliesEvenToIncreases() {
        var rt = CurveRuntime(curve: makeCurve())
        _ = rt.step(tempC: 60, now: t(0))
        XCTAssertEqual(rt.step(tempC: 75, now: t(1)), .none)  // < 2 s since last send
        XCTAssertEqual(rt.step(tempC: 75, now: t(2.5)), .set(rpm: 4049.75))
    }

    func testSpinDownRequiresHysteresisAndDwell() {
        var rt = CurveRuntime(curve: makeCurve())
        _ = rt.step(tempC: 75, now: t(0))                       // 4049.75
        // Temp falls 2 °C — inside 3 °C hysteresis: hold.
        XCTAssertEqual(rt.step(tempC: 73, now: t(10)), .none)
        // Falls beyond hysteresis: allowed (first decrease has no dwell anchor).
        XCTAssertEqual(rt.step(tempC: 65, now: t(12)), .set(rpm: 2550))
        // Another quick fall: dwell (8 s) not elapsed since last decrease.
        XCTAssertEqual(rt.step(tempC: 55, now: t(15)), .none)
        // After dwell: proceeds.
        XCTAssertEqual(rt.step(tempC: 55, now: t(21)), .set(rpm: 1650))
    }

    func testPingPongAtKneeSuppressed() {
        var rt = CurveRuntime(curve: makeCurve())
        _ = rt.step(tempC: 70, now: t(0))  // 3000
        // Oscillate ±1 °C around the knee: nothing should be sent either way —
        // the up-deadband suppresses the noise-ratchet on the steep segment.
        for (i, temp) in [69.0, 71.0, 69.5, 70.5, 69.0].enumerated() {
            XCTAssertEqual(rt.step(tempC: temp, now: t(Double(3 + i * 3))), .none, "temp \(temp)")
        }
        // A genuine 2 °C rise clears the deadband and spins up promptly.
        XCTAssertEqual(rt.step(tempC: 72, now: t(30)), .set(rpm: 3419.9))
    }

    // MARK: - Runtime: hybrid-auto

    private var hybridCurve: FanCurve {
        makeCurve(hybrid: HybridAutoConfig(releaseBelowC: 45, reacquireAboveC: 55, releaseDelaySeconds: 30))
    }

    func testHybridReleasesAfterSustainedCool() {
        var rt = CurveRuntime(curve: hybridCurve)
        _ = rt.step(tempC: 60, now: t(0))
        // Below threshold: timer starts, and the curve still follows down —
        // the fan tracks toward min while waiting to release.
        XCTAssertEqual(rt.step(tempC: 40, now: t(10)), .set(rpm: 1200))
        XCTAssertEqual(rt.step(tempC: 40, now: t(25)), .none)   // 15 s below — not yet
        XCTAssertEqual(rt.step(tempC: 40, now: t(41)), .release)  // 31 s below
        XCTAssertEqual(rt.phase, .released)
    }

    func testHybridBlipResetsReleaseTimer() {
        var rt = CurveRuntime(curve: hybridCurve)
        _ = rt.step(tempC: 60, now: t(0))
        XCTAssertEqual(rt.step(tempC: 40, now: t(10)), .set(rpm: 1200))  // timer starts at 10
        _ = rt.step(tempC: 50, now: t(20))                       // blip above release
        XCTAssertEqual(rt.step(tempC: 40, now: t(45)), .none)   // timer restarted at 45
        XCTAssertEqual(rt.step(tempC: 40, now: t(80)), .release)
    }

    func testHybridReacquires() {
        var rt = CurveRuntime(curve: hybridCurve)
        _ = rt.step(tempC: 60, now: t(0))
        _ = rt.step(tempC: 40, now: t(10))
        _ = rt.step(tempC: 40, now: t(50))  // released
        XCTAssertEqual(rt.phase, .released)
        XCTAssertEqual(rt.step(tempC: 50, now: t(60)), .none)   // between thresholds: stay auto
        XCTAssertEqual(rt.step(tempC: 56, now: t(70)), .set(rpm: 1740))  // reacquired
        XCTAssertEqual(rt.phase, .controlling)
    }

    func testResetSendStateResends() {
        var rt = CurveRuntime(curve: makeCurve())
        _ = rt.step(tempC: 60, now: t(0))
        XCTAssertEqual(rt.step(tempC: 60, now: t(5)), .none)
        rt.resetSendState()  // daemon dropped us (sleep, lease lapse)
        XCTAssertEqual(rt.step(tempC: 60, now: t(10)), .set(rpm: 2100))
    }

    private func t(_ seconds: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }
}
