//
//  DashboardModels.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Codable models for the popover widget dashboard layout.
//

import Foundation

/// Identifies a widget type shown in the popover dashboard.
enum DashboardWidgetKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case cpuTemperature
    case gpuTemperature
    case powerOrSystem
    case fanControl
    case autoModeSettings
    case batteryInfo
    case systemInfo

    var id: String { rawValue }

    /// Human-readable title for the widget gallery.
    var displayName: String {
        switch self {
        case .cpuTemperature: return "CPU Temperature"
        case .gpuTemperature: return "GPU Temperature"
        case .powerOrSystem: return "Power or Fan Load"
        case .fanControl: return "Fans"
        case .autoModeSettings: return "Auto Curve"
        case .batteryInfo: return "Battery"
        case .systemInfo: return "System"
        }
    }

    var galleryIcon: String {
        switch self {
        case .cpuTemperature: return "cpu"
        case .gpuTemperature: return "display"
        case .powerOrSystem: return "bolt.fill"
        case .fanControl: return "fan.fill"
        case .autoModeSettings: return "dial.medium"
        case .batteryInfo: return "battery.100"
        case .systemInfo: return "info.circle"
        }
    }

    var galleryDescription: String {
        switch self {
        case .cpuTemperature: return "CPU temperature and comfort band"
        case .gpuTemperature: return "GPU temperature and comfort band"
        case .powerOrSystem: return "What the Mac draws, or fan load without a battery"
        case .fanControl: return "Each fan’s speed and the manual sliders"
        case .autoModeSettings: return "When fans speed up in Auto, and how far"
        case .batteryInfo: return "Charge, health, cycles and capacity"
        case .systemInfo: return "Thermal pressure, temperatures and fan ranges"
        }
    }

    /// Default column span when added to a row (1 = half width, 2 = full width).
    var defaultColumnSpan: Int {
        switch self {
        case .cpuTemperature, .gpuTemperature, .powerOrSystem:
            return 1
        case .fanControl, .autoModeSettings, .batteryInfo, .systemInfo:
            return 2
        }
    }

    /// Whether this widget is available on the current device profile.
    func isAvailable(hasBattery: Bool, hasFans: Bool) -> Bool {
        switch self {
        case .batteryInfo:
            return hasBattery
        case .fanControl, .autoModeSettings:
            return hasFans
        case .powerOrSystem:
            // Power needs the battery's telemetry; fan load needs fans.
            return hasBattery || hasFans
        default:
            return true
        }
    }

    /// Whether this widget draws anything now: it is available here, and the
    /// Auto curve shows only in Auto.
    func isShown(hasBattery: Bool, hasFans: Bool, isAuto: Bool) -> Bool {
        isAvailable(hasBattery: hasBattery, hasFans: hasFans) && (self != .autoModeSettings || isAuto)
    }
}

/// A single placed widget in the dashboard grid.
struct DashboardWidget: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var kind: DashboardWidgetKind
    /// Number of columns this widget spans within its row (1 or 2).
    var columnSpan: Int

    init(id: UUID = UUID(), kind: DashboardWidgetKind, columnSpan: Int? = nil) {
        self.id = id
        self.kind = kind
        self.columnSpan = columnSpan ?? kind.defaultColumnSpan
    }
}

/// One horizontal row in the dashboard; widgets flow left-to-right up to `columns`.
struct DashboardRow: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    /// 1 = single column (full width widgets), 2 = two-column grid.
    var columns: Int
    var widgets: [DashboardWidget]

    init(id: UUID = UUID(), columns: Int = 2, widgets: [DashboardWidget] = []) {
        self.id = id
        self.columns = min(2, max(1, columns))
        self.widgets = widgets
    }

    /// Whether any widget in the row draws anything now. A row of widgets that
    /// draw nothing would still add a gap between the cards.
    func isShown(hasBattery: Bool, hasFans: Bool, isAuto: Bool) -> Bool {
        widgets.contains { $0.kind.isShown(hasBattery: hasBattery, hasFans: hasFans, isAuto: isAuto) }
    }
}

/// Full persisted dashboard layout.
struct DashboardLayout: Codable, Equatable {
    var rows: [DashboardRow]

    /// All widget kinds currently placed in the layout.
    var placedKinds: Set<DashboardWidgetKind> {
        Set(rows.flatMap { $0.widgets.map(\.kind) })
    }
}
