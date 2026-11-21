//
//  SystemMonitor.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Reads temperatures, fan speeds and fan limits from the SMC, without
//  privileges. Writes go through the root helper (FanController).
//

import Foundation
import Combine
import IOKit

// MARK: - SMC Types (Compatible with actual Apple SMC)

private typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

// SMC key as 4-character code (FourCharCode)
private func fourCharCodeFrom(_ string: String) -> UInt32 {
    var result: UInt32 = 0
    for (index, char) in string.utf8.prefix(4).enumerated() {
        result |= UInt32(char) << (8 * (3 - index))
    }
    return result
}

// SMC Version structure
private struct SMCKeyData_vers_t {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

// SMC Limit Data
private struct SMCKeyData_pLimitData_t {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

// SMC Key Info structure
private struct SMCKeyData_keyInfo_t {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

// Main SMC structure - must match kernel's SMCParamStruct exactly
private struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCKeyData_vers_t()
    var pLimitData = SMCKeyData_pLimitData_t()
    var keyInfo = SMCKeyData_keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

// SMC selector (kSMCUserClientOpen = 0, kSMCHandleYPCEvent = 2, etc.)
private let KERNEL_INDEX_SMC: UInt32 = 2

// SMC commands
private let SMC_CMD_READ_BYTES: UInt8 = 5
private let SMC_CMD_READ_KEYINFO: UInt8 = 9

// MARK: - System Monitor Class

class SystemMonitor: ObservableObject {
    @Published var cpuTemperature: Double?
    @Published var gpuTemperature: Double?
    @Published var fanSpeeds: [Int] = []
    @Published var fanMinSpeeds: [Int] = []
    @Published var fanMaxSpeeds: [Int] = []
    /// Each fan's SMC mode: 1 while FanMac holds it, 0 or 3 while macOS
    /// does; nil where the Mac has no mode key.
    @Published var fanModes: [Int?] = []
    /// Each fan's SMC target speed (F%dTg) in RPM; nil where it can't be read.
    @Published var fanTargets: [Int?] = []
    @Published var numberOfFans: Int = 0
    /// The SMC answers and reports no fans, as on a MacBook Air. While the
    /// fans can't be read, this stays false and detection tries again; if
    /// fans turn up later, it goes back to false.
    @Published var hasNoFans = false
    @Published var isMonitoring = false
    @Published var hasAccess = false
    @Published var lastError: String?
    
    private var smcConnection: io_connect_t = 0
    private var monitoringTimer: Timer?
    private var fanDetectionRetry: DispatchWorkItem?
    /// Seconds between sensor reads; the Settings refresh slider stores it.
    static let monitoringIntervalRange: ClosedRange<TimeInterval> = 0.5...5.0
    static let defaultMonitoringInterval: TimeInterval = 2.0
    static let monitoringIntervalKey = "monitoringInterval"
    private var monitoringInterval: TimeInterval {
        let saved = UserDefaults.standard.double(forKey: Self.monitoringIntervalKey)
        guard saved > 0 else { return Self.defaultMonitoringInterval }
        return min(Self.monitoringIntervalRange.upperBound, max(Self.monitoringIntervalRange.lowerBound, saved))
    }
    private var keyInfoCache: [UInt32: SMCKeyData_keyInfo_t] = [:]
    /// Serializes all SMC reads and the state they mutate (`keyInfoCache`,
    /// `lastGPUTemp`). Running detectFans() on the caller's thread while
    /// updateReadings() filled the cache on a global queue raced on the
    /// Dictionary and crashed the app at launch.
    private let smcQueue = DispatchQueue(label: "com.fanmac.smc-read", qos: .userInitiated)
    
    // Intel CPU/GPU proximity keys (legacy Macs).
    private let cpuTempKeysIntel = ["TC0P", "TCXC", "TC0E", "TC0F", "TC0D", "TC1C", "TC2C", "TC3C", "TC4C"]
    private let gpuTempKeysIntel = ["TGDD", "TG0P", "TG0D", "TG0E", "TG0F"]

    // Apple Silicon die sensors: P/E-core clusters (Tp**/Te**) for CPU, Tg** for
    // GPU. The exact suffixes vary by chip (M1-M4), so we probe a generous set;
    // missing keys are simply skipped. Per-core sensors report ~1-2°C when their
    // core is gated/idle, so callers take the hottest plausible reading, never
    // the first that parses (which a gated 2°C core would win).
    private let cpuTempKeysAS = [
        "Te05", "Te0L", "Te0P", "Te0S",
        "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0T", "Tp0X",
        "Tp0b", "Tp0f", "Tp0j", "Tp0n", "Tp0r", "Tp0v", "Tp0z",
        "Tp19", "Tp1d", "Tp1f", "Tp1h", "Tp1n", "Tp1p", "Tp1t", "Tp1v",
    ]
    private let gpuTempKeysAS = ["Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0V", "Tg0f", "Tg0j", "Tg1f", "Tg1j"]

