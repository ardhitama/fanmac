//
//  BatteryMonitor.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Battery and power information using IOKit
//

import Foundation
import IOKit.ps
import Combine

/// Whether the Mac reports a battery or is a desktop-style power profile.
enum DevicePowerProfile: String, Equatable {
    case battery
    case desktop
}

struct BatteryInfo {
    var percentage: Int = 0
    var isCharging: Bool = false
    var isPluggedIn: Bool = false
    var cycleCount: Int = 0
    var health: Int = 100  // Maximum capacity %
    var condition: String = "Normal"
    var temperature: Double? = nil  // in Celsius
    var voltage: Double? = nil  // in Volts
    var amperage: Int? = nil  // in mA (negative = discharging)
    var timeRemaining: Int? = nil  // minutes
    var designCapacity: Int? = nil  // mAh
    var maxCapacity: Int? = nil  // mAh (actual current max)
    var currentCapacity: Int? = nil  // mAh
    var fullyCharged: Bool = false
    var systemLoadWatts: Double? = nil  // whole Mac, from the battery's power telemetry
    var adapterWatts: Int? = nil  // the connected adapter's rating

    var healthDescription: String {
        if health >= 80 {
            return "Good"
        } else if health >= 60 {
            return "Fair"
        } else {
            return "Poor"
        }
    }
    
    var formattedTimeRemaining: String? {
        guard let time = timeRemaining, time > 0 else { return nil }
        let hours = time / 60
        let minutes = time % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
    
    // Power in Watts (calculated from voltage and amperage)
    var powerWatts: Double? {
        guard let voltage = voltage, let amp = amperage else { return nil }
        // voltage is in V, amperage in mA
        // Power = V * A = V * (mA/1000)
        return abs(voltage * Double(amp) / 1000.0)
    }

    /// What the whole Mac draws. The battery's own power is zero while the
    /// adapter carries the load, so it stands in only where the battery reports
    /// no telemetry, as on Intel Macs.
    var systemPowerWatts: Double? {
        if let systemLoadWatts, systemLoadWatts > 0 { return systemLoadWatts }
        if let powerWatts, powerWatts > 0.01 { return powerWatts }
        return nil
    }

    /// `SystemLoad` from the battery's `PowerTelemetryData`, in mW: the whole
    /// Mac's draw, from the adapter or the battery.
    static func systemLoadWatts(telemetry: [String: Any]?) -> Double? {
        guard let load = telemetry?["SystemLoad"] as? Int, load > 0 else { return nil }
        return Double(load) / 1000
    }
}

class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()
    
    @Published var batteryInfo = BatteryInfo()
    @Published var hasBattery = false

    /// Derived profile for adaptive UI (popover widgets, status bar fallbacks).
    var devicePowerProfile: DevicePowerProfile {
        hasBattery ? .battery : .desktop
    }
    
    private var timer: Timer?
    
    init() {
        updateBatteryInfo()
    }
    
