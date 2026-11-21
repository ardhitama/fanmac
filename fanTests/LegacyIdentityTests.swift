//
//  LegacyIdentityTests.swift
//  FanMacTests
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//

import XCTest
@testable import FanMac

final class LegacyIdentityTests: XCTestCase {
    private var oldDomain = ""
    private var newDomain = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let id = UUID().uuidString
        oldDomain = "LegacyIdentityTests.old.\(id)"
        newDomain = "LegacyIdentityTests.new.\(id)"
        defaults = UserDefaults(suiteName: newDomain)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: oldDomain)
        defaults.removePersistentDomain(forName: newDomain)
        super.tearDown()
    }

    private func carryOver() -> Bool {
        LegacyIdentity.carryOverSettings(defaults, into: newDomain, from: oldDomain)
    }

    func testAnUpdateBringsTheOldSettings() {
        defaults.setPersistentDomain(["fanControlMode": "manual", "manualFanSpeed": 4200], forName: oldDomain)
        XCTAssertTrue(carryOver())
        XCTAssertEqual(defaults.string(forKey: "fanControlMode"), "manual")
        XCTAssertEqual(defaults.integer(forKey: "manualFanSpeed"), 4200)
    }

    func testASettingAlreadyMadeHereWins() {
        defaults.setPersistentDomain(["fanControlMode": "manual", "autoThreshold": 60.0], forName: oldDomain)
        defaults.set("automatic", forKey: "fanControlMode")
        XCTAssertTrue(carryOver())
        XCTAssertEqual(defaults.string(forKey: "fanControlMode"), "automatic")
        XCTAssertEqual(defaults.double(forKey: "autoThreshold"), 60)
    }

    /// Later changes are FanMac's own: a setting removed here must not come
    /// back from the old domain on the next launch.
    func testItHappensOnce() {
        defaults.setPersistentDomain(["manualFanSpeed": 4200], forName: oldDomain)
        XCTAssertTrue(carryOver())
        defaults.removeObject(forKey: "manualFanSpeed")
        XCTAssertFalse(carryOver())
        XCTAssertNil(defaults.object(forKey: "manualFanSpeed"))
    }

    /// A new install has nothing to bring and must not open at login unasked.
    func testANewInstallBringsNothing() {
        XCTAssertFalse(carryOver())
        XCTAssertFalse(carryOver())
        XCTAssertNil(defaults.object(forKey: "fanControlMode"))
    }
}
