//
//  ControlServerTests.swift
//  FanMacTests
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//

import XCTest
@testable import FanMac

final class ControlServerTests: XCTestCase {
    /// `fanmac` and a second FanMac check that FanMac runs by connecting and
    /// hanging up at once. Answering that closed socket raised SIGPIPE and
    /// killed FanMac with the fans still held; here it would kill the test run.
    func testAClientThatHangsUpAtOnceDoesNotKillFanMac() {
        var ends: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends), 0)
        close(ends[1])
        ControlServer.serve(ends[0]) { _ in
            XCTFail("a client that sent nothing has no request to handle")
            return FanMacControl.Response(status: nil, error: nil)
        }
        close(ends[0])
    }

    /// `fanmac manual` on a MacBook Air: refused at once with the reason,
    /// not answered as if fans now held a speed.
    func testAFanChangeOnAMacWithoutFansIsRefused() {
        let monitor = SystemMonitor()
        let viewModel = FanControlViewModel(systemMonitor: monitor)
        let server = ControlServer(viewModel: viewModel)
        monitor.hasNoFans = true

        var manual = FanMacControl.Request(.setManualSpeed)
        manual.rpm = 3000
        for request in [manual, FanMacControl.Request(.setMode), FanMacControl.Request(.setAuto)] {
            let response = server.respond(to: request)
            XCTAssertEqual(response.error, FanMacControl.noFansMessage, "\(request.command)")
            XCTAssertEqual(response.status?.hasNoFans, true)
            XCTAssertEqual(response.status?.controlledByFanMac, false)
        }
        XCTAssertNil(server.respond(to: FanMacControl.Request(.status)).error)
    }

    /// Replacing FanMac.app while it runs points `fanmac` at the new copy
    /// while the old FanMac still answers, without the fields it didn't have.
    func testAStatusFromAnOlderFanMacStillReads() throws {
        let server = ControlServer(viewModel: FanControlViewModel(systemMonitor: SystemMonitor()))
        let current = try JSONEncoder().encode(server.respond(to: FanMacControl.Request(.status)))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
        var status = try XCTUnwrap(json["status"] as? [String: Any])
        XCTAssertNotNil(status.removeValue(forKey: "hasNoFans"))
        json["status"] = status
        let older = try JSONSerialization.data(withJSONObject: json)

        let response = try JSONDecoder().decode(FanMacControl.Response.self, from: older)
        XCTAssertNotEqual(response.status?.hasNoFans, true)
    }

    func testTheSummaryOfAMacWithoutFansSaysSo() {
        // Not the helper: a Mac without fans doesn't need it.
        XCTAssertEqual(
            FanMacControl.controlSummary(hasNoFans: true, helperInstalled: false, helperReady: false, controlledByFanMac: false, mode: .auto, perFan: false, manualRPM: 3000),
            "This Mac has no fans."
        )
        XCTAssertEqual(
            FanMacControl.controlSummary(hasNoFans: false, helperInstalled: true, helperReady: true, controlledByFanMac: false, mode: .auto, perFan: false, manualRPM: 3000),
            "macOS is controlling the fans."
        )
    }

    /// Every preview user meets this after upgrading: the helper is there,
    /// but out of date. The summary said to install it, and not how.
    func testTheSummarySaysWhatTheHelperNeeds() {
        XCTAssertEqual(
            FanMacControl.controlSummary(hasNoFans: false, helperInstalled: true, helperReady: false, controlledByFanMac: false, mode: .auto, perFan: false, manualRPM: 3000),
            "macOS controls the fans until the helper is updated: click the FanMac menu bar icon, then Update Helper."
        )
        XCTAssertEqual(
            FanMacControl.controlSummary(hasNoFans: false, helperInstalled: false, helperReady: false, controlledByFanMac: false, mode: .auto, perFan: false, manualRPM: 3000),
            "macOS controls the fans until the helper is installed: click the FanMac menu bar icon, then Install Helper."
        )
    }

    func testAClientGetsItsAnswer() throws {
        var ends: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends), 0)
        defer { close(ends[1]) }
        let request = try JSONEncoder().encode(FanMacControl.Request(.status))
        XCTAssertTrue(FanMacControl.writeMessage(request, to: ends[1]))
        ControlServer.serve(ends[0]) { _ in
            FanMacControl.Response(status: nil, error: "answered")
        }
        close(ends[0])
        let reply = try XCTUnwrap(FanMacControl.readMessage(from: ends[1]))
        XCTAssertEqual(try JSONDecoder().decode(FanMacControl.Response.self, from: reply).error, "answered")
    }
}
