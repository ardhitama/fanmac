//
//  Capture.swift
//  FanMac UI capture
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Shows FanMac's popover, Settings or widget gallery in one fixed state and
//  saves a screenshot of it. scripts/capture-ui.sh builds this with the
//  app's sources, with the helper path pointing nowhere, and runs it once
//  per state, so every state can be looked at side by side.
//

import AppKit
import SwiftUI

@main
struct Capture {
    /// Every state scripts/capture-ui.sh captures, in its order.
    static let scenarios = [
        "auto", "manual", "perfan", "onefan", "manyfans", "manyfans-perfan", "macos", "hot",
        "thermal", "failure", "helper", "outdated", "nofans", "desktop", "desktop-widgets", "widgets",
        "edit", "edit-manual", "edit-nofans", "gallery", "settings", "settings-nofans",
        "settings-nofans-fanspeed", "settings-desktop", "license",
    ]

    static func main() {
        let args = CommandLine.arguments
        if args.count == 2, args[1] == "--list" {
            print(scenarios.joined(separator: "\n"))
            exit(0)
        }
        guard args.count == 3, scenarios.contains(args[1]) else {
            FileHandle.standardError.write(Data("usage: fanmac-ui-capture <\(scenarios.joined(separator: "|"))> <out.png>\n".utf8))
            exit(2)
        }
        let scenario = args[1]
        let out = args[2]

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        FanMacTheme.applyToApplication()

        // Start from FanMac's defaults each run. An unbundled program's
        // defaults domain is its name (fanmac-ui-capture, which the script
        // deletes afterwards), so this never touches the app's settings.
        guard Bundle.main.bundleIdentifier == nil else {
            FileHandle.standardError.write(Data("capture: run the bare program, not inside an app bundle\n".utf8))
            exit(2)
        }
        UserDefaults.standard.removeObject(forKey: "dashboardLayout")
        UserDefaults.standard.removeObject(forKey: "statusBarDisplayMode")
        // Choices this Mac can't show, as a moved or misread Mac leaves them.
        if scenario == "settings-nofans-fanspeed" {
            UserDefaults.standard.set("fanSpeedPercentage", forKey: "statusBarDisplayMode")
        } else if scenario == "settings-desktop" {
            UserDefaults.standard.set("power", forKey: "statusBarDisplayMode")
        }

        let monitor = SystemMonitor()
        let viewModel = FanControlViewModel(systemMonitor: monitor)
        let fanless = scenario.contains("nofans")
        let hasBattery = !scenario.contains("desktop")
        let fanCount = scenario == "onefan" ? 1 : scenario.hasPrefix("manyfans") ? 4 : 2

        // The view model mirrors the monitor a run loop turn later, so this
        // runs again just before each capture.
        func applyFixture() {
            viewModel.hasAccess = true
            viewModel.isMonitoring = true
            viewModel.cpuTemperature = scenario == "hot" ? 92 : 68
            viewModel.gpuTemperature = 52
            viewModel.numberOfFans = fanCount
            viewModel.fanMinSpeeds = Array(repeating: 2317, count: fanCount)
            viewModel.fanMaxSpeeds = Array(repeating: 7826, count: fanCount)
            viewModel.fanSpeeds = Array([3416, 3496, 2984, 3120].prefix(fanCount))
            viewModel.currentFanSpeed = 3456
            viewModel.autoThreshold = 55
            viewModel.autoMaxSpeed = 6000
            viewModel.autoAggressiveness = 1.0
            viewModel.isControlEnabled = true
            viewModel.appliedTargets = Array(repeating: 3454, count: viewModel.numberOfFans)
            viewModel.manualSpeed = 3000
            viewModel.manualSpeeds = Array([3000, 3400, 2800, 3200].prefix(fanCount))
            viewModel.lastFailure = nil
            viewModel.thermalState = scenario == "thermal" ? .serious : .nominal
            switch scenario {
            case "manual", "edit-manual": viewModel.controlMode = .manual
            case "failure":
                viewModel.controlMode = .manual
                viewModel.lastFailure = FanControlFailure(operation: .setSpeed, reason: .refused)
            case "perfan", "manyfans-perfan": viewModel.controlMode = .manual; viewModel.perFanManualControl = true
            case "macos": viewModel.controlMode = .automatic; viewModel.isControlEnabled = false
            default: viewModel.controlMode = .automatic
            }
            if fanless {
                // As SystemMonitor leaves them on a Mac without fans.
                monitor.hasNoFans = true
                viewModel.hasNoFans = true
                viewModel.numberOfFans = 0
                viewModel.fanMinSpeeds = []; viewModel.fanMaxSpeeds = []; viewModel.fanSpeeds = []
                viewModel.currentFanSpeed = 0; viewModel.appliedTargets = []; viewModel.manualSpeeds = []
                viewModel.isControlEnabled = false
            }
            // Without fans the helper isn't needed, so it stays uninstalled
            // there: no prompt for it may appear.
            PermissionsManager.shared.isHelperInstalled = scenario != "helper" && !fanless
            PermissionsManager.shared.isHelperOutdated = scenario == "outdated"

            // The popover reads the real battery when it opens; this replaces it.
            let battery = BatteryMonitor.shared
            battery.hasBattery = hasBattery
            battery.batteryInfo = hasBattery ? BatteryInfo(
                percentage: 82, cycleCount: 143, health: 92, temperature: 31.4, voltage: 12.6,
                amperage: -1105, timeRemaining: 312, designCapacity: 6249, maxCapacity: 5749,
                currentCapacity: 4714, systemLoadWatts: 13.9
            ) : BatteryInfo()
        }
        applyFixture()

        let store = DashboardStore.shared
        store.resetToDefaults(hasBattery: hasBattery || scenario == "desktop-widgets")
        if scenario == "widgets" || scenario == "desktop-widgets" {
            for kind in [DashboardWidgetKind.batteryInfo, .systemInfo]
            where kind.isAvailable(hasBattery: hasBattery, hasFans: true) {
                // As Add Row and the widget gallery place it.
                store.addRow(columns: 2)
                guard store.addWidget(kind, toRow: store.layout.rows.last!.id) else {
                    FileHandle.standardError.write(Data("capture: couldn't place \(kind)\n".utf8))
                    exit(1)
                }
            }
        }

        if scenario.hasPrefix("settings") {
            SettingsWindowController.shared.bind(viewModel: viewModel)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                applyFixture()
                SettingsWindowController.shared.openSettings()
                captureWindow(after: 2.0, to: out) {
                    NSApp.windows.first { $0.title == "FanMac Settings" }
                }
            }
            app.run()
        }

