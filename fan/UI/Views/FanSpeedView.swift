//
//  FanSpeedView.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Fan card: each fan's measured speed within its range, FanMac's target,
//  and the manual sliders (bounds from SMC).
//

import SwiftUI

struct FanSpeedView: View {
    @ObservedObject var viewModel: FanControlViewModel
    @State private var localSpeed: Double = 2000
    @State private var localSpeeds: [Double] = []
    @State private var isApplying: Bool = false
    @State private var perFanApplying: Set<Int> = []
    @State private var unifiedDebounceTask: Task<Void, Never>?
    @State private var perFanDebounceTasks: [Int: Task<Void, Never>] = [:]

    private var unifiedSliderMin: Double {
        Double(viewModel.effectiveUnifiedMinRPM)
    }

    private var unifiedSliderMax: Double {
        let hi = viewModel.effectiveUnifiedMaxRPM
        let lo = viewModel.effectiveUnifiedMinRPM
        return Double(max(hi, lo + 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FanMacSpacing.space5) {
            HStack(alignment: .firstTextBaseline) {
                Text("Fans").fanMacCardTitle()
                Spacer()
                if let target = autoTargets?.shared {
                    Text("Target \(target.formatted()) RPM")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(FanMacTheme.secondaryText)
                }
            }

            if viewModel.numberOfFans == 0 {
                Text("No fans")
                    .font(.caption)
                    .foregroundStyle(FanMacTheme.secondaryText)
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: FanMacSpacing.space5, alignment: .topLeading),
                        count: min(2, viewModel.numberOfFans)
                    ),
                    alignment: .leading,
                    spacing: FanMacSpacing.space5
                ) {
                    ForEach(0..<viewModel.numberOfFans, id: \.self) { index in
                        fanReadout(index: index)
                    }
                }
            }

