//
//  DashboardEditOverlay.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Edit-mode chrome: drop zones, remove badges, frame tracking.
//

import SwiftUI

// MARK: - Drop zone (always hittable in edit mode)

struct DashboardDropZone: View {
    let slot: DropSlotID
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let minHitHeight = FanMacSpacing.space6
    /// A card row's height, where the card would land.
    private let activeHeight: CGFloat = 36

    // Where a drag will land, as Ardvis marks every drop target
    // (`ArdvisDropHighlight`): the dimmed accent, washed and ringed.
    var body: some View {
        RoundedRectangle(cornerRadius: FanMacTheme.cardCornerRadius, style: .continuous)
            .fill(FanMacTheme.chromeAccent.opacity(0.16))
            .strokeBorder(FanMacTheme.chromeAccent, lineWidth: 1)
            .opacity(isActive ? 1 : 0)
            .frame(height: isActive ? activeHeight : minHitHeight)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .animation(FanMacMotion.selection(reduceMotion: reduceMotion), value: isActive)
            .trackDropSlotFrame(slot: slot)
    }
}

// MARK: - Remove badge

struct WidgetRemoveBadge: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 20))
                .symbolRenderingMode(.palette)
                .foregroundStyle(FanMacTheme.canvas, FanMacTheme.destructive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove Widget")
        .help("Remove Widget")
        // Centred on the card's top edge, clear of the card's top line of text.
        .offset(x: 6, y: -10)
    }
}

// MARK: - Preference keys

struct WidgetFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, n in n }
    }
}

struct DropSlotFramePreferenceKey: PreferenceKey {
    static var defaultValue: [DropSlotID: CGRect] = [:]
    static func reduce(value: inout [DropSlotID: CGRect], nextValue: () -> [DropSlotID: CGRect]) {
        value.merge(nextValue()) { _, n in n }
    }
}

extension View {
    func trackWidgetFrame(id: UUID, in space: CoordinateSpace) -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: WidgetFramePreferenceKey.self,
                    value: [id: geo.frame(in: space)]
                )
            }
        }
    }

    func trackDropSlotFrame(slot: DropSlotID, in space: CoordinateSpace = .named("dashboardGrid")) -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: DropSlotFramePreferenceKey.self,
                    value: [slot: geo.frame(in: space)]
                )
            }
        }
    }
}
