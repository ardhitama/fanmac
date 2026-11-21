//
//  PopoverView.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Menu bar popover: what the fans are doing, why, and the widget dashboard.
//  The popover is one frosted surface (`FanMacFrost`); cards draw no fill.
//

import SwiftUI

struct PopoverView: View {
    @ObservedObject var viewModel: FanControlViewModel
    @ObservedObject var permissions = PermissionsManager.shared
    @ObservedObject var battery = BatteryMonitor.shared
    @ObservedObject private var dashboardStore = DashboardStore.shared
    var statusBarManager: StatusBarManager?

    @State private var showingResetDashboardConfirm = false
    @State private var isEditingDashboard: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `editingWidgets` opens it as the menu bar icon's Edit Widgets does.
    init(viewModel: FanControlViewModel, statusBarManager: StatusBarManager? = nil, editingWidgets: Bool = false) {
        self.viewModel = viewModel
        self.statusBarManager = statusBarManager
        _isEditingDashboard = State(initialValue: editingWidgets)
    }

    /// A Mac without fans has nothing for the helper to do.
    static func needsHelper(_ viewModel: FanControlViewModel, permissions: PermissionsManager) -> Bool {
        !viewModel.hasNoFans && (!permissions.isHelperInstalled || permissions.isHelperOutdated)
    }

    /// Whether the popover shows its widgets, which Edit Widgets arranges.
    static func showsWidgets(_ viewModel: FanControlViewModel, permissions: PermissionsManager) -> Bool {
        !needsHelper(viewModel, permissions: permissions) && viewModel.hasAccess && viewModel.cpuTemperature != nil
    }

    private var needsHelper: Bool { Self.needsHelper(viewModel, permissions: permissions) }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView {
                VStack(spacing: FanMacTheme.containerInset) {
                    if needsHelper {
                        installHelperView
                    } else if !viewModel.hasAccess {
                        noAccessView
                    } else if viewModel.cpuTemperature == nil {
                        noDataView
                    } else {
                        notices
                        DashboardGridView(
                            store: dashboardStore,
                            viewModel: viewModel,
                            battery: battery,
                            isEditing: $isEditingDashboard
                        )
                    }
                }
                .padding(.horizontal, FanMacTheme.containerInset)
                .padding(.bottom, FanMacTheme.containerInset)
            }