            if viewModel.controlMode == .manual {
                manualControls
            }
        }
        .fanMacCard()
        .onChange(of: viewModel.manualSpeeds) { _, newVal in
            syncLocalSpeedsFromModel(newVal)
        }
        .onChange(of: viewModel.numberOfFans) { _, _ in
            syncLocalSpeedsFromModel(viewModel.manualSpeeds)
        }
    }

    // MARK: - Readouts

    /// Auto's targets while FanMac holds the fans: one for the title when every
    /// fan shares it, else one under each fan. Manual shows its target on the
    /// slider instead.
    private var autoTargets: (shared: Int?, perFan: [Int])? {
        guard viewModel.controlMode == .automatic,
              viewModel.isControlEnabled,
              let first = viewModel.appliedTargets.first
        else { return nil }
        let targets = viewModel.appliedTargets
        return targets.allSatisfy({ $0 == first }) ? (first, []) : (nil, targets)
    }

    private func fanReadout(index: Int) -> some View {
        let speed = index < viewModel.fanSpeeds.count ? viewModel.fanSpeeds[index] : nil
        let low = viewModel.minRPM(atFan: index)
        let high = viewModel.maxRPM(atFan: index)

        return VStack(alignment: .leading, spacing: FanMacSpacing.space2) {
            if viewModel.numberOfFans > 1 {
                Text("Fan \(index + 1)")
                    .font(.caption)
                    .foregroundStyle(FanMacTheme.secondaryText)
            }

            HStack(alignment: .firstTextBaseline, spacing: FanMacSpacing.space2) {
                if let speed {
                    Text(speed.formatted())
                        .font(.title.weight(.semibold))
                        .monospacedDigit()
                    Text("RPM")
                        .font(.title3)
                } else {
                    Text("–")
                        .font(.title.weight(.semibold))
                }
            }
            .foregroundStyle(FanMacTheme.text)

            // Where the fan runs within its own range, as the CPU meter shows
            // the temperature within its scale.
            FanMacMeter(fraction: high > low ? Double((speed ?? low) - low) / Double(high - low) : 0)

            if let targets = autoTargets?.perFan, index < targets.count {
                Text("Target \(targets[index].formatted()) RPM")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(FanMacTheme.secondaryText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Manual

    private var manualControls: some View {
        VStack(alignment: .leading, spacing: FanMacSpacing.space5) {
            if viewModel.numberOfFans > 1 {
                // The switch ends the row, as a Form row's does, rather than
                // stopping wherever the label ends.
                HStack {
                    Text("Separate speed for each fan")
                        .font(.caption)
                        .foregroundStyle(FanMacTheme.text)
                    Spacer()
                    Toggle("Separate speed for each fan", isOn: Binding(
                        get: { viewModel.perFanManualControl },
                        set: { viewModel.setPerFanManualControl($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                }
            }

            if viewModel.perFanManualControl && viewModel.numberOfFans > 1 {
                ForEach(0..<viewModel.numberOfFans, id: \.self) { index in
                    perFanRow(index: index)
                }
            } else {
                unifiedSliderRow
            }
        }
    }

    private var unifiedSliderRow: some View {
        SettingRow(
            label: "Target speed",
            value: "\(Int(localSpeed).formatted()) RPM",
            isApplying: isApplying
        ) {
            Slider(
                value: $localSpeed.snapped(to: 100, in: unifiedSliderMin...unifiedSliderMax),
                in: unifiedSliderMin...unifiedSliderMax
            )
        }
        .onChange(of: localSpeed) { _, newValue in
            unifiedDebounceTask?.cancel()
            unifiedDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if Int(newValue) != viewModel.manualSpeed {
                        isApplying = true
                        viewModel.setManualSpeed(Int(newValue))
                    }
                }
            }
        }
        .onChange(of: viewModel.manualSpeed) { _, newValue in
            let clamped = Double(
                max(viewModel.effectiveUnifiedMinRPM, min(viewModel.effectiveUnifiedMaxRPM, newValue))
            )
            if abs(localSpeed - clamped) > 1 {
                localSpeed = clamped
            }
            isApplying = false
        }
        .task(id: "\(viewModel.effectiveUnifiedMinRPM)-\(viewModel.effectiveUnifiedMaxRPM)-\(viewModel.manualSpeed)") {
            localSpeed = Double(
                max(viewModel.effectiveUnifiedMinRPM, min(viewModel.effectiveUnifiedMaxRPM, viewModel.manualSpeed))
            )
        }
    }

    private func perFanRow(index: Int) -> some View {
        let mn = Double(viewModel.minRPM(atFan: index))
        let mx = Double(max(viewModel.maxRPM(atFan: index), viewModel.minRPM(atFan: index) + 1))
        let binding = Binding<Double>(
            get: {
                if index < localSpeeds.count {
                    return localSpeeds[index]
                }
                let v = index < viewModel.manualSpeeds.count ? viewModel.manualSpeeds[index] : viewModel.manualSpeed
                return Double(max(viewModel.minRPM(atFan: index), min(viewModel.maxRPM(atFan: index), v)))
            },
            set: { newVal in
                if localSpeeds.count <= index {
                    syncLocalSpeedsFromModel(viewModel.manualSpeeds)
                }
                if index < localSpeeds.count {
                    localSpeeds[index] = newVal
                }
                debouncedApplyPerFan(index: index, value: newVal)
            }
        )

        return SettingRow(
            label: "Fan \(index + 1) target",
            value: "\(Int(binding.wrappedValue).formatted()) RPM",
            isApplying: perFanApplying.contains(index)
        ) {
            Slider(value: binding.snapped(to: 100, in: mn...mx), in: mn...mx)
        }
    }

    private func debouncedApplyPerFan(index: Int, value: Double) {
        perFanDebounceTasks[index]?.cancel()
        perFanDebounceTasks[index] = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                perFanApplying.insert(index)
                viewModel.setManualSpeedForFan(index: index, speed: Int(value))
                perFanApplying.remove(index)
                perFanDebounceTasks[index] = nil
            }
        }
    }

    private func syncLocalSpeedsFromModel(_ speeds: [Int]) {
        localSpeeds = (0..<viewModel.numberOfFans).map { i in
            let v = i < speeds.count ? speeds[i] : viewModel.manualSpeed
            return Double(max(viewModel.minRPM(atFan: i), min(viewModel.maxRPM(atFan: i), v)))
        }
    }
}

#Preview {
    FanSpeedView(viewModel: FanControlViewModel())
        .padding()
}
