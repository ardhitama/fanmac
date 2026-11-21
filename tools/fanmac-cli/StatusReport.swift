//
//  StatusReport.swift
//  fanmac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Wording shared by `fanmac status` and `fanmac watch`.
//

import Foundation

extension FanMacControl.Status {
    var helperReady: Bool { helperInstalled && !helperNeedsUpdate }
    var perFan: Bool { manualSpeedPerFan != nil }

    var summary: String {
        FanMacControl.controlSummary(
            hasNoFans: hasNoFans == true,
            helperInstalled: helperInstalled,
            helperReady: helperReady,
            controlledByFanMac: controlledByFanMac,
            mode: mode,
            perFan: perFan,
            manualRPM: manualSpeed
        )
    }

    /// As the controller runs the curve: from the lowest fan minimum to Max
    /// speed, which no fan can run above its own top speed. Nil until FanMac
    /// has read the fans, since the speeds depend on their range.
    var curveSummary: String? {
        guard let floor = fans.map(\.minRPM).min(), let top = fans.map(\.maxRPM).max() else { return nil }
        return FanCurve.summary(threshold: speedUpFrom, response: response, floorRPM: floor, ceilingRPM: min(maxSpeed, top))
    }

    /// Auto's targets while FanMac holds the fans, as the popover's Fans card
    /// shows them: one for every fan when they share it, else one each. Manual
    /// shows its targets as settings instead.
    var autoTargets: (shared: Int?, perFan: [Int])? {
        guard mode == .auto, controlledByFanMac else { return nil }
        let targets = fans.compactMap(\.target)
        guard targets.count == fans.count, let first = targets.first else { return nil }
        return targets.allSatisfy { $0 == first } ? (first, []) : (nil, targets)
    }

    var minRPM: Int { fans.map(\.minRPM).min() ?? 0 }
    var maxRPM: Int { fans.map(\.maxRPM).max() ?? 0 }

    /// The hotter of CPU and GPU, which Auto ramps on.
    var hottestTemperature: Double? {
        [cpuTemperature, gpuTemperature].compactMap { $0 }.max()
    }
}

extension FanMacControl.Fan {
    /// Where the fan runs within its own range, 0...1.
    var rangeFraction: Double {
        guard maxRPM > minRPM else { return 0 }
        return min(1, max(0, Double(rpm - minRPM) / Double(maxRPM - minRPM)))
    }
}

func temperatureText(_ celsius: Double?) -> String {
    guard let celsius else { return "–" }
    return "\(Int(celsius.rounded())) °C"
}

func temperatureRole(_ celsius: Double?) -> Palette.Role {
    guard let celsius else { return .secondary }
    return TemperatureLevel(celsius: celsius) == .hot ? .warning : .text
}

/// What `fanmac status` prints: one labelled line per fact.
func statusReport(_ status: FanMacControl.Status, palette: Palette) -> String {
    var rows: [(String, String, Palette.Role)] = [
        ("FanMac", status.summary, .text),
    ]
    if let cpu = status.cpuTemperature {
        rows.append(("CPU", "\(temperatureText(cpu)), \(TemperatureLevel(celsius: cpu).title.lowercased())", temperatureRole(cpu)))
    }
    if let gpu = status.gpuTemperature {
        rows.append(("GPU", "\(temperatureText(gpu)), \(TemperatureLevel(celsius: gpu).title.lowercased())", temperatureRole(gpu)))
    }
    rows.append((
        "Thermal",
        status.thermalPressure + (status.thermalPressureLimitsPerformance ? ", macOS is slowing the Mac to cool it" : ""),
        status.thermalPressureLimitsPerformance ? .warning : .text
    ))
    let autoTargets = status.autoTargets
    for (index, fan) in status.fans.enumerated() {
        // A fan's own target where fans differ: Auto's, or each fan's Manual
        // speed, which the summary doesn't name.
        let target: Int? = if let perFan = autoTargets?.perFan, index < perFan.count {
            perFan[index]
        } else if status.mode == .manual, status.perFan, status.controlledByFanMac {
            fan.target
        } else {
            nil
        }
        rows.append((
            "Fan \(index + 1)",
            "\(fan.rpm.formatted()) RPM"
                + (target.map { ", target \($0.formatted())" } ?? "")
                + "  (\(fan.minRPM.formatted())–\(fan.maxRPM.formatted()))",
            .text
        ))
    }
    if let shared = autoTargets?.shared {
        rows.append(("Target", "\(shared.formatted()) RPM", .text))
    }
    if status.mode == .auto, status.hasNoFans != true, let curve = status.curveSummary {
        rows.append(("Auto curve", curve, .text))
    }
    if let problem = status.problem {
        rows.append(("Problem", problem, .destructive))
    }

    let labelWidth = rows.map(\.0.count).max() ?? 0
    return rows.map { label, value, role in
        palette.paint(label.padding(toLength: labelWidth + 2, withPad: " ", startingAt: 0), .secondary)
            + palette.paint(value, role)
    }.joined(separator: "\n")
}
