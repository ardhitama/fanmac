//
//  DashboardWidgetViews.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Extracted widget content views for the popover dashboard.
//

import SwiftUI

// MARK: - Auto mode widget

struct AutoModeSettingsWidget: View {
    @ObservedObject var viewModel: FanControlViewModel

    private var responseLabel: String {
        FanCurve.responseLabel(viewModel.autoAggressiveness)
    }

    private var maxSpeedRange: ClosedRange<Double> {
        Double(viewModel.effectiveUnifiedMinRPM)...Double(max(viewModel.effectiveUnifiedMaxRPM, viewModel.effectiveUnifiedMinRPM + 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FanMacSpacing.space5) {
            Text("Auto Curve").fanMacCardTitle()

            // The controller ramps on the hotter of CPU and GPU.
            AutoCurveGraph(
                threshold: viewModel.autoThreshold,
                response: viewModel.autoAggressiveness,
                floorRPM: viewModel.effectiveUnifiedMinRPM,
                ceilingRPM: min(viewModel.autoMaxSpeed, viewModel.effectiveUnifiedMaxRPM),
                topRPM: viewModel.effectiveUnifiedMaxRPM,
                temperature: viewModel.cpuTemperature == nil && viewModel.gpuTemperature == nil
                    ? nil : viewModel.getMaxTemperature(),
                summary: FanCurve.summary(
                    threshold: viewModel.autoThreshold,
                    response: viewModel.autoAggressiveness,
                    floorRPM: viewModel.effectiveUnifiedMinRPM,
                    ceilingRPM: min(viewModel.autoMaxSpeed, viewModel.effectiveUnifiedMaxRPM)
                )
            )

            SettingRow(label: "Speed up from", value: "\(Int(viewModel.autoThreshold)) °C") {
                Slider(
                    value: Binding(
                        get: { viewModel.autoThreshold },
                        set: { viewModel.setAutoThreshold($0) }
                    ).snapped(to: 5, in: 40...90),
                    in: 40...90
                )
            }

            SettingRow(label: "Max speed", value: "\(viewModel.autoMaxSpeed.formatted()) RPM") {
                Slider(
                    value: Binding(
                        get: { Double(viewModel.autoMaxSpeed) },
                        set: { viewModel.setAutoMaxSpeed(Int($0)) }
                    ).snapped(to: 100, in: maxSpeedRange),
                    in: maxSpeedRange
                )
            }

            SettingRow(label: "Response", value: responseLabel) {
                Slider(
                    value: Binding(
                        get: { viewModel.autoAggressiveness },
                        set: { viewModel.setAutoAggressiveness($0) }
                    ).snapped(to: 0.1, in: FanCurve.responseRange),
                    in: FanCurve.responseRange
                )
            }
        }
        .fanMacCard()
    }
}

// MARK: - Auto curve graph

/// The fan speed Auto sets at each temperature, on the temperature meter's
/// scale, with the current temperature marked. It shows what the three
/// sliders add up to, so no sentence has to repeat their values.
struct AutoCurveGraph: View {
    let threshold: Double
    let response: Double
    let floorRPM: Int
    let ceilingRPM: Int
    /// The top of the graph: the fans' maximum, so a lower Max speed shows.
    let topRPM: Int
    let temperature: Double?
    /// The curve in words, for VoiceOver.
    let summary: String

    private static let height: CGFloat = 56
    /// Keeps the line and the marker clear of the graph's edges.
    private static let inset = FanMacSpacing.space2
    private static let markerDiameter = FanMacSpacing.space4

