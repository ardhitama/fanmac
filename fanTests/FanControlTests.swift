//
//  FanControlTests.swift
//  FanMacTests
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//

import XCTest
@testable import FanMac

final class FanControlTests: XCTestCase {
    /// The settings FanController loads and saves. Each test starts without
    /// them and puts back whatever was there, so no test sees another's.
    private static let settingsKeys = [
        "fanControlMode", "perFanManualControl", "manualFanSpeed", "manualFanSpeedsPerFan",
        "autoThreshold", "autoMaxSpeed", "autoAggressiveness",
        "autoSwitchMode", "enableNotifications", "highTempAlert", "settingsVersion",
    ]
    private var savedSettings: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedSettings = [:]
        for key in Self.settingsKeys {
            savedSettings[key] = defaults.object(forKey: key)
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for key in Self.settingsKeys {
            if let value = savedSettings[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }
    
    func testControlModeEnum() {
        XCTAssertEqual(ControlMode.manual, ControlMode.manual)
        XCTAssertEqual(ControlMode.automatic, ControlMode.automatic)
        XCTAssertNotEqual(ControlMode.manual, ControlMode.automatic)
    }
    
    /// A first launch runs Auto at the Standard response. The defect: a
    /// missing Response setting read as 0, the quietest, which holds the fans
    /// at their minimum at any temperature, and the first mode was a fixed
    /// Manual speed.
    func testFanControllerInitialization() {
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor)
        
        XCTAssertEqual(controller.mode, .automatic)
        XCTAssertEqual(controller.autoAggressiveness, FanCurve.neutralResponse)
        XCTAssertGreaterThanOrEqual(controller.manualSpeed, FanRPMBounds.absoluteWriteMinRPM)
        XCTAssertLessThanOrEqual(controller.manualSpeed, FanRPMBounds.absoluteWriteMaxRPM)
    }
    
    /// The previews saved Response 0, the quietest, without anyone choosing
    /// it; under it Auto held the fans at their minimum however hot the Mac
    /// got. 1.0 puts it back to the default once.
    func testAPreviewsResponseOfZeroGoesBackToTheDefault() {
        let defaults = UserDefaults.standard
        defaults.set(0.0, forKey: "autoAggressiveness")
        defaults.set(70.0, forKey: "autoThreshold")

        let controller = FanController(systemMonitor: SystemMonitor())

        XCTAssertEqual(controller.autoAggressiveness, FanCurve.neutralResponse)
        XCTAssertEqual(controller.autoThreshold, 70, "other settings stay")
        XCTAssertNil(defaults.object(forKey: "autoAggressiveness"))
        XCTAssertEqual(defaults.integer(forKey: "settingsVersion"), FanController.settingsVersion)
    }

    func testAPreviewsOtherResponseStays() {
        UserDefaults.standard.set(2.25, forKey: "autoAggressiveness")
        XCTAssertEqual(FanController(systemMonitor: SystemMonitor()).autoAggressiveness, 2.25)
    }

    func testAResponseOfZeroChosenSince1_0Stays() {
        let defaults = UserDefaults.standard
        defaults.set(FanController.settingsVersion, forKey: "settingsVersion")
        defaults.set(0.0, forKey: "autoAggressiveness")
        XCTAssertEqual(FanController(systemMonitor: SystemMonitor()).autoAggressiveness, 0)

        // And after it is saved and read again.
        let controller = FanController(systemMonitor: SystemMonitor())
        controller.setAutoAggressiveness(0)
        XCTAssertEqual(FanController(systemMonitor: SystemMonitor()).autoAggressiveness, 0)
    }

    func testFanControllerManualSpeed() {
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor)
        controller.setMode(.manual)
        
        controller.setManualSpeed(3000)
        XCTAssertEqual(controller.manualSpeed, 3000)
        
        // Test clamping (no SMC data yet → unified limits fall back to `FanRPMBounds`)
        controller.setManualSpeed(10000)
        XCTAssertLessThanOrEqual(controller.manualSpeed, FanRPMBounds.fallbackMaxWhenSMCUnreadable)
        
        controller.setManualSpeed(500)
        XCTAssertGreaterThanOrEqual(controller.manualSpeed, FanRPMBounds.fallbackMinWhenSMCUnreadable)
    }
    
    func testFanControllerModeSwitch() {
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor)
        
        XCTAssertEqual(controller.mode, .automatic)
        
        controller.setMode(.manual)
        XCTAssertEqual(controller.mode, .manual)
        
