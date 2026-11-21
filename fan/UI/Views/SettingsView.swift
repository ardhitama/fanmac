//
//  SettingsView.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//

import SwiftUI

// MARK: - Settings window

/// One grouped form, which the system draws on its own background.
struct SettingsWindowView: View {
    @ObservedObject var viewModel: FanControlViewModel
    @ObservedObject private var battery = BatteryMonitor.shared

    @State private var launchAtLogin = LaunchAtLoginManager.shared.isRegistered
    @State private var loginItemNeedsApproval = LaunchAtLoginManager.shared.needsApproval
    @State private var loginItemError: String?
    @State private var statusBarDisplayMode = UserDefaults.standard.string(forKey: "statusBarDisplayMode") ?? "temperature"
    @State private var monitoringInterval: Double = 2
    @State private var showMenuBarIcon = !MenuBarIconPreferences.isHidden
    @State private var commandState = CommandLineTool.state
    @State private var commandError: String?
    @State private var shownDocument: LegalNotices.Document?

    var body: some View {
        Form {
            generalSection
            commandLineSection
            menuBarSection
            monitoringSection
            alertsSection
            aboutSection
        }
        .formStyle(.grouped)
        .sheet(item: $shownDocument) { LegalDocumentSheet(document: $0) }
        .tint(FanMacTheme.accent)
        // Narrower, the Menu Bar choices no longer fit as a segmented control.
        .frame(width: 500)
        // The window fits the form and follows it as rows come and go; the
        // form scrolls only on a screen too short for it. A fixed 640 pt cut
        // the last section's margin short wherever the Mac has fans.
        .frame(maxHeight: (NSScreen.main?.visibleFrame.height ?? 800) - 80)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            showMenuBarIcon = !MenuBarIconPreferences.isHidden
            monitoringInterval = viewModel.monitoringInterval
            refreshSystemState()
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        // The login item and the command's link can change outside FanMac,
        // in System Settings or with brew, while this window stays open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshSystemState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuBarIconVisibilityChanged)) { notification in
            if let hidden = notification.object as? Bool {
                showMenuBarIcon = !hidden
            }
        }
    }

    // MARK: Sections

    private var generalSection: some View {
        Section("General") {
            Toggle(isOn: $showMenuBarIcon) {
                Text("Show menu bar icon")
                if !showMenuBarIcon {
                    Text("Open FanMac from Applications to see this window again.")
                }
            }
            .onChange(of: showMenuBarIcon) { _, visible in
                AppDelegate.shared?.setMenuBarIconVisible(visible)
            }

            Toggle(isOn: $launchAtLogin) {
                Text("Open at login")
                if loginItemNeedsApproval {
                    Text("macOS opens FanMac at login once you allow it in Login Items.")
                }
            }
            .onChange(of: launchAtLogin) { _, enabled in
                let manager = LaunchAtLoginManager.shared
                // Refreshing from macOS also lands here; only a change by the
                // person needs registering.
                guard enabled != manager.isRegistered else { return }
                manager.setRegistered(enabled)
                loginItemError = manager.lastError.map { "Couldn’t change the login item. \($0)" }
                refreshSystemState()
            }
            if loginItemNeedsApproval {
                Button("Open Login Items…") {
                    LaunchAtLoginManager.shared.openLoginItemsSettings()
                }
            }
            if let loginItemError {
                Text(loginItemError)
                    .foregroundStyle(FanMacTheme.destructive)
            }
        }
    }

    /// Reads back what macOS reports, which the person can change in System Settings.
    private func refreshSystemState() {
        let manager = LaunchAtLoginManager.shared
        launchAtLogin = manager.isRegistered
        loginItemNeedsApproval = manager.needsApproval
        commandState = CommandLineTool.state
    }

    private var commandLineSection: some View {
        Section {
            LabeledContent {
                switch commandState {
                case .installed:
                    Text("Installed")
                        .foregroundStyle(FanMacTheme.secondaryText)
                case .notInstalled, .otherFile:
                    Button(commandState == .otherFile ? "Replace…" : "Install…") {
                        commandError = nil
                        CommandLineTool.install { error in
                            commandError = error.map { "Couldn’t install the command. \($0)" }
                            commandState = CommandLineTool.state
                        }
                    }
                case .unavailable:
                    Text("Not in this build")
                        .foregroundStyle(FanMacTheme.secondaryText)
                }
            } label: {
                Text("fanmac command")
                if commandState == .otherFile {
                    Text("Another file is at \(CommandLineTool.linkPath).")
                }
            }
            .help("Watch and change the fans from Terminal")
            if let commandError {
                Text(commandError)
                    .foregroundStyle(FanMacTheme.destructive)
            }
        } header: {
            Text("Command Line")
        }
    }

    private var menuBarSection: some View {
        Section {
            LabeledContent("Show next to the icon") {
                FanMacSegmentedPicker(
                    title: "Show next to the icon",
                    options: displayModeOptions,
                    selection: shownDisplayMode
                )
            }
            .help(displayModeHelp)
            .onChange(of: statusBarDisplayMode) { _, tag in
                UserDefaults.standard.set(tag, forKey: "statusBarDisplayMode")
                viewModel.statusBarDisplayMode = tag
                NotificationCenter.default.post(
                    name: NSNotification.Name("StatusBarDisplayModeChanged"),
                    object: tag
                )
            }
        } header: {
            Text("Menu Bar")
        }
    }

    /// Power needs a battery, which reports the Mac's draw; Fan Speed needs fans.
    private var displayModeOptions: [(value: String, label: String)] {
        var options = [("none", "Nothing"), ("temperature", "Temperature")]
        if battery.hasBattery { options.append(("power", "Power")) }
        if !viewModel.hasNoFans { options.append(("fanSpeedPercentage", "Fan Speed")) }
        return options
    }

    private var displayModeHelp: String {
        var parts: [String] = []
        if battery.hasBattery { parts.append("Power shows what the whole Mac draws") }
        if !viewModel.hasNoFans { parts.append("Fan Speed shows where the fans run within their range, as a percentage") }
        return parts.joined(separator: "; ")
    }

    /// A choice this Mac can't show shows as the one the menu bar uses in its
    /// place, such as Fan Speed for Power on a Mac without a battery.
    private var shownDisplayMode: Binding<String> {
        Binding(
            get: {
                StatusBarManager.effectiveDisplayMode(
                    statusBarDisplayMode, hasBattery: battery.hasBattery, hasFans: !viewModel.hasNoFans
                )
            },
            set: { statusBarDisplayMode = $0 }
        )
    }

    private var monitoringSection: some View {
        Section("Monitoring") {
            LabeledContent {
                Slider(
                    value: $monitoringInterval.snapped(to: 0.5, in: SystemMonitor.monitoringIntervalRange),
                    in: SystemMonitor.monitoringIntervalRange
                )
                    .labelsHidden()
                    .onChange(of: monitoringInterval) { _, value in
                        viewModel.setMonitoringInterval(value)
                    }
            } label: {
                Text("Read sensors every")
                Text(monitoringInterval.formatted(.number.precision(.fractionLength(1))) + " seconds")
            }

            if !viewModel.hasNoFans {
                Toggle(isOn: Binding(
                    get: { viewModel.autoSwitchMode },
                    set: { viewModel.setAutoSwitchMode($0) }
                )) {
                    Text("Switch to Auto when hot")
                }
                .help("Switches to Auto when the CPU passes the alert temperature")
            }
        }
    }

    private var alertsSection: some View {
        Section("Alerts") {
            Toggle(isOn: Binding(
                get: { viewModel.enableNotifications },
                set: { viewModel.setEnableNotifications($0) }
            )) {
                Text("Alert when the CPU is hot")
            }

            LabeledContent {
                Slider(
                    value: Binding(
                        get: { viewModel.highTempAlert },
                        set: { viewModel.setHighTempAlert($0) }
                    ).snapped(to: 1, in: 70...95),
                    in: 70...95
                )
                .labelsHidden()
            } label: {
                Text("Alert temperature")
                Text("\(Int(viewModel.highTempAlert)) °C")
            }
        }
    }

    /// The notices the GPL asks FanMac to show: copyright, no warranty, and
    /// where to read the license.
    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: LegalNotices.version())
            VStack(alignment: .leading, spacing: FanMacSpacing.space2) {
                Text(LegalNotices.copyright)
                Text("FanMac comes with absolutely no warranty. It’s free software: you may share and change it under the GNU General Public License, version 3 or later. The license doesn’t cover the FanMac name or icon.")
                    .foregroundStyle(FanMacTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                ForEach(LegalNotices.Document.allCases) { document in
                    Button(document == .license ? "License…" : "Notices…") { shownDocument = document }
                }
                Spacer()
                Link("Source Code", destination: LegalNotices.sourceCode)
            }
        }
    }
}

/// A notice file from the app's Resources, read-only. Opening it in an
/// editor instead could change the file inside the signed app.
struct LegalDocumentSheet: View {
    let document: LegalNotices.Document
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(document.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], FanMacSpacing.space6)
            ScrollView {
                Text(document.text() ?? "This copy of FanMac is missing its \(document.rawValue) file. Read it at \(LegalNotices.sourceCode.absoluteString).")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(FanMacSpacing.space6)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .fanMacProminentButton()
            }
            .padding(FanMacSpacing.space6)
        }
        .frame(width: 640, height: 520)
    }
}