    var body: some View {
        VStack(spacing: FanMacSpacing.space1) {
            Canvas { context, size in
                let plot = CGRect(origin: .zero, size: size).insetBy(dx: Self.inset, dy: Self.inset)
                let range = TemperatureLevel.meterRange

                var curve = Path()
                for celsius in stride(from: range.lowerBound, through: range.upperBound, by: 1) {
                    let point = self.point(celsius: celsius, in: plot)
                    if curve.isEmpty { curve.move(to: point) } else { curve.addLine(to: point) }
                }

                // The hottest reading, in the text's tone: the grey accent sits at
                // the curve's own tone, so the dot stands out by lightness. The
                // line and the area stop short of it, leaving a ring of the card
                // itself: a ring painted in the card's colour would show on a
                // card the wallpaper tints.
                let dot = temperature.map { temperature in
                    let center = point(celsius: min(range.upperBound, max(range.lowerBound, temperature)), in: plot)
                    let radius = Self.markerDiameter / 2
                    return CGRect(x: center.x - radius, y: center.y - radius, width: Self.markerDiameter, height: Self.markerDiameter)
                }
                var underDot = context
                if let dot {
                    underDot.clip(
                        to: Path(ellipseIn: dot.insetBy(dx: -FanMacSpacing.space1, dy: -FanMacSpacing.space1)),
                        options: .inverse
                    )
                }

                // The speed above the fans' minimum in the meters' track tone,
                // so the curve reads as a level, as a meter's fill does.
                var area = curve
                area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
                area.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
                area.closeSubpath()
                underDot.fill(area, with: .color(FanMacTheme.fill))

                underDot.stroke(
                    curve,
                    with: .color(FanMacTheme.secondaryText),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )

                if let dot {
                    context.fill(Path(ellipseIn: dot), with: .color(FanMacTheme.text))
                }
            }
            .frame(height: Self.height)

            HStack {
                Text("\(Int(TemperatureLevel.meterRange.lowerBound)) °C")
                Spacer()
                Text("\(Int(TemperatureLevel.meterRange.upperBound)) °C")
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(FanMacTheme.secondaryText)
        }
        .accessibilityElement()
        .accessibilityLabel("Auto curve")
        .accessibilityValue(summary)
    }

    private func point(celsius: Double, in plot: CGRect) -> CGPoint {
        let level = FanCurve.level(
            temperature: celsius,
            threshold: threshold,
            response: response,
            floorRPM: floorRPM,
            ceilingRPM: ceilingRPM,
            topRPM: topRPM
        )
        return CGPoint(
            x: plot.minX + plot.width * TemperatureLevel.meterFraction(celsius),
            y: plot.maxY - plot.height * level
        )
    }
}

// MARK: - Battery widget

struct BatteryInfoWidget: View {
    @ObservedObject var battery: BatteryMonitor

    var body: some View {
        let info = battery.batteryInfo
        VStack(alignment: .leading, spacing: FanMacSpacing.space4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Battery").fanMacCardTitle()
                Spacer()
                Text("\(info.percentage)%")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(FanMacTheme.text)
            }

            VStack(spacing: FanMacSpacing.space2) {
                CompactInfoItem(label: "Source", value: info.isCharging ? "Charging" : (info.isPluggedIn ? "Power adapter" : "Battery"))
                if let timeStr = info.formattedTimeRemaining {
                    CompactInfoItem(label: info.isCharging ? "Full in" : "Time left", value: timeStr)
                }
                CompactInfoItem(label: "Health", value: "\(info.health)%, \(info.condition.lowercased())")
                CompactInfoItem(label: "Cycles", value: info.cycleCount.formatted())
                if let maxCap = info.maxCapacity, let designCap = info.designCapacity {
                    CompactInfoItem(label: "Capacity", value: "\(maxCap.formatted()) of \(designCap.formatted()) mAh")
                }
                if let power = info.powerWatts, power > 0.1 {
                    CompactInfoItem(label: "Power", value: String(format: "%.1f W", power))
                }
                if let temp = info.temperature {
                    CompactInfoItem(label: "Temperature", value: String(format: "%.1f °C", temp))
                }
                if let voltage = info.voltage {
                    CompactInfoItem(label: "Voltage", value: String(format: "%.2f V", voltage))
                }
            }
        }
        .fanMacCard()
    }
}

// MARK: - System info widget

struct SystemInfoWidget: View {
    @ObservedObject var viewModel: FanControlViewModel

