//
//  FanMacApp.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Menu bar app entry point
//

import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var statusBarManager: StatusBarManager?
    var viewModel: FanControlViewModel?
    private var controlServer: ControlServer?
    private var iconUpdateTimer: Timer?
    private var displayModeObserver: NSObjectProtocol?
    private var menuBarVisibilityObserver: NSObjectProtocol?
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var isHandingBackFans = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self
        installTerminationSignalHandler()
        if handOffToRunningCopy() { return }
        carryOverLegacyIdentity()
        NSApp.setActivationPolicy(.accessory)
        FanMacTheme.applyToApplication()
        installSettingsKeyboardShortcut()
        setupApplication()
    }

    /// Another FanMac already runs: a second copy of the app, or `open -n`.
    /// Two would fight over the fans, and this one's quit would hand back
    /// fans the other believes it holds. Reopen the running one, as opening
    /// it again would, and quit before touching the fans.
    private func handOffToRunningCopy() -> Bool {
        guard let existing = FanMacControl.connect() else { return false }
        close(existing)
        print("FanMac: another copy is already running; quitting")
        let me = ProcessInfo.processInfo.processIdentifier
        let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0.processIdentifier != me }
        guard let url = other?.bundleURL else {
            NSApp.terminate(nil)
            return true
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    /// Replacing the previous app (bundle identifier tests.fan): bring the settings over
    /// before anything reads them, and open at login. macOS doesn't say
    /// whether the old FanMac opened at login, so it does now; macOS
    /// announces the new login item, and Settings turns it off.
    private func carryOverLegacyIdentity() {
        guard let domain = Bundle.main.bundleIdentifier,
              domain != LegacyIdentity.bundleIdentifier,
              LegacyIdentity.carryOverSettings(into: domain) else { return }
        print("FanMac: carried the settings over from \(LegacyIdentity.bundleIdentifier)")
        let loginItem = LaunchAtLoginManager.shared
        if !loginItem.isRegistered {
            loginItem.setRegistered(true)
        }
    }

    private func installSettingsKeyboardShortcut() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "," else {
                return event
            }
            self?.openSettings()
            return nil
        }
    }

    private func setupApplication() {
        let viewModel = FanControlViewModel()
        self.viewModel = viewModel
        SettingsWindowController.shared.bind(viewModel: viewModel)

        let controlServer = ControlServer(viewModel: viewModel)
        controlServer.start()
        self.controlServer = controlServer

        let statusBarManager = StatusBarManager()
        self.statusBarManager = statusBarManager
        wireStatusBarActions(statusBarManager)

        let initialMode = UserDefaults.standard.string(forKey: "statusBarDisplayMode") ?? "temperature"
        statusBarManager.setDisplayMode(initialMode)

        displayModeObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("StatusBarDisplayModeChanged"),
            object: nil,
            queue: .main
        ) { [weak statusBarManager] notification in
            if let mode = notification.object as? String {
                statusBarManager?.setDisplayMode(mode)
            }
        }

        menuBarVisibilityObserver = NotificationCenter.default.addObserver(
            forName: .menuBarIconVisibilityChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let shown = notification.object as? Bool == false
            // queue: .main delivers on the main thread.
            MainActor.assumeIsolated {
                if shown { self?.attachPopoverContent() }
            }
        }

        statusBarManager.setupStatusBar()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.attachPopoverContent()
            self?.initializeMonitoring()

            if MenuBarIconPreferences.isHidden {
                self?.presentSettingsForHiddenIcon(reason: "launch")
            }
        }
    }

    private func wireStatusBarActions(_ manager: StatusBarManager) {
        manager.canEditWidgets = { [weak self] in
            guard let viewModel = self?.viewModel else { return false }
            return PopoverView.showsWidgets(viewModel, permissions: .shared)
        }
        manager.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        manager.onHideIcon = { [weak self] in
            self?.hideMenuBarIconFromUserAction()
        }
        manager.onQuitApp = {
            NSApp.terminate(nil)
        }
    }

    private func attachPopoverContent() {
        guard let statusBarManager, let viewModel else { return }
        // Provide a factory, not a live view. The popover builds its content on
        // open and releases it on close (see StatusBarManager), so the dashboard
        // gauges and glass panels never render while the popover is hidden.
        statusBarManager.popoverContentProvider = { [weak viewModel, weak statusBarManager] editingWidgets in
            guard let viewModel, let statusBarManager else { return NSViewController() }
            let controller = WholePointHostingController(
                rootView: PopoverView(viewModel: viewModel, statusBarManager: statusBarManager,
                                      editingWidgets: editingWidgets)
            )
            // The popover takes the view's ideal size, so it fits its cards and
            // resizes as they change instead of leaving an empty band.
            controller.sizingOptions = [.preferredContentSize]
            return controller
        }
    }

    func openSettings() {
        statusBarManager?.closePopover()
        SettingsWindowController.shared.openSettings()
    }

    private func hideMenuBarIconFromUserAction() {
        statusBarManager?.hideMenuBarIcon()
    }

    func setMenuBarIconVisible(_ visible: Bool) {
        guard let statusBarManager else { return }
        if visible {
            statusBarManager.showMenuBarIcon()
            attachPopoverContent()
        } else {
            statusBarManager.hideMenuBarIcon()
        }
    }

    func presentSettingsForHiddenIcon(reason: String) {
        guard MenuBarIconPreferences.isHidden else { return }
        print("FanMac: presenting settings (icon hidden, reason=\(reason))")
        openSettings()
    }

    private func initializeMonitoring() {
        guard let viewModel else { return }
        viewModel.startMonitoring()
        startIconUpdateTimer()
    }

    private func startIconUpdateTimer() {
        iconUpdateTimer?.invalidate()
        iconUpdateTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            // The timer runs on the main run loop.
            MainActor.assumeIsolated { self?.updateStatusBarIcon() }
        }
        RunLoop.current.add(iconUpdateTimer!, forMode: .common)
        updateStatusBarIcon()
    }

    private func updateStatusBarIcon() {
        guard let viewModel,
              let statusBarManager,
              statusBarManager.isStatusItemVisible else { return }

        let maxTemp = viewModel.getMaxTemperature()
        statusBarManager.updateIcon(
            fanSpeeds: viewModel.fanSpeeds,
            fanMinSpeeds: viewModel.fanMinSpeeds,
            fanMaxSpeeds: viewModel.fanMaxSpeeds,
            temperature: maxTemp > 0 ? maxTemp : nil
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if MenuBarIconPreferences.isHidden {
            presentSettingsForHiddenIcon(reason: "reopen")
        }
        return true
    }

    /// Every way of quitting reaches this: Quit, logging out, `brew upgrade`
    /// and `brew uninstall`, AppleScript, SIGTERM, SIGINT and SIGHUP. FanMac hands the fans
    /// back to macOS before it exits; otherwise they would stay at its last
    /// speed with the thermal manager held off.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel else { return .terminateNow }
        // Already handing back: keep waiting for that reply.
        guard !isHandingBackFans else { return .terminateLater }
        isHandingBackFans = true
        viewModel.handBackFansForQuit {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Turns SIGTERM (`kill`, launchd), SIGINT (Control-C) and SIGHUP (a
    /// closed terminal) into a normal quit so they hand the fans back too.
    /// SIGKILL and crashes can't be caught; FanReleaseWatchdog covers those.
    private func installTerminationSignalHandler() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            // A no-op handler keeps the signal from killing FanMac before the
            // source below sees it. Not SIG_IGN: an ignored signal stays
            // ignored in the sudo and helper processes FanMac starts, so
            // quitting couldn't stop a speed write still running. A handler
            // resets to the default on exec.
            signal(signalNumber) { _ in }
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                // A second terminate while the hand-back is waiting makes
                // AppKit exit at once, so ignore repeats.
                guard let self, !self.isHandingBackFans else { return }
                // Quit from the run loop rather than inside this main-queue block.
                NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controlServer?.stop()
        iconUpdateTimer?.invalidate()
        viewModel?.stopMonitoring()

        if let observer = displayModeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = menuBarVisibilityObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct FanMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            Text("FanMac")
                .frame(width: 0, height: 0)
                .hidden()
        }
    }
}
