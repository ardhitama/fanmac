//
//  FanControlViewModel.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  The app's state for the popover, Settings and the menu bar: readings from
//  SystemMonitor, fan control through FanController, and the alerts.
//

import Foundation
import Combine
import SwiftUI
import AppKit
import UserNotifications

@MainActor
class FanControlViewModel: ObservableObject {
    // Temperature readings
    @Published var cpuTemperature: Double?
    @Published var gpuTemperature: Double?
    
    // Fan data
    @Published var fanSpeeds: [Int] = []
    @Published var fanMinSpeeds: [Int] = []
    @Published var fanMaxSpeeds: [Int] = []
    @Published var numberOfFans: Int = 0
    /// This Mac has no fans (see SystemMonitor.hasNoFans).
    @Published var hasNoFans = false
    @Published var currentFanSpeed: Int = 0
    
    // Control state
    @Published var controlMode: ControlMode = .manual
    @Published var manualSpeed: Int = 2000
    @Published var autoThreshold: Double = 60.0
    @Published var autoMaxSpeed: Int = 4500
    @Published var autoAggressiveness: Double = 1.5

    /// When true (manual mode), each fan uses its own target RPM from `manualSpeeds`.
    @Published var perFanManualControl: Bool = false
    @Published var manualSpeeds: [Int] = []
    
    // Status
    @Published var isMonitoring = false
    @Published var hasAccess = false
    @Published var lastError: String?
    @Published var statusMessage: String = ""
    @Published var lastWriteSuccess = false
    /// True while FanMac holds the fans; false while macOS controls them.
    @Published var isControlEnabled = false
    /// Per-fan targets FanMac last applied; empty while macOS controls the fans.
    @Published var appliedTargets: [Int] = []
    @Published var lastFailure: FanControlFailure?
    @Published var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState

    // Settings
    @Published var statusBarDisplayMode: String = "temperature"
    @Published private(set) var enableNotifications = true
    @Published private(set) var highTempAlert: Double = 85.0
    @Published private(set) var autoSwitchMode = false
    /// Set once an alert fires; cleared when the CPU cools 5 °C below the threshold.
    private var highTempAlertShown = false
    
    private let systemMonitor: SystemMonitor
    let fanController: FanController
    private var cancellables = Set<AnyCancellable>()
    
    /// Tests pass their own monitor and helper. A default argument would
    /// build the monitor outside the main actor.
    init(systemMonitor: SystemMonitor? = nil, helperRunner: HelperRunner? = nil) {
        let systemMonitor = systemMonitor ?? SystemMonitor()
        self.systemMonitor = systemMonitor
        self.fanController = FanController(systemMonitor: systemMonitor, helperRunner: helperRunner)
        
        // Load settings from UserDefaults
        self.statusBarDisplayMode = UserDefaults.standard.string(forKey: "statusBarDisplayMode") ?? "temperature"
        self.enableNotifications = UserDefaults.standard.object(forKey: "enableNotifications") as? Bool ?? true
        self.highTempAlert = UserDefaults.standard.double(forKey: "highTempAlert") > 0 ? UserDefaults.standard.double(forKey: "highTempAlert") : 85.0
        self.autoSwitchMode = UserDefaults.standard.object(forKey: "autoSwitchMode") as? Bool ?? false
        
        setupBindings()
        setupSettingsObservers()
        setupSleepWakeNotifications()
    }
    