    private var controlText: String {
        guard viewModel.isControlEnabled else { return "macOS" }
        return viewModel.controlMode == .automatic ? "FanMac, Auto" : "FanMac, Manual"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FanMacSpacing.space4) {
            Text("System").fanMacCardTitle()

            VStack(spacing: FanMacSpacing.space2) {
                CompactInfoItem(label: "Thermal pressure", value: viewModel.thermalState.title)
                if let cpuTemp = viewModel.cpuTemperature {
                    CompactInfoItem(label: "CPU", value: String(format: "%.0f °C", cpuTemp))
                }
                if let gpuTemp = viewModel.gpuTemperature {
                    CompactInfoItem(label: "GPU", value: String(format: "%.0f °C", gpuTemp))
                }
                if !viewModel.hasNoFans {
                    CompactInfoItem(label: "Fan control", value: controlText)
                }
                ForEach(0..<viewModel.numberOfFans, id: \.self) { i in
                    CompactInfoItem(
                        label: "Fan \(i + 1) range",
                        value: "\(viewModel.minRPM(atFan: i).formatted())–\(viewModel.maxRPM(atFan: i).formatted()) RPM"
                    )
                }
            }
        }
        .fanMacCard()
    }
}

// MARK: - Desktop system load card (no battery)

struct SystemLoadCardView: View {
    let fanPercent: Int
    let fanRPM: Int

    var body: some View {
        VStack(alignment: .leading, spacing: FanMacSpacing.space4) {
            Text("Fan Load").fanMacCardTitle()

            HStack(alignment: .firstTextBaseline, spacing: FanMacSpacing.space1) {
                Text("\(fanPercent)")
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                Text("%")
                    .font(.title3)
            }
            .foregroundStyle(FanMacTheme.text)

            Text("\(fanRPM.formatted()) RPM")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(FanMacTheme.secondaryText)
        }
        .fanMacCard()
    }
}

/// While editing, a widget this Mac can't show, such as Fans on a Mac
/// without fans or Battery on one without a battery.
private struct UnavailableWidgetCard: View {
    let title: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).fanMacCardTitle()
            Spacer()
            Text("Not on this Mac")
                .font(.caption)
                .foregroundStyle(FanMacTheme.secondaryText)
        }
        .fanMacCard()
    }
}

// MARK: - Widget router

struct DashboardWidgetView: View {
    let widget: DashboardWidget
    @ObservedObject var viewModel: FanControlViewModel
    @ObservedObject var battery: BatteryMonitor
    var isEditing: Bool = false

    var body: some View {
        Group {
            if isEditing {
                // Every widget keeps its card while editing, so it can be
                // moved or removed: the Auto Curve shows in Manual too.
                if widget.kind.isAvailable(hasBattery: battery.hasBattery, hasFans: !viewModel.hasNoFans) {
                    content
                } else {
                    UnavailableWidgetCard(title: widget.kind.displayName)
                }
            } else if widget.kind.isShown(
                hasBattery: battery.hasBattery,
                hasFans: !viewModel.hasNoFans,
                isAuto: viewModel.controlMode == .automatic
            ) {
                content
            }
        }
        .allowsHitTesting(!isEditing)
    }

    @ViewBuilder
    private var content: some View {
        switch widget.kind {
        case .cpuTemperature:
            TemperatureView(label: "CPU", temperature: viewModel.cpuTemperature)
        case .gpuTemperature:
            TemperatureView(label: "GPU", temperature: viewModel.gpuTemperature)
        case .powerOrSystem:
            if battery.hasBattery {
                PowerCardView(info: battery.batteryInfo)
            } else {
                SystemLoadCardView(
                    fanPercent: viewModel.averageFanLoadPercent,
                    fanRPM: viewModel.currentFanSpeed
                )
            }
        case .fanControl:
            FanSpeedView(viewModel: viewModel)
        case .autoModeSettings:
            AutoModeSettingsWidget(viewModel: viewModel)
        case .batteryInfo:
            BatteryInfoWidget(battery: battery)
        case .systemInfo:
            SystemInfoWidget(viewModel: viewModel)
        }
    }
}