    func startMonitoring() {
        timer?.invalidate()
        updateBatteryInfo()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.updateBatteryInfo()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    /// Reads the battery and publishes it at once: the popover builds its
    /// dashboard in the same run loop turn that first creates this monitor, and
    /// a late `hasBattery` gave a new laptop the desktop's default layout.
    func updateBatteryInfo() {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        let descriptions = sources.compactMap {
            IOPSGetPowerSourceDescription(snapshot, $0 as CFTypeRef).takeUnretainedValue() as? [String: Any]
        }
        guard let info = Self.internalBattery(in: descriptions) else {
            hasBattery = false
            return
        }

        var newInfo = BatteryInfo()

        // Basic info from IOPowerSources
        if let capacity = info[kIOPSCurrentCapacityKey] as? Int {
            newInfo.percentage = capacity
        }

        if let isCharging = info[kIOPSIsChargingKey] as? Bool {
            newInfo.isCharging = isCharging
        }

        if let powerSource = info[kIOPSPowerSourceStateKey] as? String {
            newInfo.isPluggedIn = (powerSource == kIOPSACPowerValue)
        }

        if let fullyCharged = info[kIOPSIsChargedKey] as? Bool {
            newInfo.fullyCharged = fullyCharged
        }

        if let timeToEmpty = info[kIOPSTimeToEmptyKey] as? Int, timeToEmpty > 0 {
            newInfo.timeRemaining = timeToEmpty
        } else if let timeToFull = info[kIOPSTimeToFullChargeKey] as? Int, timeToFull > 0 {
            newInfo.timeRemaining = timeToFull
        }

        // Get detailed info from IORegistry
        getDetailedBatteryInfo(&newInfo)

        batteryInfo = newInfo
        hasBattery = true
    }

    /// The Mac's own battery among its power sources. A UPS plugged into a
    /// desktop Mac is a power source too, but not a battery FanMac can read.
    static func internalBattery(in sources: [[String: Any]]) -> [String: Any]? {
        sources.first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
    }

    private func getDetailedBatteryInfo(_ info: inout BatteryInfo) {
        // Access AppleSmartBattery for detailed info
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        
        // Cycle Count
        if let cycleCount = getIORegistryProperty(service: service, key: "CycleCount") as? Int {
            info.cycleCount = cycleCount
        }
        
        // Design Capacity (original capacity in mAh)
        if let designCap = getIORegistryProperty(service: service, key: "DesignCapacity") as? Int {
            info.designCapacity = designCap
        }
        
        // NominalChargeCapacity is what Apple uses for "Maximum Capacity" percentage
        // This matches the value shown in System Information
        if let nominalCap = getIORegistryProperty(service: service, key: "NominalChargeCapacity") as? Int {
            info.maxCapacity = nominalCap
            // Calculate health: this matches Apple's "Maximum Capacity" in System Info
            if let designCap = info.designCapacity, designCap > 0 {
                info.health = (nominalCap * 100) / designCap
            }
        } else if let rawMaxCap = getIORegistryProperty(service: service, key: "AppleRawMaxCapacity") as? Int {
            // Fallback to AppleRawMaxCapacity if NominalChargeCapacity not available
            info.maxCapacity = rawMaxCap
            if let designCap = info.designCapacity, designCap > 0 {
                info.health = (rawMaxCap * 100) / designCap
            }
        }
        
        // Current capacity in mAh
        if let rawCurrentCap = getIORegistryProperty(service: service, key: "AppleRawCurrentCapacity") as? Int {
            info.currentCapacity = rawCurrentCap
        }
        
        // Temperature (in 0.1 Kelvin units, e.g., 3060 = 306.0K = 32.85°C)
        if let temp = getIORegistryProperty(service: service, key: "Temperature") as? Int {
            // Temperature is in deciKelvin (0.1K units)
            // Convert: (temp / 10) - 273.15 = Celsius
            info.temperature = (Double(temp) / 10.0) - 273.15
        }
        
        // Voltage in mV, convert to V
        if let voltage = getIORegistryProperty(service: service, key: "Voltage") as? Int {
            info.voltage = Double(voltage) / 1000.0  // Convert mV to V
        }
        
        // Amperage - stored as unsigned 64-bit representing negative values when discharging
        // Try multiple casting approaches since IORegistry can return different types
        let amperageValue = getIORegistryProperty(service: service, key: "InstantAmperage") 
            ?? getIORegistryProperty(service: service, key: "Amperage")
        
        if let amperage = amperageValue {
            // Try to get the raw value and convert to signed
            if let uint64Val = amperage as? UInt64 {
                info.amperage = Int(Int64(bitPattern: uint64Val))
            } else if let int64Val = amperage as? Int64 {
                info.amperage = Int(int64Val)
            } else if let nsNumber = amperage as? NSNumber {
                // NSNumber fallback - get the int64 value
                let val = nsNumber.int64Value
                info.amperage = Int(val)
            }
        }
        
        info.systemLoadWatts = BatteryInfo.systemLoadWatts(
            telemetry: getIORegistryProperty(service: service, key: "PowerTelemetryData") as? [String: Any]
        )
        if info.isPluggedIn,
           let adapter = getIORegistryProperty(service: service, key: "AdapterDetails") as? [String: Any],
           let watts = adapter["Watts"] as? Int, watts > 0 {
            info.adapterWatts = watts
        }

        // Battery Condition - matches Apple's System Information criteria
        // "Service Recommended" when Maximum Capacity drops to 80% or below
        if let condition = getIORegistryProperty(service: service, key: "BatteryInstalled") as? Bool, !condition {
            info.condition = "Not Installed"
        } else if let permanentFailure = getIORegistryProperty(service: service, key: "PermanentFailureStatus") as? Int, permanentFailure != 0 {
            info.condition = "Service Battery"
        } else if info.health <= 80 {
            info.condition = "Service Recommended"
        } else {
            info.condition = "Normal"
        }
    }
    
    private func getIORegistryProperty(service: io_service_t, key: String) -> Any? {
        let cfKey = key as CFString
        guard let value = IORegistryEntryCreateCFProperty(service, cfKey, kCFAllocatorDefault, 0) else {
            return nil
        }
        return value.takeRetainedValue()
    }
    
    deinit {
        stopMonitoring()
    }
}
