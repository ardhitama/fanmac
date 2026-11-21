//
//  TemperatureView.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Temperature card: the reading, its comfort band and a meter.
//

import SwiftUI

struct TemperatureView: View {
    let label: String
    let temperature: Double?

    private var level: TemperatureLevel? {
        temperature.map(TemperatureLevel.init(celsius:))
    }

    /// Only a hot reading asks for attention, so only it takes a status colour.
    private var tone: Color {
        level == .hot ? FanMacTheme.warning : FanMacTheme.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FanMacSpacing.space4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).fanMacCardTitle()
                Spacer()
                Text(level?.title ?? "No reading")
                    .font(.caption)
                    .foregroundStyle(level == .hot ? FanMacTheme.warning : FanMacTheme.secondaryText)
            }

            HStack(alignment: .firstTextBaseline, spacing: FanMacSpacing.space1) {
                if let temperature {
                    Text(temperature, format: .number.precision(.fractionLength(0)))
                        .font(.title.weight(.semibold))
                        .monospacedDigit()
                    Text("°C")
                        .font(.title3)
                } else {
                    Text("–")
                        .font(.title.weight(.semibold))
                }
            }
            .foregroundStyle(tone)

            Spacer(minLength: 0)

            FanMacMeter(
                fraction: TemperatureLevel.meterFraction(temperature ?? TemperatureLevel.meterRange.lowerBound),
                fill: level == .hot ? FanMacTheme.warning : FanMacTheme.secondaryText
            )
        }
        .fanMacCard()
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    HStack(spacing: FanMacTheme.containerInset) {
        TemperatureView(label: "CPU", temperature: 65.5)
        TemperatureView(label: "GPU", temperature: 88.3)
    }
    .padding()
}
