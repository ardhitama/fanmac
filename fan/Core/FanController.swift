//
//  FanController.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  SMC fan control with per-fan targets and hardware-derived RPM limits.
//

import AppKit
import Combine
import IOKit

enum ControlMode: String, CaseIterable {
    case manual
    case automatic
}

/// Why a privileged-helper call failed; the popover picks its recovery text from this.
nonisolated enum FanHelperFailure: Equatable {
    /// The helper binary is missing.
    case helperMissing
    /// sudo refused the helper, and the administrator prompt failed or was cancelled.
    case notAuthorized
    /// The helper ran as root, but the fan controller refused the change.
    case refused
}

nonisolated struct FanControlFailure: Equatable {
    enum Operation: Equatable {
        case setSpeed
        case restoreSystemControl
    }

    let operation: Operation
    let reason: FanHelperFailure

    /// What failed, as the popover and `fanmac` say it.
    var summary: String {
        switch operation {
        case .setSpeed: return "Couldn’t set the fan speed."
        case .restoreSystemControl: return "Couldn’t return the fans to macOS."
        }
    }

    /// How to recover.
    var recovery: String {
        switch reason {
        case .refused:
            return "The Mac’s fan controller refused the change. If the fans stay at 0 RPM, shut down the Mac for 30 seconds to reset the controller, then try again."
        case .helperMissing:
            return "The helper is missing. Install it again, then try again."
        case .notAuthorized:
            return "The helper isn’t allowed to run without a password. Install it again to restore its permission."
        }
    }
}

/// Runs one privileged-helper command and returns nil on success, or why it
/// failed. `allowPrompt` is false at quit, where an administrator prompt
/// can't be shown. Tests inject one in place of the helper.
typealias HelperRunner = @Sendable (_ args: [String], _ allowPrompt: Bool) -> FanHelperFailure?

/// Stops FanMac changing the fans once it starts handing them back at quit.
/// After `close()`, only `auto` commands run, and a speed write that is
/// still running is terminated so the hand-back doesn't wait behind it;
/// sudo passes the SIGTERM on to the helper.
nonisolated final class HelperGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var runningWrite: Process?

    var isClosed: Bool {
        lock.withLock { closed }
    }

    /// Whether `args` may still run.
    func allows(_ args: [String]) -> Bool {
        lock.withLock { !closed || Self.isHandBack(args) }
    }

    /// Starts `process` for `args`, or returns false without starting it
    /// once the gate is closed to `args`.
    func start(_ process: Process, args: [String]) throws -> Bool {
        try lock.withLock {
            guard !closed || Self.isHandBack(args) else { return false }
            try process.run()
            if !Self.isHandBack(args) { runningWrite = process }
            return true
        }
    }

    func finished(_ process: Process) {
        lock.withLock {
            if runningWrite === process { runningWrite = nil }
        }
    }

    func close() {
        let write: Process? = lock.withLock {
            closed = true
            return runningWrite
        }
        if let write, write.isRunning { write.terminate() }
    }

    private static func isHandBack(_ args: [String]) -> Bool {
        args.first == "auto"
    }
}

/// Calls an action once, from whichever caller comes first.
private final class OneShot {
    private var action: (() -> Void)?

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func fire() {
        let action = self.action
        self.action = nil
        action?()
    }
}

class FanController: ObservableObject {
    /// Auto until the person picks: it follows the heat, where a fixed
    /// Manual speed would hold the fans low under any load.
    @Published var mode: ControlMode = .automatic
    /// Unified manual target (single slider / legacy settings).
    @Published var manualSpeed: Int = 2000
    /// When `perFanManualControl` is true, each index maps to `F%dTg` for fan `d`.
    @Published var manualSpeeds: [Int] = []
    @Published var perFanManualControl: Bool = false

    @Published var autoThreshold: Double = 60.0
    @Published var autoMaxSpeed: Int = 4500
    @Published var autoAggressiveness: Double = 1.5  // 0.0 = always min, 1.5 = temp-based, 3.0 = always max
    @Published var isControlEnabled = false
    @Published var lastWriteSuccess = false
    @Published var statusMessage: String = ""
    /// When Auto sends a new speed; see `AutoSpeedGate`.
    private var autoSpeeds = AutoSpeedGate()
    /// Per-fan targets the helper last applied; empty while macOS controls the fans.
    @Published var appliedTargets: [Int] = []
    /// The most recent helper failure, cleared by the next success.
    @Published var lastFailure: FanControlFailure?
    /// Whether FanMac knows the fans' limits and has applied the saved
    /// settings. A change made before then clamps to placeholder limits.
    private(set) var isReady = false
    /// This Mac has no fans, so there is nothing to control.
    var hasNoFans: Bool { systemMonitor?.hasNoFans ?? false }