        if scenario == "license" {
            // As Settings presents it. capture-ui.sh puts LICENSE beside
            // this program, where Bundle.main finds it.
            let host = NSWindow(
                contentRect: NSRect(x: 600, y: 300, width: 640, height: 520),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            host.contentViewController = NSHostingController(rootView: Color.clear.frame(width: 640, height: 520).sheet(isPresented: .constant(true)) {
                LegalDocumentSheet(document: .license)
            })
            host.title = "FanMac UI capture"
            host.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            captureWindow(after: 2.0, to: out) { host.attachedSheet }
            app.run()
        }

        if scenario == "gallery" {
            // Presented as the dashboard presents it: a sheet.
            let host = NSWindow(
                contentRect: NSRect(x: 600, y: 300, width: 400, height: 560),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            host.contentViewController = NSHostingController(rootView: Color.clear.frame(width: 400, height: 560).sheet(isPresented: .constant(true)) {
                WidgetGallerySheet(store: store, targetRowID: store.layout.rows.first!.id, hasBattery: true, hasFans: true)
            })
            host.title = "FanMac UI capture"
            host.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            captureWindow(after: 2.0, to: out) { host.attachedSheet }
            app.run()
        }

        // The popover hangs from a small window, as from the menu bar icon.
        let anchor = NSWindow(
            contentRect: NSRect(x: 700, y: 1000, width: 240, height: 30),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        anchor.title = "FanMac UI capture"
        anchor.makeKeyAndOrderFront(nil)
        app.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            applyFixture()
            // The edit states show the popover as the menu's Edit Widgets opens it.
            let controller = NSHostingController(
                rootView: PopoverView(viewModel: viewModel, editingWidgets: scenario.hasPrefix("edit"))
            )
            controller.sizingOptions = [.preferredContentSize]
            let popover = NSPopover()
            // Not transient: the app that had the focus can take it back
            // while this one starts, and a transient popover would close.
            popover.behavior = .applicationDefined
            // As StatusBarManager's: the frost reaches under the arrow.
            popover.hasFullSizeContent = true
            popover.contentViewController = controller
            popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
            // A clicked popover is key, and key-only colours show only then.
            NSApp.activate(ignoringOtherApps: true)
            controller.view.window?.makeKey()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                applyFixture()
                controller.view.window?.makeKey()
                captureWindow(after: 1.2, to: out) { controller.view.window }
            }
        }
        app.run()
    }

    /// Saves the window's screenshot, without its shadow, and quits. Waits
    /// for the window to be key first, since key-only colours show only then.
    private static func captureWindow(after delay: TimeInterval, to out: String, attempt: Int = 1,
                                      _ findWindow: @escaping () -> NSWindow?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let window = findWindow() else {
                FileHandle.standardError.write(Data("capture: the window didn't open\n".utf8))
                exit(1)
            }
            if !window.isKeyWindow {
                guard attempt < 5 else {
                    FileHandle.standardError.write(Data("capture: the window never became key; another app kept the focus\n".utf8))
                    exit(1)
                }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKey()
                captureWindow(after: 0.5, to: out, attempt: attempt + 1, findWindow)
                return
            }
            let screencapture = Process()
            screencapture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            screencapture.arguments = ["-x", "-o", "-l", String(window.windowNumber), out]
            do {
                try screencapture.run()
                screencapture.waitUntilExit()
            } catch {
                FileHandle.standardError.write(Data("capture: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
            exit(screencapture.terminationStatus == 0 && FileManager.default.fileExists(atPath: out) ? 0 : 1)
        }
    }
}
