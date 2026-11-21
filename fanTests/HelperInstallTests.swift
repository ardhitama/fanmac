//
//  HelperInstallTests.swift
//  fanTests
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//

import XCTest
@testable import FanMac

final class HelperInstallTests: XCTestCase {
    /// Opening the popover makes FanMac the active app, so the password
    /// prompt can close it, and the popover's own state goes with it. Why the
    /// install failed has to be there when the popover opens again. (The test
    /// bundle has no helper to install, so the install fails without a prompt.)
    func testAFailedInstallKeepsItsReasonForTheNextPopover() {
        let permissions = PermissionsManager.shared
        let finished = expectation(description: "install finished")
        permissions.installHelper { success, _ in
            XCTAssertFalse(success)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(permissions.installError, "App Bundle missing smc-helper. Re-build app.")
    }

    /// The install script, run with its root-only folders moved into a
    /// temporary one and without chown, which needs root.
    private func runInstall(requirement: String?, in folder: URL) throws -> Int32 {
        let script = PermissionsManager.installCommand(bundledHelperPath: "/usr/bin/true", requirement: requirement)
            .replacingOccurrences(of: "/Library/PrivilegedHelperTools", with: folder.appendingPathComponent("helpers").path)
            .replacingOccurrences(of: "/etc/sudoers.d", with: folder.appendingPathComponent("sudoers.d").path)
            .replacingOccurrences(of: "/usr/local/bin/smc-helper", with: folder.appendingPathComponent("legacy").path)
            .replacingOccurrences(of: "/usr/sbin/chown root:wheel", with: "/usr/bin/true")
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script]
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        shell.waitUntilExit()
        return shell.terminationStatus
    }

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// The defect: root copied whatever binary sat in the app bundle, which
    /// anything running as the person can replace, and staged the sudoers
    /// rule in the person's own temporary folder. Now both are staged in the
    /// folder they go live in, and the helper must meet the requirement.
    func testTheInstallScriptInstallsOnlyAHelperThatMeetsTheRequirement() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let helpers = folder.appendingPathComponent("helpers")
        let sudoers = folder.appendingPathComponent("sudoers.d")

        XCTAssertNotEqual(try runInstall(requirement: #"identifier "com.apple.false" and anchor apple"#, in: folder), 0)
        XCTAssertEqual(names(in: helpers), [], "a helper that fails the requirement was installed, or its staged copy left")
        XCTAssertEqual(names(in: sudoers), [], "the rule went in without its helper")

        XCTAssertEqual(try runInstall(requirement: #"identifier "com.apple.true" and anchor apple"#, in: folder), 0)
        XCTAssertEqual(names(in: helpers), ["fanmac-smc-helper"])
        XCTAssertEqual(names(in: sudoers), ["smc-fan-helper"])
        let attributes = try FileManager.default.attributesOfItem(atPath: sudoers.appendingPathComponent("smc-fan-helper").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o440)
        let rule = try String(contentsOf: sudoers.appendingPathComponent("smc-fan-helper"), encoding: .utf8)
        XCTAssertEqual(rule, "%admin ALL=(root) NOPASSWD: \(helpers.appendingPathComponent("fanmac-smc-helper").path)\n")
    }

    func testTheRequirementNamesTheAppsTeam() {
        XCTAssertEqual(
            PermissionsManager.helperRequirement(teamIdentifier: "ABCDE12345"),
            #"identifier "smc-helper" and anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#
        )
        XCTAssertNil(PermissionsManager.helperRequirement(teamIdentifier: nil), "a local build has no team to compare")
        XCTAssertNil(PermissionsManager.helperRequirement(teamIdentifier: #"X" or anchor apple"#))
    }
}