    // GPU die sensors power-gate when the GPU goes idle: every Tg** key stops
    // reading at once, so a naive aggregate snaps to nil and the UI flickers
    // between a number and "--". Hold the last good value for a short window to
    // ride over those gaps; after it, report nil honestly (GPU genuinely idle).
    private var lastGPUTemp: Double?
    private var lastGPUTempAt = Date.distantPast
    private let gpuTempHoldWindow: TimeInterval = 8.0
    /// The fan mode key: F%dMd, or F%dmd on M5. Read on `smcQueue`.
    private var fanModeKeyFormat: String?
    /// The last value each fan key read, by key. Read on `smcQueue`.
    private var lastGoodFanValues: [String: Int] = [:]

    init() {
        // Try to connect on init
        _ = openSMCConnection()
    }
    
    deinit {
        stopMonitoring()
        closeSMCConnection()
    }
    
    // MARK: - SMC Connection Management
    
    private func openSMCConnection() -> Bool {
        if smcConnection != 0 {
            hasAccess = true
            return true
        }
        
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            lastError = "AppleSMC service not found"
            hasAccess = false
            return false
        }
        
        defer { IOObjectRelease(service) }
        
        let result = IOServiceOpen(service, mach_task_self_, 0, &smcConnection)
        
        if result == kIOReturnSuccess {
            hasAccess = true
            lastError = nil
            return true
        } else {
            let errorString = describeIOReturn(result)
            lastError = "Failed to open SMC connection: \(errorString)"
            hasAccess = false
            return false
        }
    }
    
    private func closeSMCConnection() {
        if smcConnection != 0 {
            IOServiceClose(smcConnection)
            smcConnection = 0
        }
    }
    
    private func describeIOReturn(_ result: IOReturn) -> String {
        switch Int32(bitPattern: UInt32(result)) {
        case kIOReturnSuccess: return "Success"
        case kIOReturnError: return "General error"
        case kIOReturnNoMemory: return "No memory"
        case kIOReturnNoResources: return "No resources"
        case kIOReturnBadArgument: return "Bad argument"
        case kIOReturnNotPrivileged: return "Not privileged (needs root)"
        case kIOReturnNotOpen: return "Not open"
        case kIOReturnNotFound: return "Not found"
        case kIOReturnNotReadable: return "Not readable"
        case kIOReturnNotWritable: return "Not writable"
        default: return "Error code: \(result)"
        }
    }
    
    // MARK: - Monitoring Control
    
    func startMonitoring() {
        guard openSMCConnection() else {
            print("SMC: Cannot start monitoring - no connection")
            return
        }
        
        stopMonitoring()
        isMonitoring = true

        // Counts the fans, then takes the first reading. A reading covers only
        // the fans already counted, so one taken before the count would carry
        // no fan speeds or limits, and FanMac couldn't take the fans until the
        // timer's first tick.
        detectFans()

        // Start periodic timer
        DispatchQueue.main.async { [weak self] in
            self?.scheduleTimer()
        }
    }

    private func scheduleTimer() {
        monitoringTimer?.invalidate()
        monitoringTimer = Timer.scheduledTimer(withTimeInterval: monitoringInterval, repeats: true) { [weak self] _ in
            self?.updateReadings()
        }
        RunLoop.current.add(monitoringTimer!, forMode: .common)
    }

    /// Saves the refresh interval and, while monitoring, reschedules reads at it.
    func setMonitoringInterval(_ seconds: TimeInterval) {
        UserDefaults.standard.set(seconds, forKey: Self.monitoringIntervalKey)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isMonitoring else { return }
            self.scheduleTimer()
        }
    }
    
    func stopMonitoring() {
        monitoringTimer?.invalidate()
        monitoringTimer = nil
        fanDetectionRetry?.cancel()
        fanDetectionRetry = nil
        isMonitoring = false
    }
    
    // MARK: - Fan Detection
    
