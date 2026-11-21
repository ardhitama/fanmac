//
//  FanReleaseWatchdogTests.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  The watchdog runs a recording command in place of sudo and the helper,
//  so these tests never touch the fans.
//

import XCTest
@testable import FanMac

final class FanReleaseWatchdogTests: XCTestCase {
    private var directory: URL!
    private var log: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FanReleaseWatchdogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = directory.appendingPathComponent("calls.log")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Appends each `auto <fan>` the watchdog runs to the log.
    private var recorder: [String] {
        ["/bin/sh", "-c", #"echo "$*" >> "$0""#, log.path]
    }

    private var unmatchedWrites: String {
        "fanmac-test-no-such-write-\(UUID().uuidString)"
    }

    private func calls() -> [String] {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// The watchdogs of this test: their arguments hold the log's path.
    private func watchdogs() -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "fanmac-watchdog .*\(log.path)"]
        let output = Pipe()
        pgrep.standardOutput = output
        guard (try? pgrep.run()) != nil else { return [] }
        pgrep.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").compactMap { pid_t($0) }
    }

    private func waitForWatchdogs(replacing old: [pid_t], timeout: TimeInterval = 3) -> [pid_t] {
        let deadline = Date().addingTimeInterval(timeout)
        var found = watchdogs()
        while (found.isEmpty || found == old) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            found = watchdogs()
        }
        return found
    }

    private func waitForCalls(_ count: Int, timeout: TimeInterval = 5) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while calls().count < count && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return calls()
    }

    func testHandsBackEveryFanWhenFanMacGoesAway() {
        var watchdog: FanReleaseWatchdog? = FanReleaseWatchdog()
        XCTAssertTrue(watchdog!.arm(fanCount: 2, command: recorder, writePattern: unmatchedWrites))
        XCTAssertTrue(watchdog!.isWatching)
        // Releasing it closes FanMac's end of the pipe, as FanMac's exit does.
        watchdog = nil
        XCTAssertEqual(waitForCalls(2), ["auto 0", "auto 1"])
    }

    func testDoesNothingAfterACleanHandBack() {
        let watchdog = FanReleaseWatchdog()
        XCTAssertTrue(watchdog.arm(fanCount: 2, command: recorder, writePattern: unmatchedWrites))
        watchdog.disarm()
        let deadline = Date().addingTimeInterval(3)
        while watchdog.isWatching && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(watchdog.isWatching, "the watchdog should exit after disarm")
        XCTAssertEqual(calls(), [])
    }

    func testStartsOnlyOnce() {
        let watchdog = FanReleaseWatchdog()
        XCTAssertTrue(watchdog.arm(fanCount: 1, command: recorder, writePattern: unmatchedWrites))
        XCTAssertFalse(watchdog.arm(fanCount: 1, command: recorder, writePattern: unmatchedWrites))
        watchdog.disarm()
    }

    func testDisarmingTwiceOrAfterTheWatchdogExitedIsHarmless() {
        let watchdog = FanReleaseWatchdog()
        watchdog.disarm()
        XCTAssertTrue(watchdog.arm(fanCount: 1, command: recorder, writePattern: unmatchedWrites))
        watchdog.disarm()
        watchdog.disarm()
        XCTAssertEqual(calls(), [])
    }

    /// Ending the watchdog alone (`pkill -f fanmac`, Activity Monitor) must
    /// not leave a later crash with the fans held.
    func testStartsAnotherWatchdogWhenOneIsEnded() throws {
        var watchdog: FanReleaseWatchdog? = FanReleaseWatchdog()
        XCTAssertTrue(watchdog!.arm(fanCount: 2, command: recorder, writePattern: unmatchedWrites))
        let first = watchdogs()
        XCTAssertEqual(first.count, 1)
        Thread.sleep(forTimeInterval: 1.2) // past the guard against a watchdog that can't run
        kill(try XCTUnwrap(first.first), SIGKILL)

        let second = waitForWatchdogs(replacing: first)
        XCTAssertEqual(second.count, 1)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(calls(), [])
        watchdog = nil
        XCTAssertEqual(waitForCalls(2), ["auto 0", "auto 1"])
    }

    /// A watchdog that ends at once isn't restarted in a loop; the next
    /// speed write arms another.
    func testAWatchdogThatEndsAtOnceIsArmedByTheNextWrite() throws {
        let watchdog = FanReleaseWatchdog()
        XCTAssertTrue(watchdog.arm(fanCount: 1, command: recorder, writePattern: unmatchedWrites))
        kill(try XCTUnwrap(watchdogs().first), SIGKILL)
        let deadline = Date().addingTimeInterval(3)
        while watchdog.isWatching && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(watchdogs(), [], "restarted a watchdog that ended at once")
        XCTAssertTrue(watchdog.arm(fanCount: 1, command: recorder, writePattern: unmatchedWrites))
        XCTAssertEqual(watchdogs().count, 1)
        watchdog.disarm()
        XCTAssertEqual(calls(), [])
    }

    /// A speed write FanMac started keeps running after FanMac dies and
    /// would take the fan again after an early hand-back.
    func testWaitsForASpeedWriteStillRunning() throws {
        let marker = "fanmac-test-write-\(UUID().uuidString)"
        let write = Process()
        write.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `; :` keeps sh from exec'ing sleep, so the marker stays in the command line.
        write.arguments = ["-c", "sleep 1.5; :", marker]
        try write.run()

        var watchdog: FanReleaseWatchdog? = FanReleaseWatchdog()
        XCTAssertTrue(watchdog!.arm(fanCount: 1, command: recorder, writePattern: marker))
        watchdog = nil

        Thread.sleep(forTimeInterval: 0.7)
        XCTAssertTrue(write.isRunning)
        XCTAssertEqual(calls(), [], "handed back while the speed write was still running")
        XCTAssertEqual(waitForCalls(1), ["auto 0"])
        XCTAssertFalse(write.isRunning)
    }
}
