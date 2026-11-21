//
//  FanCurveTests.swift
//  FanMacTests
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  The Auto curve: the threshold decides where the ramp starts.
//

import XCTest
@testable import FanMac

final class FanCurveTests: XCTestCase {
    private func target(_ temperature: Double, threshold: Double = 60, response: Double = 1.5) -> Int {
        FanCurve.target(
            temperature: temperature,
            threshold: threshold,
            response: response,
            floorRPM: 2000,
            ceilingRPM: 6000
        )
    }

    func testBelowThresholdHoldsFloor() {
        XCTAssertEqual(target(45), 2000)
        XCTAssertEqual(target(60), 2000)
    }

    func testRampsFromThresholdToFullSpeedTemperature() {
        // Halfway between 60 °C and 90 °C is halfway between floor and ceiling.
        XCTAssertEqual(target(75), 4000)
        XCTAssertEqual(target(90), 6000)
        XCTAssertEqual(target(99), 6000)
    }

    func testThresholdMovesTheRamp() {
        // The defect: the curve ignored the threshold and always ramped from 30 °C.
        XCTAssertGreaterThan(target(55, threshold: 40), target(55, threshold: 60))
        XCTAssertEqual(target(55, threshold: 60), 2000)
    }

    func testThresholdAtFullSpeedTemperatureSteps() {
        XCTAssertEqual(target(89, threshold: 90), 2000)
        XCTAssertEqual(target(90, threshold: 90), 6000)
    }

    func testResponseBlendsTowardFloorOrCeiling() {
        XCTAssertEqual(target(75, response: 0), 2000)
        XCTAssertEqual(target(75, response: 3), 6000)
        XCTAssertEqual(target(75, response: 0.75), 3000)
        XCTAssertEqual(target(75, response: 2.25), 5000)
    }

    /// The summary names the speeds the fans really reach. Gentle at 108 °C
    /// held 4,650 RPM while the summary said they reach Max speed at 90 °C.
    func testSummaryNamesTheSpeedsTheCurveGives() {
        func summary(_ response: Double, threshold: Double = 60, floor: Int = 2000, ceiling: Int = 6000) -> String {
            FanCurve.summary(threshold: threshold, response: response, floorRPM: floor, ceilingRPM: ceiling)
        }
        XCTAssertEqual(
            summary(1.0, threshold: 55, floor: 2317, ceiling: 5817),
            "Fans stay at minimum up to 55 °C, then speed up to reach \(4650.formatted()) RPM at 90 °C. Gentle keeps them under Max speed, \(5817.formatted()) RPM."
        )
        XCTAssertEqual(summary(1.5), "Fans stay at minimum up to 60 °C, then speed up to reach \(6000.formatted()) RPM at 90 °C.")
        XCTAssertEqual(summary(2.25), "Fans hold \(4000.formatted()) RPM up to 60 °C, then speed up to reach \(6000.formatted()) RPM at 90 °C.")
        XCTAssertEqual(summary(1.5, threshold: 90), "Fans stay at minimum until 90 °C, then run at \(6000.formatted()) RPM.")
        XCTAssertEqual(summary(0), "Fans stay at their minimum speed at every temperature.")
        XCTAssertEqual(summary(3), "Fans run at \(6000.formatted()) RPM at every temperature.")
        XCTAssertEqual(summary(1.5, ceiling: 1500), "Fans run at \(2000.formatted()) RPM at every temperature.")
    }

    func testCeilingBelowFloorPinsToFloor() {
        let rpm = FanCurve.target(temperature: 80, threshold: 40, response: 1.5, floorRPM: 2000, ceilingRPM: 1500)
        XCTAssertEqual(rpm, 2000)
    }

    func testTemperatureLevels() {
        XCTAssertEqual(TemperatureLevel(celsius: 45), .cool)
        XCTAssertEqual(TemperatureLevel(celsius: 50), .normal)
        XCTAssertEqual(TemperatureLevel(celsius: 70), .warm)
        XCTAssertEqual(TemperatureLevel(celsius: 85), .hot)
    }

