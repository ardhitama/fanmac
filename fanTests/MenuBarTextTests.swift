//
//  MenuBarTextTests.swift
//  fanTests
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//

import XCTest
@testable import FanMac

final class MenuBarTextTests: XCTestCase {
    /// Plugged in, the battery's own current is zero while the adapter carries
    /// the load. Power must still say what the whole Mac draws, as the
    /// popover's Power card does, not fall back to the fans' load.
    func testPowerIsWhatTheWholeMacDrawsWhilePluggedIn() {
        let pluggedIn = BatteryInfo(voltage: 12.335, amperage: 0, systemLoadWatts: 20.554)
        XCTAssertEqual(
            StatusBarManager.displayText(mode: "power", temperature: 68, battery: pluggedIn, fanLoadPercent: 35),
            "20.6W"
        )
        XCTAssertEqual(
            StatusBarManager.displayText(mode: "power", temperature: 68, battery: BatteryInfo(), fanLoadPercent: 35),
            "--W"
        )
    }

    /// A choice this Mac can't show is shown as the one in its place, and
    /// Settings shows that same choice.
    func testChoicesThisMacCantShow() {
        // Without a battery, Power is the fans' load: what Fan Speed shows.
        XCTAssertEqual(StatusBarManager.effectiveDisplayMode("power", hasBattery: false, hasFans: true), "fanSpeedPercentage")
        XCTAssertEqual(StatusBarManager.displayText(mode: "power", temperature: 68, battery: nil, fanLoadPercent: 35), "35%")
        // Without fans, Fan Speed is the temperature.
        XCTAssertEqual(StatusBarManager.effectiveDisplayMode("fanSpeedPercentage", hasBattery: true, hasFans: false), "temperature")
        XCTAssertEqual(
            StatusBarManager.displayText(mode: "fanSpeedPercentage", temperature: 68, battery: BatteryInfo(), fanLoadPercent: nil),
            "68°"
        )
        // Choices this Mac can show stay as they are.
        for mode in ["none", "temperature", "power", "fanSpeedPercentage"] {
            XCTAssertEqual(StatusBarManager.effectiveDisplayMode(mode, hasBattery: true, hasFans: true), mode)
        }
        XCTAssertEqual(StatusBarManager.displayText(mode: "none", temperature: 68, battery: nil, fanLoadPercent: 35), "")
        XCTAssertEqual(StatusBarManager.displayText(mode: "temperature", temperature: nil, battery: nil, fanLoadPercent: 35), "--°")
    }
}