    private func detectFans() {
        smcQueue.async { [weak self] in
            guard let self = self else { return }
            var count = 0
            for i in 0..<8 {
                let key = String(format: "F%dAc", i)
                if let _ = self.readSMCValue(key: key) {
                    count += 1
                } else {
                    break
                }
            }
            // The SMC's own count tells a Mac without fans from a failed read,
            // and catches a speed that failed to read and ended the count early.
            let reportedFans = self.readSMCValue(key: "FNum")
            let smcAnswers = count > 0 || self.readSMCValue(key: "#KEY") != nil

            DispatchQueue.main.async {
                self.applyFanDetection(
                    Self.fanDetection(countedFans: count, reportedFans: reportedFans, smcAnswers: smcAnswers)
                )
                self.updateReadings()
            }
        }
    }

    /// Detection runs until it finds fans: soon after a failed read, and now
    /// and then on a Mac without fans, since a failed read can pass for one.
    func applyFanDetection(_ detection: FanDetection) {
        switch detection {
        case .fans(let n):
            numberOfFans = n
            hasNoFans = false
            print("SMC: Detected \(n) fan(s)")
        case .none:
            numberOfFans = 0
            if !hasNoFans { print("SMC: This Mac has no fans") }
            hasNoFans = true
            scheduleFanDetectionRetry(after: 30)
        case .unknown:
            print("SMC: Couldn't read the fans; trying again in 2 seconds")
            scheduleFanDetectionRetry(after: 2)
        }
    }

    private func scheduleFanDetectionRetry(after seconds: TimeInterval) {
        fanDetectionRetry?.cancel()
        let retry = DispatchWorkItem { [weak self] in
            guard let self, self.isMonitoring else { return }
            self.detectFans()
        }
        fanDetectionRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: retry)
    }

    enum FanDetection: Equatable {
        case fans(Int)
        /// The Mac has no fans.
        case none
        /// A read failed; try again.
        case unknown
    }

    /// Fans are counted by their speed keys. None counted means a Mac without
    /// fans only when the SMC answers and doesn't report fans either.
    static func fanDetection(countedFans: Int, reportedFans: Double?, smcAnswers: Bool) -> FanDetection {
        if countedFans > 0 {
            // A fan past the first one whose speed didn't read stopped the
            // count; the helper takes fan numbers up to FNum, so trust it.
            if let reported = reportedFans, reported.isFinite, Int(exactly: reported).map({ $0 > countedFans && $0 <= 8 }) == true {
                return .fans(Int(reported))
            }
            return .fans(countedFans)
        }
        guard smcAnswers, (reportedFans ?? 0) == 0 else { return .unknown }
        return .none
    }
    
    // MARK: - Reading Updates
    
