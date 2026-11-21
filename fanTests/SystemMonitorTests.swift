//
//  SystemMonitorTests.swift
//  FanMacTests
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//

import XCTest
@testable import FanMac

final class SystemMonitorTests: XCTestCase {
    
    func testSystemMonitorInitialization() {
        let monitor = SystemMonitor()
        
        XCTAssertNotNil(monitor)
        XCTAssertFalse(monitor.isMonitoring)
    }
    
    func testSystemMonitorStartStop() {
        let monitor = SystemMonitor()
        
        XCTAssertFalse(monitor.isMonitoring)
        
        monitor.startMonitoring()
        // Note: In actual implementation, monitoring might start asynchronously
        // This test verifies the method can be called without crashing
        
        monitor.stopMonitoring()
        XCTAssertFalse(monitor.isMonitoring)
    }

    /// FanMac takes the fans once it knows their limits. A first reading
    /// taken before the fans were counted left them out, so the limits came
    /// a whole read interval (2 s by default) after launch.
    func testTheFirstReadingIncludesTheFansLimits() throws {
        let monitor = SystemMonitor()
        monitor.startMonitoring()
        defer { monitor.stopMonitoring() }
        try XCTSkipUnless(monitor.isMonitoring, "this process can't read the SMC")

        let deadline = Date().addingTimeInterval(1.2)
        while (monitor.numberOfFans == 0 || monitor.fanMaxSpeeds.count < monitor.numberOfFans)
            && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        try XCTSkipIf(monitor.numberOfFans == 0, "this Mac reports no fans")
        XCTAssertEqual(monitor.fanMinSpeeds.count, monitor.numberOfFans)
        XCTAssertEqual(monitor.fanMaxSpeeds.count, monitor.numberOfFans)
        XCTAssertFalse(monitor.hasNoFans)
    }

    /// A MacBook Air has no fans: the SMC answers, has no fan speed to read
    /// and reports no fans.
    func testAMacWithoutFansIsToldFromAFailedRead() {
        XCTAssertEqual(SystemMonitor.fanDetection(countedFans: 2, reportedFans: nil, smcAnswers: true), .fans(2))
        // Fan 2's speed failed to read at launch and ended the count at one;
        // fan 2 then went undriven for the whole session.
        XCTAssertEqual(SystemMonitor.fanDetection(countedFans: 1, reportedFans: 2, smcAnswers: true), .fans(2))
        XCTAssertEqual(SystemMonitor.fanDetection(countedFans: 2, reportedFans: 2, smcAnswers: true), .fans(2))
        XCTAssertEqual(SystemMonitor.fanDetection(countedFans: 2, reportedFans: 200, smcAnswers: true), .fans(2))
        XCTAssertEqual(SystemMonitor.fanDetection(countedFans: 0, reportedFans: 0, smcAnswers: true), .none)
        XCTAssertEqual(SystemMonitor.fanDetection(countedFans: 0, reportedFans: nil, smcAnswers: true), .none)
        // The SMC says there are fans, or doesn't answer: a read failed, and
        // calling the Mac fanless would hide its fans for good.
        XCTAssertEqual(SystemMonitor.fanDetection(countedFans: 0, reportedFans: 2, smcAnswers: true), .unknown)
        XCTAssertEqual(SystemMonitor.fanDetection(countedFans: 0, reportedFans: nil, smcAnswers: false), .unknown)
    }

    /// A failed read can pass for a Mac without fans. Fans found later must
    /// bring the fan controls back, not stay hidden until FanMac restarts.
    func testFansFoundAfterAMisreadComeBack() {
        let monitor = SystemMonitor()
        monitor.applyFanDetection(.none)
        XCTAssertTrue(monitor.hasNoFans)
        XCTAssertEqual(monitor.numberOfFans, 0)

        monitor.applyFanDetection(.fans(2))
        XCTAssertFalse(monitor.hasNoFans)
        XCTAssertEqual(monitor.numberOfFans, 2)
    }
}