    func testLevelSpansFloorToTop() {
        func level(_ temperature: Double, ceiling: Int = 6000) -> Double {
            FanCurve.level(
                temperature: temperature, threshold: 60, response: 1.5,
                floorRPM: 2000, ceilingRPM: ceiling, topRPM: 6000
            )
        }
        XCTAssertEqual(level(50), 0)
        XCTAssertEqual(level(75), 0.5, accuracy: 0.001)
        XCTAssertEqual(level(95), 1)
        // A lower Max speed stops the curve below the top.
        XCTAssertEqual(level(95, ceiling: 4000), 0.5, accuracy: 0.001)
    }

    func testMeterFractionClampsToItsScale() {
        XCTAssertEqual(TemperatureLevel.meterFraction(30), 0)
        XCTAssertEqual(TemperatureLevel.meterFraction(65), 0.5, accuracy: 0.0001)
        XCTAssertEqual(TemperatureLevel.meterFraction(100), 1)
        XCTAssertEqual(TemperatureLevel.meterFraction(12), 0)
        XCTAssertEqual(TemperatureLevel.meterFraction(110), 1)
    }

    // MARK: - When Auto sends a speed

    /// Feeds `targets` to a gate, one reading each, and returns what it sent.
    private func sends(_ targets: [Int], gate: inout AutoSpeedGate) -> [Int?] {
        targets.map { gate.speed(for: $0, floorRPM: 2000, ceilingRPM: 6000) }
    }

    func testTheFirstReadingSendsAndSmallChangesDont() {
        var gate = AutoSpeedGate()
        XCTAssertEqual(sends([3000, 3050, 3099, 2950], gate: &gate), [3000, nil, nil, nil])
        XCTAssertEqual(gate.sent, 3000)
    }

    func testARiseGoesOutAtOnce() {
        var gate = AutoSpeedGate()
        XCTAssertEqual(sends([3000, 3100, 3500], gate: &gate), [3000, 3100, 3500])
    }

    /// The defect: readings that wobble by a degree or two sent a speed on
    /// nearly every 2 s tick, and the fans turned down and back up again.
    func testAWobblingCurveSendsNothingMore() {
        var gate = AutoSpeedGate()
        let wobble = [3000, 2850, 3060, 2800, 3090, 2830, 3020, 2870, 3080, 2810]
        XCTAssertEqual(sends(wobble, gate: &gate).compactMap { $0 }, [3000])
    }

    func testAFallWaitsThenSendsTheHighestRecentTarget() {
        var gate = AutoSpeedGate()
        XCTAssertEqual(sends([4000, 3000, 3200, 3100, 3000], gate: &gate), [4000, nil, nil, nil, nil])
        // Once 4000 leaves the window, the highest of the last five is 3200.
        XCTAssertEqual(sends([3000], gate: &gate), [3200])
        XCTAssertEqual(sends([3000, 3000, 3000], gate: &gate), [nil, nil, 3000], "settles once 3200 leaves the window")
    }

    func testCoolingSettlesOnTheFloor() {
        var gate = AutoSpeedGate()
        XCTAssertEqual(sends([2100] + Array(repeating: 2000, count: 5), gate: &gate), [2100, nil, nil, nil, nil, 2000])
    }

    func testTheCeilingIsNeverHeldBack() {
        var gate = AutoSpeedGate()
        XCTAssertEqual(sends([5950, 6000], gate: &gate), [5950, 6000])
    }

    func testResetSendsTheNextReading() {
        var gate = AutoSpeedGate()
        _ = sends([3000], gate: &gate)
        gate.reset()
        XCTAssertNil(gate.sent)
        XCTAssertEqual(sends([2900], gate: &gate), [2900], "a changed curve applies at once, down as well as up")
    }
}
