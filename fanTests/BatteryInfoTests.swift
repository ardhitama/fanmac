//
//  BatteryInfoTests.swift
//  FanMacTests
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  The Power card shows what the whole Mac draws, also while the adapter
//  carries the load and the battery's own power is zero.
//

import IOKit.ps
import XCTest
@testable import FanMac

final class BatteryInfoTests: XCTestCase {
    func testSystemLoadReadsMilliwattsFromTelemetry() {
        XCTAssertEqual(BatteryInfo.systemLoadWatts(telemetry: ["SystemLoad": 65843]) ?? 0, 65.843, accuracy: 0.0001)
        XCTAssertNil(BatteryInfo.systemLoadWatts(telemetry: ["SystemLoad": 0]))
        XCTAssertNil(BatteryInfo.systemLoadWatts(telemetry: ["SystemPowerIn": 65843]))
        XCTAssertNil(BatteryInfo.systemLoadWatts(telemetry: nil))
    }

    func testPluggedInWithIdleBatteryShowsSystemLoad() {
        // Plugged in at a charge limit: the battery passes no current.
        var info = BatteryInfo()
        info.isPluggedIn = true
        info.voltage = 12.383
        info.amperage = 0
        info.systemLoadWatts = 26.394

        XCTAssertEqual(info.systemPowerWatts ?? 0, 26.394, accuracy: 0.0001)
    }

    func testBatteryPowerStandsInWithoutTelemetry() {
        var info = BatteryInfo()
        info.voltage = 12
        info.amperage = -1500

        XCTAssertEqual(info.systemPowerWatts ?? 0, 18, accuracy: 0.0001)
    }

    func testNoReadingWithoutTelemetryOrBatteryCurrent() {
        var info = BatteryInfo()
        info.isPluggedIn = true
        info.voltage = 12.383
        info.amperage = 0

        XCTAssertNil(info.systemPowerWatts)
    }

    /// A UPS plugged into a desktop Mac is a power source, not its battery.
    func testAUPSIsNotTheMacsBattery() {
        let ups: [String: Any] = [kIOPSTypeKey: kIOPSUPSType, kIOPSCurrentCapacityKey: 100]
        let battery: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 80]
        XCTAssertNil(BatteryMonitor.internalBattery(in: [ups]))
        XCTAssertEqual(BatteryMonitor.internalBattery(in: [ups, battery])?[kIOPSCurrentCapacityKey] as? Int, 80)
    }

    /// The popover builds its dashboard in the run loop turn that creates the
    /// monitor. A `hasBattery` that came a turn later gave a new laptop the
    /// desktop's default layout. (On a Mac without a battery this can't fail.)
    func testANewMonitorKnowsAtOnceWhetherThereIsABattery() {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        let hasBattery = sources.contains {
            (IOPSGetPowerSourceDescription(snapshot, $0 as CFTypeRef).takeUnretainedValue() as? [String: Any])?[kIOPSTypeKey]
                as? String == kIOPSInternalBatteryType
        }
        XCTAssertEqual(BatteryMonitor().hasBattery, hasBattery)
    }

    /// The popover reads the battery only while it's open; Power in the menu
    /// bar must not freeze at what it read last.
    func testPowerInTheMenuBarRereadsTheBattery() throws {
        let battery = BatteryMonitor.shared
        try XCTSkipUnless(battery.hasBattery, "this Mac has no battery")
        battery.batteryInfo = BatteryInfo()
        let manager = StatusBarManager()
        manager.setDisplayMode("power")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        manager.refreshDisplay()
        XCTAssertNotNil(battery.batteryInfo.voltage, "still the reading from before")
    }
}