    private weak var systemMonitor: SystemMonitor?
    private var autoControlTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Serializes privileged-helper invocations off the main thread so a slider
    /// drag (or the auto loop) never blocks the UI on sudo + waitUntilExit.
    private let applyQueue = DispatchQueue(label: "com.fanmac.fan-apply", qos: .userInitiated)
    /// The newest targets waiting for the helper. Each write blocks for at
    /// least 0.2 s per fan, and a slider drag asks for many more writes than
    /// that, so only the latest request waits; older ones are dropped.
    private var pendingTargets: [Int]?
    private var isWritingTargets = false
    /// The targets the helper is writing now, between `pendingTargets` and `appliedTargets`.
    private var writingTargets: [Int]?
    /// Whether every readable fan mode has read 1 (manual) since FanMac last
    /// handed the fans back. Only then does a fan reading otherwise mean
    /// FanMac lost it; a Mac whose mode key never reads 1 would otherwise be
    /// rewritten every `retakeInterval`.
    private var fansReadHeld = false
    /// Whether every readable fan target (F%dTg) has read as FanMac's applied
    /// target since FanMac last wrote it. Only then does a different target
    /// mean another app set its own speed; a Mac whose SMC reports a target
    /// other than the one written would otherwise be rewritten forever.
    private var targetsReadBack = false
    /// SMC targets within this many RPM of FanMac's count as FanMac's.
    static let targetTolerance = 10
    /// The settings reapply after a wake. macOS reports one wake several ways,
    /// and the Mac may sleep again before it runs.
    private var wakeReapply: DispatchWorkItem?
    /// FanMac handed the fans back for sleep and hasn't reapplied since. A
    /// display wake or unlock without it finds the fans still held. While it
    /// is set nothing takes the fans: the Mac can stay awake for 30 s after
    /// the sleep notice, or wake dark, and fans taken then stay held through
    /// the sleep. Changes are saved, and the wake reapply applies them.
    private var sleptSinceReapply = false
    /// The helper is handing the fans to macOS (sleep, or a retry after a failed hand-back).
    private var isHandingBack = false
    /// The last time FanMac took back fans something else had handed to macOS.
    private var lastRetake: Date?
    /// Auto's readings in a row without a CPU or GPU temperature.
    private var readingsWithoutTemperature = 0
    private var retakeCheckScheduled = false
    /// Retakes are this far apart at least, so FanMac can't fight another fan
    /// app at the sensor rate.
    static let retakeInterval: TimeInterval = 10
    private let helperGate = HelperGate()
    private let helperRunner: HelperRunner?
    /// Hands the fans back if FanMac dies before it can (see FanReleaseWatchdog).
    private let releaseWatchdog = FanReleaseWatchdog()

    private var smcHelperPath: String {
        PermissionsManager.helperPath
    }

    init(systemMonitor: SystemMonitor, helperRunner: HelperRunner? = nil) {
        self.systemMonitor = systemMonitor
        self.helperRunner = helperRunner
        loadSettings()

        systemMonitor.$fanMaxSpeeds
            .combineLatest(systemMonitor.$fanMinSpeeds, systemMonitor.$numberOfFans)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, fanCount in
                guard let self = self, fanCount > 0 else { return }
                self.onHardwareLimitsUpdated()
            }
            .store(in: &cancellables)

        // Wait for the fans' limits as well as their count. Until the first
        // reading, targets clamp to the fallback limits, which would drive a
        // fan below its real minimum.
        systemMonitor.$numberOfFans
            .combineLatest(systemMonitor.$fanMinSpeeds, systemMonitor.$fanMaxSpeeds)
            .receive(on: DispatchQueue.main)
            .filter { count, minima, maxima in count > 0 && minima.count >= count && maxima.count >= count }
            .first()
            .sink { [weak self] _ in
                print("FanController: Fans detected, applying initial settings")
                self?.applyInitialSettings()
            }
            .store(in: &cancellables)

        // Without fans there is nothing to apply, and a change is refused at
        // once rather than after waiting for fans that never come.
        systemMonitor.$hasNoFans
            .receive(on: DispatchQueue.main)
            .filter { $0 }
            .first()
            .sink { [weak self] _ in self?.isReady = true }
            .store(in: &cancellables)