            if isEditingDashboard {
                editingFooter
            }
        }
        .frame(width: 340)
        // The popover takes this view's ideal height: its content, up to a
        // height that still fits under the menu bar on a small display.
        .frame(maxHeight: 640)
        // Under the arrow too: the popover has full-size content.
        .background { FanMacFrost().ignoresSafeArea() }
        .tint(FanMacTheme.accent)
        .onAppear {
            if viewModel.hasAccess && !viewModel.isMonitoring {
                viewModel.startMonitoring()
            }
            battery.startMonitoring()
        }
        .onDisappear {
            battery.stopMonitoring()
        }
        .onChange(of: battery.hasBattery) { _, hasBattery in
            if !hasBattery {
                dashboardStore.removeWidgets(ofKind: .batteryInfo)
            }
        }
        .alert("Reset the widget layout?", isPresented: $showingResetDashboardConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Reset Layout", role: .destructive) {
                withAnimation(FanMacMotion.panel(reduceMotion: reduceMotion)) {
                    dashboardStore.resetToDefaults(hasBattery: battery.hasBattery)
                }
            }
        } message: {
            Text("Your widget arrangement is replaced by the default one.")
        }
    }

    // MARK: - Header

    /// The title and the mode switch. The popover has no menu of its own:
    /// Edit Widgets, Settings and Quit are the menu bar icon's
    /// right-click menu. Text on the popover's frost is the primary text,
    /// set apart by size.
    private var headerView: some View {
        VStack(alignment: .leading, spacing: FanMacSpacing.space1) {
            HStack(spacing: FanMacSpacing.space4) {
                Text("FanMac")
                    .font(.headline)

                Spacer(minLength: 0)

                if !needsHelper && !viewModel.hasNoFans {
                    FanMacSegmentedPicker(
                        title: "Fan control",
                        options: [(ControlMode.manual, "Manual"), (ControlMode.automatic, "Auto")],
                        selection: Binding(
                            get: { viewModel.controlMode },
                            set: { viewModel.setControlMode($0) }
                        )
                    )
                    // Two short words always fit beside the title.
                    .fixedSize()
                    .help("Manual holds a speed you set; Auto follows the temperature")
                }
            }

            if let controlNote {
                Text(controlNote)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(FanMacTheme.text)
        .padding(.horizontal, FanMacTheme.chromeInset)
        .padding(.vertical, FanMacSpacing.space5)
    }

    /// Who drives the fans, only while macOS does though the helper is ready;
    /// otherwise the switch says it, or the install step below does.
    private var controlNote: String? {
        guard !needsHelper, !viewModel.isControlEnabled else { return nil }
        return FanMacControl.controlSummary(
            hasNoFans: viewModel.hasNoFans,
            helperInstalled: permissions.isHelperInstalled,
            helperReady: !needsHelper,
            controlledByFanMac: viewModel.isControlEnabled,
            mode: viewModel.controlMode == .manual ? .manual : .auto,
            perFan: viewModel.perFanManualControl && viewModel.numberOfFans > 1,
            manualRPM: viewModel.manualSpeed
        )
    }

    // MARK: - Notices

    /// Statuses that need the person; each says what happened and what to do.
    @ViewBuilder
    private var notices: some View {
        if let failure = viewModel.lastFailure {
            NoticeCard(
                title: failure.summary,
                message: failure.recovery,
                tone: FanMacTheme.destructive,
                actionTitle: failure.reason == .refused ? "Try Again" : "Install Helper",
                action: { recover(from: failure) }
            )
        }

        if viewModel.thermalState.limitsPerformance {
            NoticeCard(
                title: "macOS is slowing the Mac to cool it.",
                message: "Thermal pressure is \(viewModel.thermalState.title.lowercased()). \(viewModel.hasNoFans ? "Cooler air lets" : "Faster fans or cooler air let") the CPU and GPU run at full speed again.",
                tone: FanMacTheme.warning
            )
        }
    }

    private func recover(from failure: FanControlFailure) {
        if failure.reason == .refused {
            viewModel.retryFanControl()
        } else {
            reinstallHelper()
        }
    }

    private func reinstallHelper() {
        permissions.installHelper { success, _ in
            if success {
                viewModel.retryFanControl()
            }
        }
    }

    // MARK: - Setup and error states

    private var installHelperView: some View {
        ContentUnavailableView {
            EmptyStateLabel(
                permissions.isHelperOutdated ? "Update the Helper" : "Install the Helper",
                systemImage: "wrench.and.screwdriver"
            )
        } description: {
            if let installError = permissions.installError {
                Text("Couldn’t install the helper. \(installError)")
                    .foregroundStyle(FanMacTheme.destructive)
            }
        } actions: {
            Button(permissions.isHelperOutdated ? "Update Helper" : "Install Helper") {
                // Fan control failed while the helper was missing; retrying
                // clears that failure, which would otherwise ask to install
                // the helper a second time.
                reinstallHelper()
            }
            .fanMacProminentButton()
            .help(permissions.isHelperOutdated
                  ? "This FanMac comes with a newer helper, which fan control needs"
                  : "FanMac changes fan speeds through a helper in /Library/PrivilegedHelperTools, so it doesn’t ask for your password each time")
        }
        .padding(.top, FanMacSpacing.space8)
    }

    private var noAccessView: some View {
        ContentUnavailableView {
            EmptyStateLabel("Can’t Read the Sensors", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Couldn’t open the System Management Controller.")
            if let error = viewModel.lastError {
                Text(error)
                    .font(.caption.monospaced())
            }
        }
        .padding(.top, FanMacSpacing.space8)
    }

    private var noDataView: some View {
        ContentUnavailableView {
            EmptyStateLabel("No Temperature Sensors", systemImage: "thermometer.medium.slash")
        }
        .help("This Mac reports none of the temperature sensors FanMac reads")
        .padding(.top, FanMacSpacing.space8)
    }

    // MARK: - Footer

    private var editingFooter: some View {
        HStack(spacing: FanMacSpacing.space4) {
            Button("Reset Layout…") {
                showingResetDashboardConfirm = true
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("Done") {
                withAnimation(FanMacMotion.panel(reduceMotion: reduceMotion)) { isEditingDashboard = false }
            }
            .fanMacProminentButton()
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, FanMacTheme.chromeInset)
        .padding(.vertical, FanMacSpacing.space5)
    }
}

// MARK: - Empty state label

/// An empty state's title and icon on the popover's frost: the title in the
/// primary text, as the popover's other titles are, and the icon in the
/// secondary text, which reads there, not the system's own fainter glyph.
struct EmptyStateLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title).foregroundStyle(FanMacTheme.text)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(FanMacTheme.secondaryText)
        }
    }
}