        controller.setMode(.automatic)
        XCTAssertEqual(controller.mode, .automatic)
    }
    
    func testFanControlViewModelInitialization() {
        let viewModel = FanControlViewModel()
        
        XCTAssertNotNil(viewModel)
        XCTAssertEqual(viewModel.controlMode, .manual)
        XCTAssertEqual(viewModel.fanSpeeds.count, 0)
    }
    
    func testMaxTemperatureCalculation() {
        let viewModel = FanControlViewModel()
        
        viewModel.cpuTemperature = 50.0
        viewModel.gpuTemperature = 60.0
        XCTAssertEqual(viewModel.getMaxTemperature(), 60.0)
        
        viewModel.cpuTemperature = 70.0
        viewModel.gpuTemperature = 65.0
        XCTAssertEqual(viewModel.getMaxTemperature(), 70.0)
    }

    // MARK: - Quit hand-back

    /// FanMac learns the fan count before the fans' limits. Applying the
    /// saved settings then would clamp to the fallback limits and drive the
    /// fans below their real minimum until the next reading.
    func testSavedSettingsWaitForTheFansLimits() {
        UserDefaults.standard.set("manual", forKey: "fanControlMode")
        UserDefaults.standard.set(1500, forKey: "manualFanSpeed")
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)

        monitor.numberOfFans = 2
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(helper.calls, [], "wrote targets before the fans' limits were known")
        XCTAssertFalse(controller.isReady, "a change now would clamp to placeholder limits")

        monitor.fanMinSpeeds = [2317, 2317]
        monitor.fanMaxSpeeds = [7826, 7826]
        let deadline = Date().addingTimeInterval(3)
        while helper.calls.count < 2 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let calls = helper.calls
        XCTAssertGreaterThanOrEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.first == "set" && $0[2] == "2317" }, "\(calls)")
        XCTAssertTrue(controller.isReady)
        withExtendedLifetime(controller) {}
    }

    /// Without fans FanMac has nothing to apply: it is ready at once, so
    /// `fanmac` gets its answer without waiting, and it never claims fans.
    /// The defect: Auto ran sudo and the helper for every fan whenever the
    /// curve moved 50 RPM, so a 1 °C wobble rewrote the fans on every 2 s tick.
    func testAutoLeavesTheFansAloneThroughAWobble() {
        let defaults = UserDefaults.standard
        defaults.set("automatic", forKey: "fanControlMode")
        defaults.set(60.0, forKey: "autoThreshold")
        defaults.set(1.5, forKey: "autoAggressiveness")
        defaults.set(6000, forKey: "autoMaxSpeed")
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)
        monitor.numberOfFans = 1
        monitor.cpuTemperature = 75
        monitor.fanMinSpeeds = [2000]
        monitor.fanMaxSpeeds = [6000]

        func sets() -> [[String]] { helper.calls.filter { $0.first == "set" } }
        let deadline = Date().addingTimeInterval(3)
        while sets().isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(sets().map { $0[2] }, ["4000"], "75 °C is halfway up the curve")

        // 1 °C cooler is 133 RPM lower: not worth a write until it lasts.
        monitor.cpuTemperature = 74
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        XCTAssertEqual(sets().count, 1, "\(sets())")

        // 2 °C warmer goes out on the next tick.
        monitor.cpuTemperature = 77
        let riseDeadline = Date().addingTimeInterval(5)
        while sets().count < 2 && Date() < riseDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(sets().map { $0[2] }, ["4000", "4266"])
        withExtendedLifetime(controller) {}
    }

    /// The defect: when sudo refused the helper, every fan and every new Auto
    /// target raised another administrator prompt, so a cancelled prompt came
    /// straight back. One prompt per attempt, then Auto waits for the person.
    func testAutoAsksForThePasswordOnceAfterARefusal() {
        let defaults = UserDefaults.standard
        defaults.set("automatic", forKey: "fanControlMode")
        defaults.set(60.0, forKey: "autoThreshold")
        defaults.set(6000, forKey: "autoMaxSpeed")
        let helper = RecordingHelper(result: .notAuthorized)
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)
        monitor.numberOfFans = 2
        monitor.cpuTemperature = 75
        monitor.fanMinSpeeds = [2000, 2000]
        monitor.fanMaxSpeeds = [6000, 6000]

        let first = waitForSets(helper, count: 1)
        XCTAssertEqual(first.map { $0[1] }, ["0"], "the second fan asked again: \(first)")
        XCTAssertEqual(controller.lastFailure?.reason, .notAuthorized)

        // A hotter reading moves Auto's target, which used to ask again.
        monitor.cpuTemperature = 85
        RunLoop.main.run(until: Date().addingTimeInterval(4.5))
        XCTAssertEqual(helper.calls.filter { $0.first == "set" }.count, 1, "\(helper.calls)")
    }

    /// The defect: Auto counted a speed as sent before the helper wrote it,
    /// so after a failed write the fans kept their old, lower speed until the
    /// curve rose further, which a steady load never does.
    func testAutoSendsAgainAfterAFailedWrite() {
        let defaults = UserDefaults.standard
        defaults.set("automatic", forKey: "fanControlMode")
        defaults.set(60.0, forKey: "autoThreshold")
        defaults.set(6000, forKey: "autoMaxSpeed")
        let helper = RecordingHelper(result: .refused, failures: 1)
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)
        monitor.numberOfFans = 1
        monitor.cpuTemperature = 75
        monitor.fanMinSpeeds = [2000]
        monitor.fanMaxSpeeds = [6000]

        let sets = waitForSets(helper, count: 2, seconds: 5)
        XCTAssertEqual(sets.map { $0[2] }, ["4000", "4000"], "\(helper.calls)")
        XCTAssertNil(controller.lastFailure)
    }

    /// The defect: with no CPU or GPU temperature, Auto returned early and
    /// left the fans at the last speed it sent, whatever the heat.
    func testAutoReturnsTheFansWhenNoTemperatureReads() {
        let defaults = UserDefaults.standard
        defaults.set("automatic", forKey: "fanControlMode")
        defaults.set(60.0, forKey: "autoThreshold")
        defaults.set(6000, forKey: "autoMaxSpeed")
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)
        monitor.numberOfFans = 1
        monitor.cpuTemperature = 75
        monitor.fanMinSpeeds = [2000]
        monitor.fanMaxSpeeds = [6000]
        XCTAssertEqual(waitForSets(helper, count: 1).count, 1)

        monitor.cpuTemperature = nil
        monitor.gpuTemperature = nil
        let deadline = Date().addingTimeInterval(9)
        while !helper.calls.contains(where: { $0.first == "auto" }) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(helper.calls.filter { $0.first == "auto" }, [["auto", "0", "no-prompt"]])

        // A temperature again: Auto takes the fans back.
        monitor.cpuTemperature = 75
        XCTAssertEqual(waitForSets(helper, count: 2, seconds: 5).count, 2, "\(helper.calls)")
        withExtendedLifetime(controller) {}
    }

    /// The defect: `fanmac manual 3000 --fan 1` on a one-fan Mac turned on
    /// separate speeds, which the popover hides there, so its slider then
    /// changed a speed nothing wrote.
    func testOneFanTakesAFanNumberAsAllFans() {
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)
        monitor.numberOfFans = 1
        monitor.cpuTemperature = 50
        monitor.fanMinSpeeds = [2000]
        monitor.fanMaxSpeeds = [6000]
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        controller.switchToManual(speed: 3000, fan: 0)
        XCTAssertFalse(controller.perFanManualControl)
        controller.setManualSpeed(4000)
        let deadline = Date().addingTimeInterval(3)
        while !helper.calls.contains(["set", "0", "4000", "prompt"]) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(helper.calls.contains(["set", "0", "4000", "prompt"]), "\(helper.calls)")
    }

    /// The defect: the sleep hand-back could raise a password prompt as the
    /// Mac went to sleep, and ran even when FanMac had never taken the fans.
    func testTheSleepHandBackNeverPrompts() {
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)
        monitor.numberOfFans = 1
        monitor.cpuTemperature = 75
        monitor.fanMinSpeeds = [2000]
        monitor.fanMaxSpeeds = [6000]
        XCTAssertEqual(waitForSets(helper, count: 1).count, 1)

        controller.handBackForSleep()
        let deadline = Date().addingTimeInterval(3)
        while !helper.calls.contains(where: { $0.first == "auto" }) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(helper.calls.filter { $0.first == "auto" }, [["auto", "0", "no-prompt"]])
    }

    /// Waits up to `seconds` for the helper to have run `count` speed writes.
    private func waitForSets(_ helper: RecordingHelper, count: Int, seconds: TimeInterval = 3) -> [[String]] {
        let deadline = Date().addingTimeInterval(seconds)
        var sets: [[String]] { helper.calls.filter { $0.first == "set" } }
        while sets.count < count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return sets
    }

    /// The defect: when something else handed the fans to macOS, Manual
    /// never took them back and FanMac went on saying it held them.
    func testManualTakesBackFansHandedToMacOS() {
        UserDefaults.standard.set("manual", forKey: "fanControlMode")
        UserDefaults.standard.set(3000, forKey: "manualFanSpeed")
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)
        monitor.numberOfFans = 2
        monitor.fanMinSpeeds = [2000, 2000]
        monitor.fanMaxSpeeds = [6000, 6000]
        XCTAssertGreaterThanOrEqual(waitForSets(helper, count: 2).count, 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5)) // the limits' own reapply
        let settled = helper.calls.filter { $0.first == "set" }.count

        monitor.fanModes = [1, 1]
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(helper.calls.filter { $0.first == "set" }.count, settled, "took fans it already held")

        monitor.fanModes = [0, 1]
        let sets = waitForSets(helper, count: settled + 2)
        XCTAssertEqual(sets.dropFirst(settled).map { Array($0.prefix(3)) }, [["set", "0", "3000"], ["set", "1", "3000"]])

        // Lost again at once: a retake waits `retakeInterval`, so FanMac
        // can't fight another fan app at the sensor rate.
        monitor.fanModes = [1, 1]
        monitor.fanModes = [3, 3]
        XCTAssertEqual(waitForSets(helper, count: settled + 3, seconds: 1).count, settled + 2)
        withExtendedLifetime(controller) {}
    }

    func testAutoTakesBackFansHandedToMacOS() {
        UserDefaults.standard.set("automatic", forKey: "fanControlMode")
        UserDefaults.standard.set(60.0, forKey: "autoThreshold")
        UserDefaults.standard.set(1.5, forKey: "autoAggressiveness")
        UserDefaults.standard.set(6000, forKey: "autoMaxSpeed")
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)
        monitor.numberOfFans = 1
        monitor.cpuTemperature = 75
        monitor.fanMinSpeeds = [2000]
        monitor.fanMaxSpeeds = [6000]
        XCTAssertEqual(waitForSets(helper, count: 1).map { $0[2] }, ["4000"])

        // A steady temperature never moves the target, so only the mode shows the loss.
        monitor.fanModes = [1]
        monitor.fanModes = [0]
        XCTAssertEqual(waitForSets(helper, count: 2, seconds: 1.5).map { $0[2] }, ["4000", "4000"])
        withExtendedLifetime(controller) {}
    }

    /// FanMac's own hand-back (sleep) reads as macOS holding the fans too.
    func testNoRetakeOfFansFanMacHandsBack() {
        UserDefaults.standard.set("manual", forKey: "fanControlMode")
        UserDefaults.standard.set(3000, forKey: "manualFanSpeed")
        let helper = RecordingHelper(delay: 0.3)
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)
        monitor.numberOfFans = 1
        monitor.fanMinSpeeds = [2000]
        monitor.fanMaxSpeeds = [6000]
        XCTAssertEqual(waitForSets(helper, count: 1).count, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let setsBefore = helper.calls.filter { $0.first == "set" }.count

        controller.restoreAutomaticControl()
        monitor.fanModes = [0] // while the helper hands it back
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        monitor.fanModes = [1]
        monitor.fanModes = [0] // after: FanMac no longer claims the fans
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(helper.calls.filter { $0.first == "set" }.count, setsBefore, "\(helper.calls)")
        XCTAssertFalse(controller.isControlEnabled)
        withExtendedLifetime(controller) {}
    }

    /// The defect: Auto kept ticking after the sleep hand-back and took the
    /// fans again within 2 s, so the Mac could fall asleep, or run its dark
    /// wakes, with FanMac holding the fans.
    func testAutoLeavesTheFansWithMacOSUntilWake() {
        UserDefaults.standard.set("automatic", forKey: "fanControlMode")
        UserDefaults.standard.set(60.0, forKey: "autoThreshold")
        UserDefaults.standard.set(1.5, forKey: "autoAggressiveness")
        UserDefaults.standard.set(6000, forKey: "autoMaxSpeed")
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)
        monitor.numberOfFans = 1
        monitor.cpuTemperature = 75
        monitor.fanMinSpeeds = [2000]
        monitor.fanMaxSpeeds = [6000]
        XCTAssertEqual(waitForSets(helper, count: 1).map { $0[2] }, ["4000"])

        controller.handBackForSleep()
        monitor.fanModes = [0]
        XCTAssertEqual(waitForSets(helper, count: 2, seconds: 3).count, 1, "\(helper.calls)")
        XCTAssertEqual(helper.calls.filter { $0.first == "auto" }.count, 1)
        XCTAssertFalse(controller.isControlEnabled)

        controller.reapplySettings() // wake
        XCTAssertEqual(waitForSets(helper, count: 2).map { $0[2] }, ["4000", "4000"])
        withExtendedLifetime(controller) {}
    }

    func testAutoIgnoresAnUnchangedLimit() {
        UserDefaults.standard.set("automatic", forKey: "fanControlMode")
        UserDefaults.standard.set(60.0, forKey: "autoThreshold")
        UserDefaults.standard.set(1.5, forKey: "autoAggressiveness")
        UserDefaults.standard.set(6000, forKey: "autoMaxSpeed")
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)
        monitor.numberOfFans = 1
        monitor.cpuTemperature = 75
        monitor.fanMinSpeeds = [2000]
        monitor.fanMaxSpeeds = [6000]
        XCTAssertEqual(waitForSets(helper, count: 1).map { $0[2] }, ["4000"])
        monitor.fanMaxSpeeds = [6000]
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(setCount(helper), 1, "\(helper.calls)")
        monitor.fanMaxSpeeds = [3500] // the curve now spans 2000–3500
        XCTAssertEqual(waitForSets(helper, count: 2).map { $0[2] }, ["4000", "2750"])
        withExtendedLifetime(controller) {}
    }

    private func manualController(_ helper: RecordingHelper, monitor: SystemMonitor) -> FanController {
        UserDefaults.standard.set("manual", forKey: "fanControlMode")
        UserDefaults.standard.set(3000, forKey: "manualFanSpeed")
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)
        monitor.numberOfFans = 1
        monitor.fanMinSpeeds = [2000]
        monitor.fanMaxSpeeds = [6000]
        return controller
    }

    private func setCount(_ helper: RecordingHelper) -> Int {
        helper.calls.filter { $0.first == "set" }.count
    }

    /// The defect: at startup the limits handler can run after the first
    /// apply (Combine doesn't order the two subscribers), and it wrote the
    /// same speed again.
    func testManualWritesOnceAtStartup() {
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        let controller = manualController(helper, monitor: monitor)
        XCTAssertEqual(waitForSets(helper, count: 1).count, 1)
        monitor.fanMaxSpeeds = [6000] // the limits handler, late
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(setCount(helper), 1, "\(helper.calls)")

        // A limit that changes the target still goes out.
        monitor.fanMaxSpeeds = [2800]
        XCTAssertEqual(waitForSets(helper, count: 2).map { $0[2] }, ["3000", "2800"])
        withExtendedLifetime(controller) {}
    }

    /// The defect: macOS reports one wake four ways (wake, screens wake,
    /// unlock, session active), and each reapplied the settings 2 s later,
    /// even when the Mac had gone back to sleep by then.
    func testOneWakeReappliesOnceAndSleepCancelsIt() {
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        let controller = manualController(helper, monitor: monitor)
        XCTAssertEqual(waitForSets(helper, count: 1).count, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let settled = setCount(helper)

        controller.handBackForSleep()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        for _ in 0..<4 { controller.reapplyAfterWake() }
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(setCount(helper), settled + 1, "\(helper.calls)")

        controller.reapplyAfterWake()
        controller.handBackForSleep() // asleep again within 2 s
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(setCount(helper), settled + 1, "\(helper.calls)")
        XCTAssertFalse(controller.isControlEnabled)
        withExtendedLifetime(controller) {}
    }

    /// The defect: a fan limit read while FanMac handed the fans back queued
    /// a write that took them again as soon as the hand-back finished.
    func testALimitChangeDuringTheHandBackLeavesTheFans() {
        let helper = RecordingHelper(delay: 0.3)
        let monitor = SystemMonitor()
        let controller = manualController(helper, monitor: monitor)
        XCTAssertEqual(waitForSets(helper, count: 1).count, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let settled = setCount(helper)

        controller.handBackForSleep()
        monitor.fanMaxSpeeds = [5900]
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(setCount(helper), settled, "\(helper.calls)")
        XCTAssertFalse(controller.isControlEnabled)
        withExtendedLifetime(controller) {}
    }

    /// The defect: switching to Auto handed the fans to macOS first, and when
    /// Auto's target hadn't moved they stayed there until its next tick.
    func testSwitchingToAutoKeepsTheFans() {
        UserDefaults.standard.set(60.0, forKey: "autoThreshold")
        UserDefaults.standard.set(1.5, forKey: "autoAggressiveness")
        UserDefaults.standard.set(6000, forKey: "autoMaxSpeed")
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        monitor.cpuTemperature = 75
        let controller = manualController(helper, monitor: monitor)
        XCTAssertEqual(waitForSets(helper, count: 1).map { $0[2] }, ["3000"])

        controller.setMode(.automatic)
        XCTAssertEqual(waitForSets(helper, count: 2, seconds: 1).map { $0[2] }, ["3000", "4000"])
        controller.setMode(.manual)
        controller.setMode(.automatic) // Auto's target hasn't moved
        XCTAssertEqual(waitForSets(helper, count: 4, seconds: 1).map { $0[2] }, ["3000", "4000", "3000", "4000"])
        XCTAssertEqual(helper.calls.filter { $0.first == "auto" }.count, 0, "\(helper.calls)")
        withExtendedLifetime(controller) {}
    }

    /// The defect: a display sleep or screen lock handed the fans to macOS,
    /// so a Manual speed didn't hold with the screen off. Only the Mac's own
    /// sleep hands them back now; its wake notices reapply the settings once.
    func testOnlyTheMacSleepingHandsTheFansBack() {
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        UserDefaults.standard.set("manual", forKey: "fanControlMode")
        UserDefaults.standard.set(3000, forKey: "manualFanSpeed")
        let viewModel = FanControlViewModel(systemMonitor: monitor, helperRunner: helper.run)
        monitor.numberOfFans = 1
        monitor.fanMinSpeeds = [2000]
        monitor.fanMaxSpeeds = [6000]
        XCTAssertEqual(waitForSets(helper, count: 1).count, 1)
        let center = NSWorkspace.shared.notificationCenter
        func post(_ name: Notification.Name) { center.post(name: name, object: NSWorkspace.shared) }
        func handBacks() -> Int { helper.calls.filter { $0.first == "auto" }.count }

        post(NSWorkspace.screensDidSleepNotification)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(handBacks(), 0, "\(helper.calls)")
        XCTAssertTrue(viewModel.fanController.isControlEnabled)

        // The display waking, or an unlock, finds the fans still held: no write.
        post(NSWorkspace.screensDidWakeNotification)
        post(NSWorkspace.sessionDidBecomeActiveNotification)
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(setCount(helper), 1, "\(helper.calls)")

        post(NSWorkspace.willSleepNotification)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(handBacks(), 1, "\(helper.calls)")
        XCTAssertFalse(viewModel.fanController.isControlEnabled)

        post(NSWorkspace.didWakeNotification)
        post(NSWorkspace.screensDidWakeNotification)
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(setCount(helper), 2, "\(helper.calls)")
        XCTAssertTrue(viewModel.fanController.isControlEnabled)
    }

    /// The defect: after the sleep hand-back, a hot reading with "Switch to
    /// Auto when hot" on started Auto, which took the fans before the Mac
    /// slept (it can stay awake 30 s after the notice) or during a dark wake,
    /// and held them through the sleep.
    func testAHotReadingAfterTheSleepHandBackWaitsForTheWake() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "autoSwitchMode")
        defaults.set(false, forKey: "enableNotifications")
        defaults.set(70.0, forKey: "highTempAlert")
        defaults.set(60.0, forKey: "autoThreshold")
        defaults.set(1.5, forKey: "autoAggressiveness")
        defaults.set(6000, forKey: "autoMaxSpeed")
        defaults.set("manual", forKey: "fanControlMode")
        defaults.set(3000, forKey: "manualFanSpeed")
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        monitor.cpuTemperature = 50
        let viewModel = FanControlViewModel(systemMonitor: monitor, helperRunner: helper.run)
        monitor.numberOfFans = 1
        monitor.fanMinSpeeds = [2000]
        monitor.fanMaxSpeeds = [6000]
        XCTAssertEqual(waitForSets(helper, count: 1).map { $0[2] }, ["3000"])
        let center = NSWorkspace.shared.notificationCenter

        center.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
        monitor.cpuTemperature = 75
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(setCount(helper), 1, "\(helper.calls)")
        XCTAssertFalse(viewModel.fanController.isControlEnabled)
        XCTAssertEqual(viewModel.fanController.mode, .automatic, "the switch waits for the wake")

        center.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        XCTAssertEqual(waitForSets(helper, count: 2, seconds: 4).map { $0[2] }, ["3000", "4000"])
        XCTAssertTrue(viewModel.fanController.isControlEnabled)
    }

    /// The same gap through the command line: a mode, speed or curve change
    /// after the sleep hand-back took the fans. The wake applies it instead.
    func testChangesAfterTheSleepHandBackWaitForTheWake() {
        UserDefaults.standard.set(60.0, forKey: "autoThreshold")
        UserDefaults.standard.set(1.5, forKey: "autoAggressiveness")
        UserDefaults.standard.set(6000, forKey: "autoMaxSpeed")
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        monitor.cpuTemperature = 75
        let controller = manualController(helper, monitor: monitor)
        XCTAssertEqual(waitForSets(helper, count: 1).map { $0[2] }, ["3000"])

        controller.handBackForSleep()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        controller.switchToManual(speed: 3500, fan: nil)
        controller.setMode(.automatic)
        controller.setAutoThreshold(65)
        controller.setMode(.manual)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(setCount(helper), 1, "\(helper.calls)")
        XCTAssertFalse(controller.isControlEnabled)

        controller.reapplySettings() // wake
        XCTAssertEqual(waitForSets(helper, count: 2).map { $0[2] }, ["3000", "3500"])
        withExtendedLifetime(controller) {}
    }

    /// FanMac opened just before a sleep finds its fans after the hand-back
    /// notice; it leaves them with macOS until the wake.
    func testFansFoundAfterTheSleepHandBackWaitForTheWake() {
        UserDefaults.standard.set("manual", forKey: "fanControlMode")
        UserDefaults.standard.set(3000, forKey: "manualFanSpeed")
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)
        controller.handBackForSleep()
        monitor.numberOfFans = 1
        monitor.fanMinSpeeds = [2000]
        monitor.fanMaxSpeeds = [6000]
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(setCount(helper), 0, "\(helper.calls)")
        XCTAssertTrue(controller.isReady)

        controller.reapplySettings() // wake
        XCTAssertEqual(waitForSets(helper, count: 1).map { $0[2] }, ["3000"])
        withExtendedLifetime(controller) {}
    }

    /// The defect: on a Mac whose mode key never reads 1 (manual) after
    /// FanMac takes a fan, FanMac took it back every 10 seconds forever.
    func testNoRetakeWhereTheModeNeverReadsHeld() {
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        let controller = manualController(helper, monitor: monitor)
        XCTAssertEqual(waitForSets(helper, count: 1).count, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let settled = setCount(helper)

        monitor.fanModes = [3]
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(setCount(helper), settled, "\(helper.calls)")
        withExtendedLifetime(controller) {}
    }

    /// The defect: another fan app kept the fans in manual mode and wrote
    /// its own speed. The mode keys still read as FanMac's, so Manual held
    /// the other app's speed while showing its own.
    func testManualTakesBackATargetAnotherAppSet() {
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        let controller = manualController(helper, monitor: monitor)
        XCTAssertEqual(waitForSets(helper, count: 1).map { $0[2] }, ["3000"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        monitor.fanModes = [1]
        monitor.fanTargets = [3000] // reads back
        monitor.fanTargets = [nil] // a failed read is no evidence
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(setCount(helper), 1, "\(helper.calls)")

        monitor.fanTargets = [3800] // another app's speed
        XCTAssertEqual(waitForSets(helper, count: 2, seconds: 1.5).map { $0[2] }, ["3000", "3000"])

        // FanMac's own change, with a reading from before it landed.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        monitor.fanTargets = [3000]
        controller.setManualSpeed(3500)
        XCTAssertEqual(waitForSets(helper, count: 3).map { $0[2] }, ["3000", "3000", "3500"])
        monitor.fanTargets = [3000]
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(setCount(helper), 3, "\(helper.calls)")
        withExtendedLifetime(controller) {}
    }

    /// Auto at a steady temperature sends nothing, so only the target check
    /// notices another app's speed.
    func testAutoTakesBackATargetAnotherAppSet() {
        UserDefaults.standard.set("automatic", forKey: "fanControlMode")
        UserDefaults.standard.set(60.0, forKey: "autoThreshold")
        UserDefaults.standard.set(1.5, forKey: "autoAggressiveness")
        UserDefaults.standard.set(6000, forKey: "autoMaxSpeed")
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)
        monitor.numberOfFans = 1
        monitor.cpuTemperature = 75
        monitor.fanMinSpeeds = [2000]
        monitor.fanMaxSpeeds = [6000]
        XCTAssertEqual(waitForSets(helper, count: 1).map { $0[2] }, ["4000"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        monitor.fanModes = [1]
        monitor.fanTargets = [4000]
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(setCount(helper), 1, "\(helper.calls)")

        monitor.fanTargets = [5500]
        XCTAssertEqual(waitForSets(helper, count: 2, seconds: 1.5).map { $0[2] }, ["4000", "4000"])
        withExtendedLifetime(controller) {}
    }

    /// The defect: a Manual speed change while the helper handed the fans
    /// back for sleep queued a write behind the hand-back, which took the
    /// fans again and held them through the sleep.
    func testASpeedChangeDuringTheSleepHandBackWaitsForTheWake() {
        let helper = RecordingHelper(delay: 0.3)
        let monitor = SystemMonitor()
        let controller = manualController(helper, monitor: monitor)
        XCTAssertEqual(waitForSets(helper, count: 1).count, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(1))

        controller.handBackForSleep()
        controller.setManualSpeed(3500)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(setCount(helper), 1, "\(helper.calls)")
        XCTAssertFalse(controller.isControlEnabled)

        controller.reapplySettings() // wake
        XCTAssertEqual(waitForSets(helper, count: 2).map { $0[2] }, ["3000", "3500"])
        withExtendedLifetime(controller) {}
    }

    /// A Mac whose SMC reports a target other than the one written must not
    /// be rewritten every `retakeInterval`.
    func testNoRetakeWhereTheTargetNeverReadsBack() {
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        let controller = manualController(helper, monitor: monitor)
        XCTAssertEqual(waitForSets(helper, count: 1).count, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        monitor.fanTargets = [2500]
        monitor.fanTargets = [3800]
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(setCount(helper), 1, "\(helper.calls)")
        withExtendedLifetime(controller) {}
    }

    func testAMacWithoutFansIsReadyAndTakesNothing() {
        UserDefaults.standard.set("manual", forKey: "fanControlMode")
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)
        monitor.hasNoFans = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(controller.isReady)
        XCTAssertTrue(controller.hasNoFans)

        controller.setMode(.automatic)
        controller.switchToManual(speed: 3000, fan: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(helper.calls, [])
        XCTAssertFalse(controller.isControlEnabled, "would say FanMac controls fans that don't exist")
    }

    func testQuitHandsEveryFanBackAndDropsLaterWrites() {
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        monitor.numberOfFans = 2
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)
        controller.setMode(.manual)
        controller.setManualSpeed(3000)

        let done = expectation(description: "hand-back finished")
        controller.handBackForQuit {
            done.fulfill()
        }
        // Changes that arrive while FanMac quits must not take the fans again.
        controller.setManualSpeed(4321)
        controller.setMode(.automatic)
        wait(for: [done], timeout: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let calls = helper.calls
        XCTAssertEqual(calls.suffix(2), [["auto", "0", "no-prompt"], ["auto", "1", "no-prompt"]])
        XCTAssertFalse(calls.contains { $0.first == "set" && $0[2] == "4321" })
    }

    func testQuitCompletesOnceWhenTheHelperFails() {
        let helper = RecordingHelper(result: .notAuthorized)
        let monitor = SystemMonitor()
        monitor.numberOfFans = 2
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)

        let done = expectation(description: "hand-back finished")
        done.expectedFulfillmentCount = 1
        done.assertForOverFulfill = true
        controller.handBackForQuit(timeout: 0.5) {
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(helper.calls, [["auto", "0", "no-prompt"], ["auto", "1", "no-prompt"]])
    }

    func testQuitCompletesOnceAfterTimeoutWhenTheHelperHangs() {
        let helper = RecordingHelper(delay: 1.0)
        let monitor = SystemMonitor()
        monitor.numberOfFans = 1
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)

        let done = expectation(description: "hand-back timed out")
        done.assertForOverFulfill = true
        let started = Date()
        controller.handBackForQuit(timeout: 0.2) {
            done.fulfill()
        }
        wait(for: [done], timeout: 0.9)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.9)
        // The hand-back finishing later must not quit a second time.
        RunLoop.main.run(until: Date().addingTimeInterval(1.3))
        XCTAssertEqual(helper.calls, [["auto", "0", "no-prompt"]])
    }

    /// A quit can start inside a main-queue block (a SwiftUI button action,
    /// say). AppKit then waits for the reply by running the run loop in
    /// modal-panel mode inside that block, where later main-queue blocks
    /// can't run. The completion must still arrive.
    func testQuitCompletesInsideAMainQueueBlockWaitingInModalPanelMode() {
        let helper = RecordingHelper()
        let monitor = SystemMonitor()
        monitor.numberOfFans = 2
        let controller = FanController(systemMonitor: monitor, helperRunner: helper.run)

        let waited = expectation(description: "quit wait finished")
        DispatchQueue.main.async {
            var replied = false
            controller.handBackForQuit {
                replied = true
            }
            let deadline = Date().addingTimeInterval(3)
            while !replied && Date() < deadline {
                RunLoop.current.run(mode: .modalPanel, before: deadline)
            }
            XCTAssertTrue(replied, "the hand-back's completion never reached the modal-panel wait")
            waited.fulfill()
        }
        wait(for: [waited], timeout: 5)
        XCTAssertEqual(helper.calls, [["auto", "0", "no-prompt"], ["auto", "1", "no-prompt"]])
    }

    func testQuitTimeoutFiresInsideAMainQueueBlockWaitingInModalPanelMode() {
        let monitor = SystemMonitor()
        monitor.numberOfFans = 1
        let controller = FanController(systemMonitor: monitor, helperRunner: RecordingHelper(delay: 2).run)

        let waited = expectation(description: "quit wait finished")
        DispatchQueue.main.async {
            var replied = false
            let started = Date()
            controller.handBackForQuit(timeout: 0.2) {
                replied = true
            }
            let deadline = Date().addingTimeInterval(1.5)
            while !replied && Date() < deadline {
                RunLoop.current.run(mode: .modalPanel, before: deadline)
            }
            XCTAssertTrue(replied, "the timeout never reached the modal-panel wait")
            XCTAssertLessThan(Date().timeIntervalSince(started), 1)
            waited.fulfill()
        }
        wait(for: [waited], timeout: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(2.2))
    }

    func testClosingTheGateTerminatesARunningWrite() throws {
        let gate = HelperGate()
        let write = Process()
        write.executableURL = URL(fileURLWithPath: "/bin/sleep")
        write.arguments = ["30"]
        XCTAssertTrue(try gate.start(write, args: ["set", "0", "3000"]))

        gate.close()
        write.waitUntilExit()
        XCTAssertEqual(write.terminationReason, .uncaughtSignal)
        XCTAssertEqual(write.terminationStatus, SIGTERM)

        let lateWrite = Process()
        lateWrite.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertFalse(try gate.start(lateWrite, args: ["set", "0", "3000"]))
        XCTAssertEqual(lateWrite.processIdentifier, 0, "a write after close must not start")

        let handBack = Process()
        handBack.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        XCTAssertTrue(try gate.start(handBack, args: ["auto", "0"]))
        handBack.waitUntilExit()
        gate.finished(handBack)
        XCTAssertEqual(handBack.terminationStatus, 0)
    }
}

/// Stands in for the privileged helper and records each command, with
/// "prompt" or "no-prompt" appended for whether it could ask for a password.
private final class RecordingHelper: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let result: FanHelperFailure?
    private let delay: TimeInterval
    /// How many calls return `result` before the rest succeed; nil for all.
    private let failures: Int?

    init(result: FanHelperFailure? = nil, delay: TimeInterval = 0, failures: Int? = nil) {
        self.result = result
        self.delay = delay
        self.failures = failures
    }

    var calls: [[String]] {
        lock.withLock { recorded }
    }

    var run: HelperRunner {
        { [self] args, allowPrompt in
            let count = lock.withLock {
                recorded.append(args + [allowPrompt ? "prompt" : "no-prompt"])
                return recorded.count
            }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            if let failures, count > failures { return nil }
            return result
        }
    }
}