        // Another fan app, a tool or the firmware can hand the fans to macOS.
        // FanMac only wrote again when its own target moved, so it went on
        // saying it held fans macOS drove, and in Manual it never took them back.
        systemMonitor.$fanModes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] modes in
                guard let self else { return }
                let readable = modes.compactMap { $0 }
                if !readable.isEmpty && readable.allSatisfy({ $0 == 1 }) { self.fansReadHeld = true }
                self.retakeFansIfLost()
            }
            .store(in: &cancellables)

        // Another fan app can keep the fans in manual mode and write its own
        // speed. The mode keys then still read as FanMac's, and Manual held
        // the other app's speed while showing its own.
        systemMonitor.$fanTargets
            .receive(on: DispatchQueue.main)
            .sink { [weak self] targets in
                guard let self else { return }
                if self.targetsMatch(targets) { self.targetsReadBack = true }
                self.retakeFansIfLost()
            }
            .store(in: &cancellables)
    }

    deinit {
        stopAutoControl()
    }

    // MARK: - Hardware-derived clamps

    private var unifiedMinClamp: Int {
        systemMonitor?.fanMinSpeeds.min() ?? FanRPMBounds.fallbackMinWhenSMCUnreadable
    }

    private var unifiedMaxClamp: Int {
        systemMonitor?.fanMaxSpeeds.max() ?? FanRPMBounds.fallbackMaxWhenSMCUnreadable
    }

    private func minRPM(for index: Int) -> Int {
        guard let monitor = systemMonitor,
              index >= 0,
              index < monitor.fanMinSpeeds.count else {
            return FanRPMBounds.fallbackMinWhenSMCUnreadable
        }
        return monitor.fanMinSpeeds[index]
    }

    private func maxRPM(for index: Int) -> Int {
        guard let monitor = systemMonitor,
              index >= 0,
              index < monitor.fanMaxSpeeds.count else {
            return FanRPMBounds.fallbackMaxWhenSMCUnreadable
        }
        return monitor.fanMaxSpeeds[index]
    }

    private func clampToFan(_ speed: Int, index: Int) -> Int {
        max(minRPM(for: index), min(maxRPM(for: index), speed))
    }

    private func clampUnified(_ speed: Int) -> Int {
        max(unifiedMinClamp, min(unifiedMaxClamp, speed))
    }

    private func onHardwareLimitsUpdated() {
        guard let monitor = systemMonitor, monitor.numberOfFans > 0 else { return }
        // A write queued now would run after the hand-back and take the fans
        // straight back.
        guard !isHandingBack else { return }
        ensureManualSpeedsSize()
        // Do NOT clamp the stored preferences (manualSpeed / autoMaxSpeed) to the live
        // hardware max here. F{n}Mx reads intermittently on Apple Silicon — it flips to
        // the unreadable fallback — and this fires on every such flip, so clamping would
        // repeatedly shrink and re-save the user's ceiling (the "max speed forgets itself"
        // bug). Targets are clamped to the real limit at apply time instead, so a low
        // reading never spins the fan past hardware while the preference is preserved.
        // Limits arrive one reading at a time, and at startup this can run
        // after the first apply; only a changed target is written.
        if mode == .manual && isControlEnabled {
            applyManualTargets(onlyIfChanged: true)
        } else if mode == .automatic && isControlEnabled {
            autoSpeeds.reset()
            updateAutoControl(onlyIfChanged: true)
        }
    }

    private func ensureManualSpeedsSize() {
        guard let monitor = systemMonitor, monitor.numberOfFans > 0 else { return }
        let n = monitor.numberOfFans
        if manualSpeeds.count < n {
            var copy = manualSpeeds
            let template = copy.last ?? manualSpeed
            while copy.count < n {
                let idx = copy.count
                copy.append(clampToFan(template, index: idx))
            }
            manualSpeeds = copy
        } else if manualSpeeds.count > n {
            manualSpeeds = Array(manualSpeeds.prefix(n))
        }
    }

    private func syncManualSpeedsFromUnified() {
        guard let monitor = systemMonitor, monitor.numberOfFans > 0 else { return }
        manualSpeeds = (0..<monitor.numberOfFans).map { clampToFan(manualSpeed, index: $0) }
    }

    // MARK: - Lifecycle

    private func applyInitialSettings() {
        print("FanController: Applying initial settings - mode: \(mode)")
        guard !sleptSinceReapply else {
            isReady = true
            return
        }
        switch mode {
        case .manual:
            enableManualMode()
            ensureManualSpeedsSize()
            if !perFanManualControl {
                syncManualSpeedsFromUnified()
            }
            applyManualTargets()
        case .automatic:
            startAutoControl()
        }
        isReady = true
    }

    /// Reapplies the settings once the Mac has settled after a wake. The
    /// wake, screens-wake, unlock and session notifications share one
    /// reapply, 2 s after the last of them; a sleep cancels it. It runs only
    /// after a sleep hand-back, or to retry a failure.
    func reapplyAfterWake() {
        wakeReapply?.cancel()
        let reapply = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.wakeReapply = nil
            guard self.sleptSinceReapply || self.lastFailure != nil else { return }
            self.reapplySettings()
        }
        wakeReapply = reapply
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: reapply)
    }

    private func cancelWakeReapply() {
        wakeReapply?.cancel()
        wakeReapply = nil
    }

    func reapplySettings() {
        print("FanController: Reapplying settings after wake - mode: \(mode)")
        guard let monitor = systemMonitor, monitor.numberOfFans > 0 else {
            if hasNoFans { return }
            print("FanController: No fans detected yet, retrying in 2 seconds...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.reapplySettings()
            }
            return
        }

        sleptSinceReapply = false
        switch mode {
        case .manual:
            enableManualMode()
            ensureManualSpeedsSize()
            if !perFanManualControl {
                syncManualSpeedsFromUnified()
            }
            applyManualTargets()
            print("FanController: Manual mode reapplied")
        case .automatic:
            enableManualMode()
            startAutoControl()
            autoSpeeds.reset()
            updateAutoControl()
            print("FanController: Auto mode reapplied")
        }
    }

    /// Toggle independent sliders for each fan (manual mode only).
    func setPerFanManualControl(_ enabled: Bool) {
        perFanManualControl = enabled
        if enabled {
            syncManualSpeedsFromUnified()
        } else {
            if !manualSpeeds.isEmpty {
                let avg = Int(round(Double(manualSpeeds.reduce(0, +)) / Double(manualSpeeds.count)))
                manualSpeed = clampUnified(avg)
            }
            syncManualSpeedsFromUnified()
        }
        saveSettings()
        if mode == .manual && isControlEnabled {
            applyManualTargets()
        }
    }

    func setManualSpeed(_ speed: Int) {
        guard mode == .manual else { return }
        manualSpeed = clampUnified(speed)
        if !perFanManualControl {
            syncManualSpeedsFromUnified()
        }
        if isControlEnabled {
            applyManualTargets()
        }
        saveSettings()
    }

    func setManualSpeed(fanIndex: Int, speed: Int) {
        guard mode == .manual, perFanManualControl else { return }
        ensureManualSpeedsSize()
        guard fanIndex >= 0, fanIndex < manualSpeeds.count else { return }
        var next = manualSpeeds
        next[fanIndex] = clampToFan(speed, index: fanIndex)
        manualSpeeds = next
        saveSettings()
        if isControlEnabled {
            applyManualTargets()
        }
    }

    /// Holds `speed` on one fan (`fan`) or all of them, switching to Manual in
    /// the same step, so the fans never first spin to the previous manual speed.
    func switchToManual(speed: Int, fan: Int?) {
        // With one fan, separate speeds would leave the popover's single
        // slider driving a speed nothing writes.
        if let fan, (systemMonitor?.numberOfFans ?? 0) > 1 {
            if !perFanManualControl {
                perFanManualControl = true
                syncManualSpeedsFromUnified()
            }
            ensureManualSpeedsSize()
            if fan >= 0, fan < manualSpeeds.count {
                manualSpeeds[fan] = clampToFan(speed, index: fan)
            }
        } else {
            perFanManualControl = false
            manualSpeed = clampUnified(speed)
        }
        setMode(.manual)
    }

    func setMode(_ newMode: ControlMode) {
        // Taking fans that don't exist would only claim FanMac controls them.
        guard !hasNoFans else { return }
        mode = newMode

        if sleptSinceReapply {
            stopAutoControl()
            saveSettings()
            return
        }

        if newMode == .automatic {
            // Auto drives the fans itself, so they stay with FanMac; its first
            // reading sends a target even when the curve hasn't moved.
            autoSpeeds.reset()
            startAutoControl()
        } else {
            stopAutoControl()
            enableManualMode()
            ensureManualSpeedsSize()
            if !perFanManualControl {
                syncManualSpeedsFromUnified()
            }
            applyManualTargets()
        }

        saveSettings()
    }

    private func enableManualMode() {
        guard systemMonitor != nil else {
            statusMessage = "No system monitor available"
            return
        }
        isControlEnabled = true
        statusMessage = "Manual control enabled"
        print("Fan Control: Manual control enabled")
    }

    /// Hands the fans to macOS while the Mac sleeps, until `reapplySettings`
    /// after wake. Auto stops too: its next tick would otherwise take them
    /// back before the Mac slept, or during a dark wake. A display sleep or
    /// screen lock doesn't hand them back. See `sleptSinceReapply`.
    func handBackForSleep() {
        cancelWakeReapply()
        sleptSinceReapply = true
        stopAutoControl()
        // Nobody is there to answer a password prompt as the Mac sleeps.
        if isControlEnabled { restoreAutomaticControl(allowPrompt: false) }
    }

    func restoreAutomaticControl(allowPrompt: Bool = true) {
        // Quitting already handed the fans back, without a password prompt.
        guard !helperGate.isClosed else { return }
        guard let monitor = systemMonitor else { return }
        let n = monitor.numberOfFans
        guard n > 0 else { return }

        // Handing the fans back supersedes targets that haven't been written.
        pendingTargets = nil
        isHandingBack = true
        applyQueue.async { [weak self] in
            guard let self = self else { return }
            var failure: FanHelperFailure?
            for i in 0..<n {
                if let error = self.runHelper(["auto", "\(i)"], allowPrompt: allowPrompt), failure == nil {
                    failure = error
                }
            }
            DispatchQueue.main.async {
                self.isHandingBack = false
                if let failure {
                    self.lastFailure = FanControlFailure(operation: .restoreSystemControl, reason: failure)
                    self.statusMessage = "Failed to restore auto mode"
                    print("Fan Control: Failed to restore auto mode")
                } else {
                    self.isControlEnabled = false
                    // If Auto runs again (a retried hand-back while awake),
                    // its next tick sends rather than claim fans macOS holds.
                    self.autoSpeeds.reset()
                    self.appliedTargets = []
                    self.fansReadHeld = false
                    self.targetsReadBack = false
                    self.lastFailure = nil
                    self.statusMessage = "Automatic mode restored"
                    print("Fan Control: Automatic mode restored")
                }
            }
        }
    }

    private func applyManualTargets(onlyIfChanged: Bool = false) {
        guard let monitor = systemMonitor else {
            statusMessage = "No system monitor"
            lastWriteSuccess = false
            return
        }
        guard monitor.numberOfFans > 0 else {
            statusMessage = "No fans detected"
            lastWriteSuccess = false
            return
        }

        ensureManualSpeedsSize()
        var targets: [Int] = []
        for i in 0..<monitor.numberOfFans {
            let raw: Int
            if perFanManualControl, i < manualSpeeds.count {
                raw = manualSpeeds[i]
            } else {
                raw = manualSpeed
            }
            targets.append(clampToFan(raw, index: i))
        }
        applyFanTargets(targets, onlyIfChanged: onlyIfChanged)
    }

    /// `onlyIfChanged` skips targets FanMac has already queued, is writing
    /// or wrote. A retake leaves it off: it rewrites the same targets.
    private func applyFanTargets(_ targets: [Int], onlyIfChanged: Bool = false) {
        // FanMac is quitting and has handed the fans back.
        guard !helperGate.isClosed else { return }
        // Asleep, or handing the fans back for sleep: a write queued now
        // would take them again. The wake reapply sends the saved settings.
        guard !sleptSinceReapply else { return }
        if onlyIfChanged, targets == (pendingTargets ?? writingTargets ?? appliedTargets) { return }
        guard let monitor = systemMonitor else {
            statusMessage = "No system monitor"
            lastWriteSuccess = false
            return
        }
        guard monitor.numberOfFans > 0, targets.count == monitor.numberOfFans else {
            statusMessage = "Fan target mismatch"
            lastWriteSuccess = false
            return
        }

        pendingTargets = targets
        if !isWritingTargets {
            writeNextTargets()
        }
    }

    /// Writes the pending targets, then any that arrived meanwhile.
    private func writeNextTargets() {
        guard let targets = pendingTargets else {
            isWritingTargets = false
            return
        }
        pendingTargets = nil
        isWritingTargets = true
        writingTargets = targets
        armReleaseWatchdog(fanCount: targets.count)

        // Spawning the privileged helper blocks: sudo + waitUntilExit, and the
        // helper itself sleeps while taking manual control. Running that on the
        // main thread freezes the UI mid slider-drag. Serialize applies onto a
        // background queue and only touch @Published state back on main.
        applyQueue.async { [weak self] in
            guard let self = self else { return }
            var failure: FanHelperFailure?
            for (i, t) in targets.enumerated() {
                let safe = max(FanRPMBounds.absoluteWriteMinRPM, min(FanRPMBounds.absoluteWriteMaxRPM, t))
                if let error = self.runHelper(["set", "\(i)", "\(safe)"]), failure == nil {
                    failure = error
                }
                // The password prompt was cancelled or refused: the next fan
                // would only ask again.
                if failure == .notAuthorized { break }
            }
            let parts = targets.enumerated().map { "F\($0.offset): \($0.element)" }.joined(separator: ", ")
            DispatchQueue.main.async {
                self.writingTargets = nil
                if let failure {
                    self.lastFailure = FanControlFailure(operation: .setSpeed, reason: failure)
                    self.statusMessage = "Failed to set fan speed"
                    self.lastWriteSuccess = false
                    // Targets that arrived while the prompt was up would ask
                    // for the password again at once.
                    if failure == .notAuthorized { self.pendingTargets = nil }
                    // The fans kept the speed before this write, which can be
                    // far below what the heat calls for; Auto's next reading
                    // sends its target again rather than count it as sent.
                    self.autoSpeeds.reset()
                } else {
                    self.appliedTargets = targets
                    // A reading taken before the write still shows the old
                    // target; the next one that matches arms the check.
                    self.targetsReadBack = self.targetsMatch(self.systemMonitor?.fanTargets ?? [])
                    self.lastFailure = nil
                    self.statusMessage = "Fan targets RPM — \(parts)"
                    self.lastWriteSuccess = true
                    print("Fan Control: \(parts)")
                }
                self.writeNextTargets()
            }
        }
    }

    /// Takes the fans back when a fan FanMac holds reads as macOS's, once the
    /// fans have read as held (`fansReadHeld`), or when a fan's target is no
    /// longer FanMac's, once it has read back (`targetsReadBack`). Then it
    /// checks again every `retakeInterval` until they stay. It leaves them
    /// while FanMac writes or hands them back itself, and after a failure,
    /// which the popover offers to retry.
    private func retakeFansIfLost() {
        guard let monitor = systemMonitor else { return }
        let modeLost = fansReadHeld && monitor.fanModes.contains(where: { $0 != nil && $0 != 1 })
        let targetMoved = targetsReadBack && targetsDiffer(monitor.fanTargets)
        guard modeLost || targetMoved,
              isControlEnabled, !appliedTargets.isEmpty, lastFailure == nil,
              !isWritingTargets, pendingTargets == nil, !isHandingBack, !helperGate.isClosed
        else { return }
        if let lastRetake, Date().timeIntervalSince(lastRetake) < Self.retakeInterval {
            scheduleRetakeCheck(after: Self.retakeInterval - Date().timeIntervalSince(lastRetake))
            return
        }
        lastRetake = Date()
        print("Fan Control: fans FanMac had changed hands (modes \(monitor.fanModes), targets \(monitor.fanTargets)); taking them back")
        switch mode {
        case .automatic:
            autoSpeeds.reset()
            updateAutoControl()
        case .manual:
            applyManualTargets()
        }
        scheduleRetakeCheck(after: Self.retakeInterval)
    }

    /// Whether some readable SMC target isn't the one FanMac applied.
    private func targetsDiffer(_ read: [Int?]) -> Bool {
        zip(read, appliedTargets).contains { read, applied in
            read.map { abs($0 - applied) > Self.targetTolerance } ?? false
        }
    }

    /// Whether every readable SMC target is the one FanMac applied, and at
    /// least one can be read.
    private func targetsMatch(_ read: [Int?]) -> Bool {
        !appliedTargets.isEmpty && zip(read, appliedTargets).contains { $0.0 != nil } && !targetsDiffer(read)
    }

    private func scheduleRetakeCheck(after seconds: TimeInterval) {
        guard !retakeCheckScheduled else { return }
        retakeCheckScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.retakeCheckScheduled = false
            self.retakeFansIfLost()
        }
    }

    /// Starts the watchdog before FanMac first takes the fans. Tests inject a
    /// helper runner, so they never start one against the real helper.
    private func armReleaseWatchdog(fanCount: Int) {
        guard helperRunner == nil else { return }
        let helperPath = smcHelperPath
        guard FileManager.default.fileExists(atPath: helperPath) else { return }
        releaseWatchdog.arm(
            fanCount: fanCount,
            command: ["/usr/bin/sudo", "-n", helperPath],
            writePattern: "\(helperPath) set "
        )
    }

    /// Runs one helper command; returns nil on success, or why it failed.
    /// Once quitting closes the gate, speed writes are dropped and count as done.
    private func runHelper(_ args: [String], allowPrompt: Bool = true) -> FanHelperFailure? {
        guard helperGate.allows(args) else { return nil }
        if let helperRunner {
            return helperRunner(args, allowPrompt)
        }
        return runSmcHelper(args: args, allowPrompt: allowPrompt)
    }

    private func runSmcHelper(args: [String], allowPrompt: Bool) -> FanHelperFailure? {
        let helperPath = smcHelperPath

        // Runs on a background queue — do not touch @Published here. Callers map
        // the failure to a status message back on the main thread.
        if !FileManager.default.fileExists(atPath: helperPath) {
            print("Error: \(helperPath) not found")
            return .helperMissing
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", helperPath] + args
        task.environment = ["LANG": "C"]
        let stderrPipe = Pipe()
        task.standardError = stderrPipe

        do {
            guard try helperGate.start(task, args: args) else { return nil }
            defer { helperGate.finished(task) }
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                return nil
            }
            // Two failures exit non-zero: sudo refusing to run us (a privilege
            // problem the password prompt can fix) and the helper running AS ROOT
            // then failing — e.g. thermalmonitord transiently holding the fan in
            // SYSTEM mode right after wake, where unlockFanManual loses the reclaim
            // race. Re-running the latter under admin privileges hits the same SMC
            // failure and only pops a spurious password dialog. Only sudo's own
            // refusal warrants the AppleScript fallback, and sudo prefixes those
            // messages with "sudo:".
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            if !stderr.contains("sudo:") {
                print("Fan Control: helper ran as root and failed (exit \(task.terminationStatus)): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
                return .refused
            }
        } catch {
            print("Fan Control: sudo -n execution error: \(error)")
        }

        guard allowPrompt, !helperGate.isClosed else {
            print("Fan Control: sudo -n unauthorized; not asking for a password while quitting.")
            return .notAuthorized
        }
        print("Fan Control: sudo -n unauthorized. Falling back to AppleScript.")
        let fullCommand = ([helperPath] + args).map(PermissionsManager.shellQuoted).joined(separator: " ")
        let scriptSource = PermissionsManager.administratorScript(fullCommand)

        // NSAppleScript drives Apple Events and must run on the main thread; this
        // path is reached from applyQueue (off-main), so hop to main. Run inline
        // if a caller is ever already on main, since main.sync would deadlock.
        let runScript: () -> FanHelperFailure? = {
            var error: NSDictionary?
            guard let scriptObject = NSAppleScript(source: scriptSource) else { return .notAuthorized }
            _ = scriptObject.executeAndReturnError(&error)
            if let error {
                let errorMsg = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                print("Fan Control: AppleScript failed: \(errorMsg)")
                // -128 is the person cancelling the administrator prompt; any
                // other error means the helper ran with privileges and failed.
                let cancelled = (error["NSAppleScriptErrorNumber"] as? Int) == -128
                return cancelled ? .notAuthorized : .refused
            }
            return nil
        }
        return Thread.isMainThread ? runScript() : DispatchQueue.main.sync(execute: runScript)
    }

    func startAutoControl() {
        stopAutoControl()
        guard !helperGate.isClosed else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.helperGate.isClosed else { return }
            self.updateAutoControl()
            self.autoControlTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                // Without the helper's permission each new target would ask
                // for an administrator password. Auto waits for the person to
                // install the helper or try again from the popover instead.
                guard let self, self.lastFailure?.reason != .notAuthorized else { return }
                self.updateAutoControl()
            }
            RunLoop.current.add(self.autoControlTimer!, forMode: .common)
        }
    }

    func stopAutoControl() {
        autoControlTimer?.invalidate()
        autoControlTimer = nil
    }

    private func updateAutoControl(onlyIfChanged: Bool = false) {
        guard mode == .automatic, !sleptSinceReapply, let monitor = systemMonitor else { return }

        let currentTemp = max(
            monitor.cpuTemperature ?? 0,
            monitor.gpuTemperature ?? 0
        )

        guard monitor.numberOfFans > 0 else { return }
        guard currentTemp > 0 else {
            // Without a temperature Auto would hold its last speed whatever
            // the heat, so after three readings (6 s) the fans go back to
            // macOS. They come back to Auto once a temperature reads again.
            readingsWithoutTemperature += 1
            if readingsWithoutTemperature == 3, isControlEnabled {
                print("Fan Control: no CPU or GPU temperature; returning the fans to macOS")
                restoreAutomaticControl(allowPrompt: false)
            }
            return
        }
        readingsWithoutTemperature = 0

        let autoCeiling = min(autoMaxSpeed, unifiedMaxClamp)
        let unifiedTarget = FanCurve.target(
            temperature: currentTemp,
            threshold: autoThreshold,
            response: autoAggressiveness,
            floorRPM: unifiedMinClamp,
            ceilingRPM: autoCeiling
        )

        if !isControlEnabled {
            enableManualMode()
        }

        guard let speed = autoSpeeds.speed(for: unifiedTarget, floorRPM: unifiedMinClamp, ceilingRPM: autoCeiling) else {
            return
        }
        var targets: [Int] = []
        for i in 0..<monitor.numberOfFans {
            let mx = maxRPM(for: i)
            let mn = minRPM(for: i)
            let cap = min(mx, autoCeiling)
            targets.append(max(mn, min(speed, cap)))
        }
        applyFanTargets(targets, onlyIfChanged: onlyIfChanged)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let parts = targets.enumerated().map { "F\($0.offset): \($0.element)" }.joined(separator: ", ")
            self.statusMessage = "Auto — \(parts) (response \(String(format: "%.1f", self.autoAggressiveness)))"
        }
    }

    /// The settings' format. 1 is FanMac 1.0's; the previews saved none.
    static let settingsVersion = 1

    private func loadSettings() {
        let defaults = UserDefaults.standard

        if let savedMode = defaults.string(forKey: "fanControlMode") {
            mode = ControlMode(rawValue: savedMode) ?? .automatic
        }

        perFanManualControl = defaults.bool(forKey: "perFanManualControl")

        let savedManualSpeed = defaults.integer(forKey: "manualFanSpeed")
        if savedManualSpeed >= FanRPMBounds.absoluteWriteMinRPM && savedManualSpeed <= FanRPMBounds.absoluteWriteMaxRPM {
            manualSpeed = savedManualSpeed
        }

        if let savedPerFan = defaults.array(forKey: "manualFanSpeedsPerFan") as? [Int], !savedPerFan.isEmpty {
            manualSpeeds = savedPerFan
        }

        let savedThreshold = defaults.double(forKey: "autoThreshold")
        if savedThreshold >= 40 && savedThreshold <= 90 {
            autoThreshold = savedThreshold
        }

        let savedMaxSpeed = defaults.integer(forKey: "autoMaxSpeed")
        if savedMaxSpeed >= FanRPMBounds.absoluteWriteMinRPM && savedMaxSpeed <= FanRPMBounds.absoluteWriteMaxRPM {
            autoMaxSpeed = savedMaxSpeed
        }

        // The 0.x previews read a missing Response as 0, the quietest, which
        // holds the fans at their minimum at any temperature, and saved it
        // with any other change. A 0 saved before 1.0 is almost never a
        // choice, so it goes back to the default once. Settings from 1.0 on
        // carry settingsVersion, and a 0 chosen since then stays.
        if defaults.integer(forKey: "settingsVersion") < Self.settingsVersion {
            if defaults.object(forKey: "autoAggressiveness") as? Double == 0 {
                defaults.removeObject(forKey: "autoAggressiveness")
            }
            defaults.set(Self.settingsVersion, forKey: "settingsVersion")
        }

        // double(forKey:) would read a missing setting as 0.
        if let savedAggressiveness = defaults.object(forKey: "autoAggressiveness") as? Double,
           savedAggressiveness >= 0.0 && savedAggressiveness <= 3.0 {
            autoAggressiveness = savedAggressiveness
        }
    }

    /// Hands every fan back to macOS before FanMac quits, then calls
    /// `completion` once on the main thread: when the hand-back finishes,
    /// or after `timeout` if the helper hangs. FanMac changes no fan
    /// after this, so the hand-back is final.
    ///
    /// The completion arrives through the main run loop rather than the main
    /// dispatch queue. AppKit waits for `reply(toApplicationShouldTerminate:)`
    /// in the modal-panel run loop mode, and while a quit started inside a
    /// main-queue block is waiting, later main-queue blocks don't run.
    func handBackForQuit(timeout: TimeInterval = 5, completion: @escaping () -> Void) {
        stopAutoControl()
        pendingTargets = nil
        helperGate.close()

        let finish = OneShot(completion)
        let timer = Timer(timeInterval: timeout, repeats: false) { _ in
            MainActor.assumeIsolated {
                print("Fan Control: hand-back timed out; quitting anyway")
                finish.fire()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)

        let fanCount = systemMonitor?.numberOfFans ?? 0
        applyQueue.async { [weak self] in
            var handedBack = true
            for i in 0..<fanCount {
                if let error = self?.runHelper(["auto", "\(i)"], allowPrompt: false) {
                    print("Fan Control: couldn’t return fan \(i) to macOS at quit: \(error)")
                    handedBack = false
                }
            }
            // If a fan didn't come back, or the timeout lets FanMac exit
            // first, the watchdog tries again once FanMac is gone.
            if handedBack { self?.releaseWatchdog.disarm() }
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                MainActor.assumeIsolated {
                    timer.invalidate()
                    finish.fire()
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(mode.rawValue, forKey: "fanControlMode")
        defaults.set(perFanManualControl, forKey: "perFanManualControl")
        defaults.set(manualSpeed, forKey: "manualFanSpeed")
        defaults.set(manualSpeeds, forKey: "manualFanSpeedsPerFan")
        defaults.set(autoThreshold, forKey: "autoThreshold")
        defaults.set(autoMaxSpeed, forKey: "autoMaxSpeed")
        defaults.set(autoAggressiveness, forKey: "autoAggressiveness")
    }

    func setAutoThreshold(_ threshold: Double) {
        autoThreshold = max(40, min(90, threshold))
        saveSettings()
        if mode == .automatic {
            autoSpeeds.reset()
            updateAutoControl()
        }
    }

    func setAutoMaxSpeed(_ speed: Int) {
        autoMaxSpeed = clampUnified(speed)
        saveSettings()
        if mode == .automatic {
            autoSpeeds.reset()
            updateAutoControl()
        }
    }

    func setAutoAggressiveness(_ value: Double) {
        autoAggressiveness = max(0.0, min(3.0, value))
        saveSettings()
        if mode == .automatic {
            autoSpeeds.reset()
            updateAutoControl()
        }
    }
}