    private func setupSettingsObservers() {
        // Alert once when the CPU crosses the threshold, not on every reading, and
        // again only after it has cooled 5 °C below it.
        $cpuTemperature
            .sink { [weak self] temp in
                guard let self = self, let cpuTemp = temp else { return }
                if cpuTemp > self.highTempAlert {
                    if self.enableNotifications && !self.highTempAlertShown {
                        self.highTempAlertShown = true
                        self.showHighTempNotification(cpuTemp)
                    }
                } else if cpuTemp < self.highTempAlert - 5 {
                    self.highTempAlertShown = false
                }
            }
            .store(in: &cancellables)

        // Observe auto switch mode for automatic mode activation
        $cpuTemperature
            .sink { [weak self] temp in
                guard let self = self else { return }
                if self.autoSwitchMode, let cpuTemp = temp, cpuTemp > self.highTempAlert {
                    if self.controlMode != .automatic {
                        print("Auto-switching to automatic mode due to high temperature: \(cpuTemp)°C")
                        self.setControlMode(.automatic)
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .map { _ in ProcessInfo.processInfo.thermalState }
            .receive(on: DispatchQueue.main)
            .assign(to: &$thermalState)
    }

    // MARK: - Settings

    func setEnableNotifications(_ enabled: Bool) {
        enableNotifications = enabled
        UserDefaults.standard.set(enabled, forKey: "enableNotifications")
    }

    func setHighTempAlert(_ celsius: Double) {
        highTempAlert = celsius
        UserDefaults.standard.set(celsius, forKey: "highTempAlert")
    }

    func setAutoSwitchMode(_ enabled: Bool) {
        autoSwitchMode = enabled
        UserDefaults.standard.set(enabled, forKey: "autoSwitchMode")
    }

    var monitoringInterval: TimeInterval {
        let saved = UserDefaults.standard.double(forKey: SystemMonitor.monitoringIntervalKey)
        return saved > 0 ? saved : SystemMonitor.defaultMonitoringInterval
    }

    func setMonitoringInterval(_ seconds: TimeInterval) {
        systemMonitor.setMonitoringInterval(seconds)
    }
    
    /// Posts the alert through Notification Center. The first alert asks
    /// for permission; once the person has answered, asking again returns
    /// their answer without a prompt. (NSUserNotification, used before, has
    /// been deprecated since macOS 11.)
    private func showHighTempNotification(_ temperature: Double) {
        // Notification Center serves only apps; the test runner isn't one.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = "The CPU is hot"
        content.body = "It’s at \(Int(temperature.rounded())) °C, above your alert temperature of \(Int(highTempAlert)) °C."
            + (fanController.mode == .automatic || hasNoFans ? "" : " Auto speeds the fans up with the heat.")
        content.sound = .default
        let request = UNNotificationRequest(identifier: "highTemperature", content: content, trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                // Asks the first time only; afterwards it returns the person's choice.
                guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
                try await center.add(request)
            } catch {
                print("FanControl: can’t post the alert: \(error.localizedDescription)")
            }
        }
    }
    
    private func setupBindings() {
        // System monitor bindings
        systemMonitor.$cpuTemperature
            .receive(on: DispatchQueue.main)
            .assign(to: &$cpuTemperature)
        
        systemMonitor.$gpuTemperature
            .receive(on: DispatchQueue.main)
            .assign(to: &$gpuTemperature)
        
        systemMonitor.$fanSpeeds
            .receive(on: DispatchQueue.main)
            .assign(to: &$fanSpeeds)
        
        systemMonitor.$fanMinSpeeds
            .receive(on: DispatchQueue.main)
            .assign(to: &$fanMinSpeeds)
        
        systemMonitor.$fanMaxSpeeds
            .receive(on: DispatchQueue.main)
            .assign(to: &$fanMaxSpeeds)
        
        systemMonitor.$numberOfFans
            .receive(on: DispatchQueue.main)
            .assign(to: &$numberOfFans)

        systemMonitor.$hasNoFans
            .receive(on: DispatchQueue.main)
            .assign(to: &$hasNoFans)
        
        systemMonitor.$isMonitoring
            .receive(on: DispatchQueue.main)
            .assign(to: &$isMonitoring)
        
        systemMonitor.$hasAccess
            .receive(on: DispatchQueue.main)
            .assign(to: &$hasAccess)
        
        systemMonitor.$lastError
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastError)
        
        // Fan controller bindings
        fanController.$mode
            .receive(on: DispatchQueue.main)
            .assign(to: &$controlMode)
        
        fanController.$manualSpeed
            .receive(on: DispatchQueue.main)
            .assign(to: &$manualSpeed)

        fanController.$perFanManualControl
            .receive(on: DispatchQueue.main)
            .assign(to: &$perFanManualControl)

        fanController.$manualSpeeds
            .receive(on: DispatchQueue.main)
            .assign(to: &$manualSpeeds)
        
        fanController.$autoThreshold
            .receive(on: DispatchQueue.main)
            .assign(to: &$autoThreshold)
        
        fanController.$autoMaxSpeed
            .receive(on: DispatchQueue.main)
            .assign(to: &$autoMaxSpeed)
        
        fanController.$autoAggressiveness
            .receive(on: DispatchQueue.main)
            .assign(to: &$autoAggressiveness)
        
        fanController.$statusMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$statusMessage)
        
        fanController.$lastWriteSuccess
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastWriteSuccess)

        fanController.$isControlEnabled
            .receive(on: DispatchQueue.main)
            .assign(to: &$isControlEnabled)

        fanController.$appliedTargets
            .receive(on: DispatchQueue.main)
            .assign(to: &$appliedTargets)