    private func updateReadings() {
        smcQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Read temperatures — hottest plausible die sensor, Apple Silicon
            // first then Intel proximity as fallback. Hottest (not first) so a
            // gated ~2°C core never wins over the real cluster temperature.
            var cpuTemp = self.hottestTemperature(self.cpuTempKeysAS)
            if cpuTemp == nil { cpuTemp = self.hottestTemperature(self.cpuTempKeysIntel) }

            var gpuTemp = self.hottestTemperature(self.gpuTempKeysAS)
            if gpuTemp == nil { gpuTemp = self.hottestTemperature(self.gpuTempKeysIntel) }

            // Smooth over brief GPU power-gating so the readout doesn't flicker.
            if let g = gpuTemp {
                self.lastGPUTemp = g
                self.lastGPUTempAt = Date()
            } else if Date().timeIntervalSince(self.lastGPUTempAt) < self.gpuTempHoldWindow {
                gpuTemp = self.lastGPUTemp
            }
            
            // Read fan data
            var speeds: [Int] = []
            var minSpeeds: [Int] = []
            var maxSpeeds: [Int] = []
            var modes: [Int?] = []
            var targets: [Int?] = []
            
            for i in 0..<self.numberOfFans {
                modes.append(self.readFanMode(i))
                targets.append(self.readSMCFanSpeed(key: String(format: "F%dTg", i)))
                // F%dAc = Actual speed, F%dMn = Minimum, F%dMx = Maximum
                let actualKey = String(format: "F%dAc", i)
                let minKey = String(format: "F%dMn", i)
                let maxKey = String(format: "F%dMx", i)
                
                // A placeholder keeps each fan's speed in its own place.
                speeds.append(self.readFanValueHoldingLast(key: actualKey) ?? 0)
                if let min = self.readFanValueHoldingLast(key: minKey) {
                    minSpeeds.append(min)
                } else {
                    minSpeeds.append(FanRPMBounds.fallbackMinWhenSMCUnreadable)
                }
                if let max = self.readFanValueHoldingLast(key: maxKey) {
                    maxSpeeds.append(max)
                } else {
                    // Placeholder: resolved below using peer fans or `FanRPMBounds`.
                    maxSpeeds.append(-1)
                }
            }

            /// If some `F%dMx` reads failed, reuse the highest successfully read maximum before falling back.
            let positiveMaxima = maxSpeeds.filter { $0 > 0 }
            let peerMax = positiveMaxima.max()
            for i in maxSpeeds.indices where maxSpeeds[i] <= 0 {
                maxSpeeds[i] = peerMax ?? FanRPMBounds.fallbackMaxWhenSMCUnreadable
            }
            
            // Update on main thread (assign only on change to limit publisher churn and downstream SMC writes).
            DispatchQueue.main.async {
                if self.cpuTemperature != cpuTemp { self.cpuTemperature = cpuTemp }
                if self.gpuTemperature != gpuTemp { self.gpuTemperature = gpuTemp }
                if self.fanSpeeds != speeds { self.fanSpeeds = speeds }
                if self.fanMinSpeeds != minSpeeds { self.fanMinSpeeds = minSpeeds }
                if self.fanMaxSpeeds != maxSpeeds { self.fanMaxSpeeds = maxSpeeds }
                if self.fanModes != modes { self.fanModes = modes }
                if self.fanTargets != targets { self.fanTargets = targets }

                if self.numberOfFans == 0 && !speeds.isEmpty {
                    self.numberOfFans = speeds.count
                }
            }
        }
    }
    
    // MARK: - SMC Data Parsing
    
    // Type codes
    private let DATA_TYPE_FLT = fourCharCodeFrom("flt ")
    private let DATA_TYPE_SP78 = fourCharCodeFrom("sp78")
    private let DATA_TYPE_FPE2 = fourCharCodeFrom("fpe2")
    private let DATA_TYPE_UINT8 = fourCharCodeFrom("ui8 ")
    private let DATA_TYPE_UINT16 = fourCharCodeFrom("ui16")
    private let DATA_TYPE_UINT32 = fourCharCodeFrom("ui32")
    private let DATA_TYPE_SINT16 = fourCharCodeFrom("si16")
    
    private func parseSMCBytes(_ bytes: SMCBytes, dataType: UInt32, dataSize: UInt32) -> Double? {
        // Helper to get bytes as array
        let byteArray = [
            bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15,
            bytes.16, bytes.17, bytes.18, bytes.19, bytes.20, bytes.21, bytes.22, bytes.23,
            bytes.24, bytes.25, bytes.26, bytes.27, bytes.28, bytes.29, bytes.30, bytes.31
        ]
        
        switch dataType {
        case DATA_TYPE_FLT:
            if dataSize == 4 {
                let val = byteArray.withUnsafeBufferPointer {
                    $0.baseAddress!.withMemoryRebound(to: Float32.self, capacity: 1) { $0.pointee }
                }
                return Double(val)
            }
            
        case DATA_TYPE_SP78:
            if dataSize == 2 {
                // Fixed Point 7.8 (Signed)
                // First bit is sign, next 7 are integer part, last 8 are fractional
                let b0 = Int(byteArray[0])
                let b1 = Int(byteArray[1])
                let val = (b0 << 8) | b1
                return Double(Int16(bitPattern: UInt16(val))) / 256.0
            }
            
        case DATA_TYPE_FPE2:
            if dataSize == 2 {
                // Fixed Point 14.2 (Unsigned)
                // First 14 bits are integer part, last 2 are fractional
                // Calculation: (Byte0 << 6) + (Byte1 >> 2)
                let b0 = Int(byteArray[0])
                let b1 = Int(byteArray[1])
                let val = (b0 << 6) + (b1 >> 2)
                return Double(val)
            }
            
        case DATA_TYPE_UINT8:
            if dataSize == 1 {
                return Double(byteArray[0])
            }
            
        case DATA_TYPE_UINT16:
            if dataSize == 2 {
                let val = (Int(byteArray[0]) << 8) + Int(byteArray[1])
                return Double(val)
            }
            
        case DATA_TYPE_UINT32:
            if dataSize == 4 {
                let val = (UInt32(byteArray[0]) << 24) | (UInt32(byteArray[1]) << 16) | (UInt32(byteArray[2]) << 8) | UInt32(byteArray[3])
                return Double(val)
            }
        
        case DATA_TYPE_SINT16:
            if dataSize == 2 {
                let val = (UInt16(byteArray[0]) << 8) | UInt16(byteArray[1])
                return Double(Int16(bitPattern: val))
            }
            
        default:
            // Check for potential fallback or unknown type
            if dataSize == 2 {
                let val = (Int(byteArray[0]) << 8) + Int(byteArray[1])
                return Double(val)
            }
        }
        
        return nil
    }
    
    // MARK: - SMC Read Operations
    
    // Generic read that handles types automatically
    func readSMCValue(key: String) -> Double? {
        guard smcConnection != 0 else { return nil }
        
        let keyCode = fourCharCodeFrom(key)
        
        // 1. Get Key Info
        var keyInfo: SMCKeyData_keyInfo_t
        if let cached = keyInfoCache[keyCode] {
            keyInfo = cached
        } else {
            var input = SMCParamStruct()
            input.key = keyCode
            input.data8 = SMC_CMD_READ_KEYINFO
            
            var output = SMCParamStruct()
            let inputSize = MemoryLayout<SMCParamStruct>.size
            var outputSize = MemoryLayout<SMCParamStruct>.size
            
            let result = IOConnectCallStructMethod(
                smcConnection,
                KERNEL_INDEX_SMC,
                &input,
                inputSize,
                &output,
                &outputSize
            )
            
            if result != kIOReturnSuccess || output.result != 0 {
                return nil
            }
            
            keyInfo = output.keyInfo
            // Validate keyInfo.dataSize
            if keyInfo.dataSize == 0 || keyInfo.dataSize > 32 {
                print("SMC: Invalid keyInfo.dataSize (\(keyInfo.dataSize)) for key \(key)")
                return nil
            }
            keyInfoCache[keyCode] = keyInfo
        }
        
        // 2. Read Data
        var input = SMCParamStruct()
        input.key = keyCode
        input.keyInfo = keyInfo
        input.data8 = SMC_CMD_READ_BYTES
        
        var output = SMCParamStruct()
        let inputSize = MemoryLayout<SMCParamStruct>.size
        var outputSize = MemoryLayout<SMCParamStruct>.size
        
        let result = IOConnectCallStructMethod(
            smcConnection,
            KERNEL_INDEX_SMC,
            &input,
            inputSize,
            &output,
            &outputSize
        )
        
        if result != kIOReturnSuccess || output.result != 0 {
            return nil
        }
        
        // Validate data size before parsing
        if keyInfo.dataSize == 0 || keyInfo.dataSize > 32 {
            print("SMC: Invalid read size \(keyInfo.dataSize) for key \(key)")
            return nil
        }
        
        // 3. Parse Data
        return parseSMCBytes(output.bytes, dataType: keyInfo.dataType, dataSize: keyInfo.dataSize)
    }

    private func readSMCTemperature(key: String) -> Double? {
        return readSMCValue(key: key)
    }

    /// Hottest plausible sensor across a candidate list. Apple Silicon exposes
    /// many per-core die sensors; gated cores report ~1-2°C, so the `floor`
    /// filters that garbage and we keep the maximum — the hottest active
    /// core/cluster — rather than the first key that happens to parse.
    private func hottestTemperature(_ keys: [String], floor: Double = 10, ceiling: Double = 130) -> Double? {
        var hottest: Double? = nil
        for key in keys {
            if let t = readSMCTemperature(key: key), t > floor, t < ceiling {
                hottest = max(hottest ?? t, t)
            }
        }
        return hottest
    }
    
    private func readFanMode(_ fan: Int) -> Int? {
        if let format = fanModeKeyFormat {
            return readSMCInteger(key: String(format: format, fan))
        }
        for format in ["F%dMd", "F%dmd"] {
            if let mode = readSMCInteger(key: String(format: format, fan)) {
                fanModeKeyFormat = format
                return mode
            }
        }
        return nil
    }

    private func readSMCFanSpeed(key: String) -> Int? {
        readSMCInteger(key: key)
    }

    /// A fan limit (`F%dMn`, `F%dMx`) or speed (`F%dAc`), or the last good
    /// reading of that key when this read fails. One failed read would
    /// otherwise put a fallback limit in its place, which moves Auto's
    /// curve and clamps saved speeds, or shift the next fan's speed into
    /// this fan's place.
    private func readFanValueHoldingLast(key: String) -> Int? {
        if let value = readSMCInteger(key: key) {
            lastGoodFanValues[key] = value
            return value
        }
        return lastGoodFanValues[key]
    }

    /// The SMC value as a whole number, or nil when it doesn't read or isn't
    /// a plausible fan value. Int() of a NaN or huge float would crash.
    private func readSMCInteger(key: String) -> Int? {
        guard let value = readSMCValue(key: key), value.isFinite, value >= 0, value < 100_000 else { return nil }
        return Int(value)
    }
}