// MARK: - Notice card

/// A status that needs the person: the status colour marks the title only.
struct NoticeCard: View {
    let title: String
    let message: String
    let tone: Color
    var actionTitle: String?
    var action: (@MainActor () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: FanMacSpacing.space3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tone)
            Text(message)
                .font(.caption)
                .foregroundStyle(FanMacTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, FanMacSpacing.space1)
            }
        }
        .fanMacCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Compact info row

/// A label and value pair inside a card.
struct CompactInfoItem: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(FanMacTheme.secondaryText)
            Spacer(minLength: FanMacSpacing.space4)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(FanMacTheme.text)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Setting row

/// A slider under its name and value, as every slider in the popover is laid out.
struct SettingRow<Control: View>: View {
    let label: String
    let value: String
    var isApplying = false
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(spacing: FanMacSpacing.space1) {
            HStack(alignment: .firstTextBaseline, spacing: FanMacSpacing.space2) {
                Text(label)
                    .foregroundStyle(FanMacTheme.secondaryText)
                Spacer()
                if isApplying {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(FanMacTheme.text)
            }
            .font(.caption)

            control()
                .controlSize(.small)
                .accessibilityLabel(label)
                .accessibilityValue(value)
        }
    }
}

// MARK: - Power card

/// What the whole Mac draws, so the person can tell load from heat.
struct PowerCardView: View {
    let info: BatteryInfo

    private var statusText: String {
        if info.isCharging { return "Charging" }
        if info.isPluggedIn { return "Plugged in" }
        return "On battery"
    }

    /// The charge, with how long it lasts or takes, or the adapter's rating
    /// while the charge holds.
    private var detailText: String? {
        let charge = "\(info.percentage)%"
        if info.isCharging {
            return info.formattedTimeRemaining.map { "\(charge), full in \($0)" } ?? charge
        }
        if info.isPluggedIn {
            return info.adapterWatts.map { "\($0) W adapter" }
        }
        return info.formattedTimeRemaining.map { "\(charge), \($0) left" } ?? charge
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FanMacSpacing.space4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Power").fanMacCardTitle()
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(FanMacTheme.secondaryText)
            }

            HStack(alignment: .firstTextBaseline, spacing: FanMacSpacing.space1) {
                if let power = info.systemPowerWatts {
                    Text(power, format: .number.precision(.fractionLength(power < 10 ? 1 : 0)))
                        .font(.title.weight(.semibold))
                        .monospacedDigit()
                    Text("W")
                        .font(.title3)
                } else {
                    Text("–")
                        .font(.title.weight(.semibold))
                }
            }
            .foregroundStyle(FanMacTheme.text)

            Spacer(minLength: 0)

            if let detailText {
                Text(detailText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(FanMacTheme.secondaryText)
            }
        }
        .fanMacCard()
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    PopoverView(viewModel: FanControlViewModel())
}
