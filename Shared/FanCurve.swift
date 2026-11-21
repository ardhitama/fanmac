//
//  FanCurve.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  The Auto mode fan curve, kept free of SMC state so it can be tested.
//

import Foundation

nonisolated enum FanCurve {
    /// The curve reaches its ceiling at this temperature (°C).
    static let fullSpeedTemperature = 90.0
    /// Response 1.5 follows the curve. Lower values blend toward the floor and
    /// higher ones toward the ceiling; 0 and 3 pin the speed there.
    static let neutralResponse = 1.5
    static let responseRange: ClosedRange<Double> = 0...3

    /// Target RPM for `temperature`: `floorRPM` up to `threshold`, then a linear
    /// ramp to `ceilingRPM` at `fullSpeedTemperature`, blended by `response`.
    static func target(
        temperature: Double,
        threshold: Double,
        response: Double,
        floorRPM: Int,
        ceilingRPM: Int
    ) -> Int {
        let floor = Double(floorRPM)
        let ceiling = Double(max(floorRPM, ceilingRPM))

        let ratio: Double
        if temperature >= fullSpeedTemperature {
            ratio = 1
        } else if temperature <= threshold {
            ratio = 0
        } else {
            ratio = (temperature - threshold) / (fullSpeedTemperature - threshold)
        }
        let curve = floor + (ceiling - floor) * ratio

        let target: Double
        if response <= neutralResponse {
            let blend = max(0, response) / neutralResponse
            target = floor * (1 - blend) + curve * blend
        } else {
            let blend = min(1, (response - neutralResponse) / (responseRange.upperBound - neutralResponse))
            target = curve * (1 - blend) + ceiling * blend
        }
        return Int(max(floor, min(target, ceiling)))
    }

    /// Where the curve sits at `temperature`, from `floorRPM` (0) to `topRPM`
    /// (1), as the popover's and `fanmac watch`'s graphs draw it.
    static func level(
        temperature: Double,
        threshold: Double,
        response: Double,
        floorRPM: Int,
        ceilingRPM: Int,
        topRPM: Int
    ) -> Double {
        let rpm = target(
            temperature: temperature,
            threshold: threshold,
            response: response,
            floorRPM: floorRPM,
            ceilingRPM: ceilingRPM
        )
        let span = Double(max(1, topRPM - floorRPM))
        return min(1, max(0, Double(rpm - floorRPM) / span))
    }

    /// Name for a `response` value, as the popover and `fanmac` show it.
    static func responseLabel(_ response: Double) -> String {
        if response <= 0.3 { return "Minimum" }
        if response <= 0.8 { return "Quiet" }
        if response <= 1.2 { return "Gentle" }
        if response <= 1.8 { return "Standard" }
        if response <= 2.3 { return "Brisk" }
        if response <= 2.7 { return "Aggressive" }
        return "Maximum"
    }

    /// What the three Auto settings add up to, in one or two sentences, with
    /// the speeds `target` gives: a quieter response never reaches `ceilingRPM`,
    /// and a faster one runs the fans above `floorRPM` even when cool.
    static func summary(threshold: Double, response: Double, floorRPM: Int, ceilingRPM: Int) -> String {
        let start = Int(threshold)
        let full = Int(fullSpeedTemperature)
        if response <= responseRange.lowerBound + 0.05 {
            return "Fans stay at their minimum speed at every temperature."
        }
        func speed(at temperature: Double) -> Int {
            target(temperature: temperature, threshold: threshold, response: response,
                   floorRPM: floorRPM, ceilingRPM: ceilingRPM)
        }
        let low = speed(at: min(threshold, fullSpeedTemperature - 1))
        let high = speed(at: fullSpeedTemperature)
        if response >= responseRange.upperBound - 0.05 || low >= high {
            return "Fans run at \(high.formatted()) RPM at every temperature."
        }
        let cool = low <= floorRPM
            ? "Fans stay at minimum" : "Fans hold \(low.formatted()) RPM"
        let curve = start >= full
            ? "\(cool) until \(full) °C, then run at \(high.formatted()) RPM."
            : "\(cool) up to \(start) °C, then speed up to reach \(high.formatted()) RPM at \(full) °C."
        guard high < max(floorRPM, ceilingRPM) else { return curve }
        return curve + " \(responseLabel(response)) keeps them under Max speed, \(ceilingRPM.formatted()) RPM."
    }
}

/// Comfort band of a die temperature, as the popover labels it.
nonisolated enum TemperatureLevel: Equatable {
    case cool
    case normal
    case warm
    case hot

    init(celsius: Double) {
        switch celsius {
        case ..<50: self = .cool
        case ..<70: self = .normal
        case ..<85: self = .warm
        default: self = .hot
        }
    }

    /// The temperature meter's and the Auto graph's scale: 30 °C is an idle
    /// die; 100 °C is where Apple Silicon throttles hard.
    static let meterRange: ClosedRange<Double> = 30...100

    /// Where `celsius` falls on `meterRange`, clamped to 0...1.
    static func meterFraction(_ celsius: Double) -> Double {
        let fraction = (celsius - meterRange.lowerBound) / (meterRange.upperBound - meterRange.lowerBound)
        return min(1, max(0, fraction))
    }

    var title: String {
        switch self {
        case .cool: return "Cool"
        case .normal: return "Normal"
        case .warm: return "Warm"
        case .hot: return "Hot"
        }
    }
}

/// Decides when Auto sends a new speed to the fans. Every send runs sudo and
/// the root helper once per fan, and the temperature jumps by degrees between
/// readings. Sending every change of 50 RPM made about 12 sends a minute
/// under load, and the fans turned back up within seconds of slowing down.
/// A rise goes out at once; a fall waits until the curve has stayed lower for
/// `fallTicks` readings, then sends the highest target of those readings.
nonisolated struct AutoSpeedGate {
    /// A rise this large goes out at once: 1 °C on the Standard curve.
    static let riseRPM = 100
    /// A fall this large goes out once it has lasted `fallTicks` readings
    /// (10 s at Auto's 2 s tick), as does settling to the floor.
    static let fallRPM = 150
    static let fallTicks = 5

    /// The speed last sent, or nil when the next reading must send.
    private(set) var sent: Int?
    private var recent: [Int] = []

    /// Makes the next reading send whatever the curve gives, for a changed
    /// curve or fans that may have left FanMac's control.
    mutating func reset() {
        sent = nil
        recent = []
    }

    /// The speed to send for this reading's curve `target`, or nil to leave
    /// the fans at `sent`.
    mutating func speed(for target: Int, floorRPM: Int, ceilingRPM: Int) -> Int? {
        recent.append(target)
        if recent.count > Self.fallTicks {
            recent.removeFirst()
        }
        guard let sent else { return send(target) }
        if target >= sent + Self.riseRPM || (target >= ceilingRPM && sent < ceilingRPM) {
            return send(target)
        }
        guard recent.count == Self.fallTicks, let peak = recent.max(), peak < sent else { return nil }
        if peak <= sent - Self.fallRPM || peak <= floorRPM {
            return send(peak)
        }
        return nil
    }

    private mutating func send(_ rpm: Int) -> Int {
        sent = rpm
        return rpm
    }
}