        fanController.$lastFailure
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastFailure)

        // Average reported RPM across detected fans (display / menu bar).
        Publishers.CombineLatest($fanSpeeds, $numberOfFans)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] speeds, n in
                guard let self = self else { return }
                guard !speeds.isEmpty, n > 0 else {
                    self.currentFanSpeed = 0
                    return
                }
                let slice = min(speeds.count, Int(n))
                let sum = speeds.prefix(slice).reduce(0, +)
                self.currentFanSpeed = Int(round(Double(sum) / Double(slice)))
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Monitoring Control
    
    private func setupSleepWakeNotifications() {
        // Register for sleep notification
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        
        // Register for wake notification
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        // A display sleep or screen lock leaves the fans alone: the Mac is
        // still awake, and a Manual speed should hold with the screen off.

        // Register for screen wake notification
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        
        // Register for session unlock notification (user logged back in)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
        
        // Also register for session active notification
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }
    
    @objc private func systemWillSleep() {
        print("FanControl: System going to sleep - restoring system control")
        fanController.handBackForSleep()
    }
    
    @objc private func systemDidWake() {
        print("FanControl: System woke up - reapplying user settings")
        fanController.reapplyAfterWake()
    }
    
    // MARK: - Monitoring Control
    
    func startMonitoring() {
        systemMonitor.startMonitoring()
    }
    
    func stopMonitoring() {
        systemMonitor.stopMonitoring()
    }
    
    // MARK: - Fan Control
    
    func setManualSpeed(_ speed: Int) {
        fanController.setManualSpeed(speed)
    }

    func setPerFanManualControl(_ enabled: Bool) {
        fanController.setPerFanManualControl(enabled)
    }

    func setManualSpeedForFan(index: Int, speed: Int) {
        fanController.setManualSpeed(fanIndex: index, speed: speed)
    }

    /// Lower bound for unified sliders when SMC minima are known.
    var effectiveUnifiedMinRPM: Int {
        guard !fanMinSpeeds.isEmpty else { return FanRPMBounds.fallbackMinWhenSMCUnreadable }
        return fanMinSpeeds.min() ?? FanRPMBounds.fallbackMinWhenSMCUnreadable
    }

    /// Upper bound for unified sliders when SMC maxima are known.
    var effectiveUnifiedMaxRPM: Int {
        guard !fanMaxSpeeds.isEmpty else { return FanRPMBounds.fallbackMaxWhenSMCUnreadable }
        return fanMaxSpeeds.max() ?? FanRPMBounds.fallbackMaxWhenSMCUnreadable
    }

    func minRPM(atFan index: Int) -> Int {
        guard index >= 0, index < fanMinSpeeds.count else { return FanRPMBounds.fallbackMinWhenSMCUnreadable }
        return fanMinSpeeds[index]
    }

    func maxRPM(atFan index: Int) -> Int {
        guard index >= 0, index < fanMaxSpeeds.count else { return FanRPMBounds.fallbackMaxWhenSMCUnreadable }
        return fanMaxSpeeds[index]
    }

    /// Mean fan utilization in \([0,100]\) using each fan's SMC min/max span.
    var averageFanLoadPercent: Int {
        guard !fanSpeeds.isEmpty else {
            let ref = fanMaxSpeeds.max() ?? FanRPMBounds.fallbackMaxWhenSMCUnreadable
            guard ref > 0 else { return 0 }
            return min(100, max(0, Int(round(Double(currentFanSpeed) / Double(ref) * 100))))
        }
        var sum = 0.0
        var count = 0
        for i in 0..<fanSpeeds.count {
            let mn = i < fanMinSpeeds.count ? fanMinSpeeds[i] : FanRPMBounds.fallbackMinWhenSMCUnreadable
            guard i < fanMaxSpeeds.count else { continue }
            let mx = fanMaxSpeeds[i]
            guard mx > mn else { continue }
            let p = Double(fanSpeeds[i] - mn) / Double(mx - mn)
            sum += min(1.0, max(0.0, p))
            count += 1
        }
        guard count > 0 else { return 0 }
        return Int(min(100, max(0, round(sum / Double(count) * 100))))
    }
    
    func setControlMode(_ mode: ControlMode) {
        fanController.setMode(mode)
    }
    
    /// Hands the fans back to macOS before FanMac quits; see `FanController.handBackForQuit`.
    func handBackFansForQuit(completion: @escaping () -> Void) {
        fanController.handBackForQuit(completion: completion)
    }

    /// Repeats whatever last failed: handing the fans back, or the current mode's targets.
    func retryFanControl() {
        if lastFailure?.operation == .restoreSystemControl {
            fanController.restoreAutomaticControl()
        } else {
            fanController.reapplySettings()
        }
    }
    
    func setAutoThreshold(_ threshold: Double) {
        fanController.setAutoThreshold(threshold)
    }
    
    func setAutoMaxSpeed(_ speed: Int) {
        fanController.setAutoMaxSpeed(speed)
    }
    
    func setAutoAggressiveness(_ value: Double) {
        fanController.setAutoAggressiveness(value)
    }
    
    // MARK: - Helper Functions
    
    func getMaxTemperature() -> Double {
        return max(cpuTemperature ?? 0, gpuTemperature ?? 0)
    }
}
