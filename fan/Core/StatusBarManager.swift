//
//  StatusBarManager.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Static status bar icon with dynamic display text (temp / power / fan load)
//

import AppKit
import SwiftUI
import Combine

class StatusBarManager: ObservableObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var refreshTimer: Timer?
    /// Builds the popover's SwiftUI content on demand, editing its widgets
    /// when asked. Kept as a factory (not a retained view) so the heavy
    /// hierarchy — dashboard gauges, Metal glass panels, the spinning-fan
    /// animation — exists only while the popover is open.
    var popoverContentProvider: ((_ editingWidgets: Bool) -> NSViewController)?
    private var popoverCloseObserver: PopoverCloseObserver?
    /// Closes the popover on a click in another app, while it's open.
    private var outsideClicks: Any?
    /// The app icon's pinwheel, a template image in the asset catalog
    /// (`scripts/generate-app-icon.py` draws it), so the system tints it to
    /// match every other menu-bar glyph. It is intentionally static: a
    /// per-frame redraw of the status item forces AppKit (and any menu-bar
    /// manager observing it) to recomposite continuously, pegging a core even
    /// while the item is hidden. Information lives in the title text, not motion.
    private let fanIcon = NSImage(resource: .menuBarIcon)
    /// Latest sampled RPM per fan (from SMC).
    private var cachedFanSpeeds: [Int] = []
    private var cachedFanMinRPM: [Int] = []
    private var cachedFanMaxRPM: [Int] = []
    private var displayFanSpeedMax: Int = 0
    private var currentTemperature: Double?
    private var displayMode: String = "temperature"

    /// Whether the menu's **Edit Widgets** is available: the popover shows
    /// its widgets only once the helper is ready and the sensors read.
    var canEditWidgets: () -> Bool = { true }
    /// Called when the user chooses **Settings…** from the status item menu.
    var onOpenSettings: (() -> Void)?
    /// Called when the user chooses **Hide Menu Bar Icon** from the status item menu.
    var onHideIcon: (() -> Void)?
    /// Called when the user chooses **Quit FanMac** from the status item menu.
    var onQuitApp: (() -> Void)?

    var isStatusItemVisible: Bool { statusItem != nil }
    
    func setupStatusBar() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if MenuBarIconPreferences.isHidden {
                self.ensurePopoverExists()
                return
            }
            self.createStatusItemIfNeeded()
            self.startRefreshTimer()
        }
    }

    private func startRefreshTimer() {
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshDisplay()
        }
        RunLoop.current.add(refreshTimer!, forMode: .common)
    }

    private func ensurePopoverExists() {
        if popover == nil {
            let popover = NSPopover()
            popover.behavior = .transient
            // The content reaches under the arrow, so the popover's frost
            // colours the arrow as it does the rest.
            popover.hasFullSizeContent = true
            // The size comes from the content's preferredContentSize.
            // Release the SwiftUI hierarchy (and its Metal pipeline / animations)
            // the moment the popover closes — NSPopover otherwise retains its
            // contentViewController and keeps rendering it in the background.
            let observer = PopoverCloseObserver { [weak self] in
                guard let self else { return }
                self.popover?.contentViewController = nil
                self.stopWatchingOutsideClicks()
            }
            popover.delegate = observer
            self.popoverCloseObserver = observer
            self.popover = popover
        }
    }

    private func createStatusItemIfNeeded() {
        guard statusItem == nil else { return }
        createStatusItem()
    }
    
    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        guard let button = statusItem?.button else {
            return
        }
        
        // The title stays empty until the first reading; updateDisplay sets it.
        button.image = fanIcon
        button.imagePosition = .imageOnly
        button.toolTip = "FanMac"
        button.setAccessibilityLabel("FanMac")

        // A click opens the popover; a right or Control-click, the menu.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.action = #selector(statusBarButtonClicked(_:))
        button.target = self
        
        ensurePopoverExists()
    }

    /// Removes the menu bar icon while keeping monitoring and popover state alive.
    func hideMenuBarIcon(persist: Bool = true) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.closePopover()

            if persist {
                MenuBarIconPreferences.isHidden = true
            }

            if let item = self.statusItem {
                NSStatusBar.system.removeStatusItem(item)
                self.statusItem = nil
            }

            print("StatusBar: Menu bar icon hidden")
        }
    }

    /// Restores the menu bar icon after it was hidden.
    func showMenuBarIcon(persist: Bool = true) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if persist {
                MenuBarIconPreferences.isHidden = false
            }

            self.createStatusItemIfNeeded()
            self.startRefreshTimer()
            self.setDisplayMode(self.displayMode)
            self.updateDisplay()

            print("StatusBar: Menu bar icon shown")
        }
    }
    
    func updateIcon(fanSpeeds: [Int], fanMinSpeeds: [Int], fanMaxSpeeds: [Int], temperature: Double?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.cachedFanSpeeds = fanSpeeds
            self.cachedFanMinRPM = fanMinSpeeds
            self.cachedFanMaxRPM = fanMaxSpeeds
            self.displayFanSpeedMax = fanSpeeds.max() ?? 0
            self.currentTemperature = temperature
            self.updateDisplay()
        }
    }

    /// Mean utilization in \([0,100]\) across fans using each fan's SMC min/max span.
    private func averageFanLoadPercent() -> Int {
        guard !cachedFanSpeeds.isEmpty else { return 0 }
        var sum = 0.0
        var count = 0
        for i in 0..<cachedFanSpeeds.count {
            let mn = i < cachedFanMinRPM.count ? cachedFanMinRPM[i] : cachedFanMinRPM.first ?? FanRPMBounds.fallbackMinWhenSMCUnreadable
            guard i < cachedFanMaxRPM.count else { continue }
            let mx = cachedFanMaxRPM[i]
            guard mx > mn else { continue }
            let p = Double(cachedFanSpeeds[i] - mn) / Double(mx - mn)
            sum += min(1.0, max(0.0, p))
            count += 1
        }
        guard count > 0 else {
            let ref = cachedFanMaxRPM.max() ?? FanRPMBounds.fallbackMaxWhenSMCUnreadable
            guard ref > 0 else { return 0 }
            return min(100, max(0, Int(round(Double(displayFanSpeedMax) / Double(ref) * 100))))
        }
        return Int(min(100, max(0, round(sum / Double(count) * 100))))
    }

    func setDisplayMode(_ mode: String) {
        DispatchQueue.main.async { [weak self] in
            self?.displayMode = mode
            self?.updateDisplay()
        }
    }
    
    /// Power changes between fan readings, and only the open popover reads
    /// the battery otherwise, so Power in the menu bar reads it here.
    func refreshDisplay() {
        if displayMode == "power" {
            BatteryMonitor.shared.updateBatteryInfo()
        }
        updateDisplay()
    }

    private func updateDisplay() {
        guard let button = statusItem?.button else { return }
        
        let text = getDisplayText()
        // With no text, the icon stands alone, without a title's padding.
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeft
        // VoiceOver names the app, then reads what the title shows.
        button.setAccessibilityLabel(text.isEmpty ? "FanMac" : "FanMac, \(text)")
        if text.isEmpty {
            button.title = ""
        } else {
            // A compact font keeps the item short.
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular)
            ]
            button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
        }
    }
    
    private func getDisplayText() -> String {
        let battery = BatteryMonitor.shared
        return Self.displayText(
            mode: displayMode,
            temperature: currentTemperature,
            battery: battery.hasBattery ? battery.batteryInfo : nil,
            // No speeds yet, or a Mac without fans.
            fanLoadPercent: cachedFanSpeeds.isEmpty ? nil : averageFanLoadPercent()
        )
    }

    /// The menu bar choice in effect. A Mac without fans has no Fan Speed, and
    /// one without a battery no power reading, so those choices show what the
    /// menu bar shows in their place. Settings shows the same choice.
    static func effectiveDisplayMode(_ stored: String, hasBattery: Bool, hasFans: Bool) -> String {
        switch stored {
        case "fanSpeedPercentage" where !hasFans:
            return "temperature"
        case "power" where !hasBattery:
            return hasFans ? "fanSpeedPercentage" : "temperature"
        default:
            return stored
        }
    }

    /// The text next to the icon. `battery` is nil on a Mac without one;
    /// `fanLoadPercent` is nil until the fans are read, and on a Mac without fans.
    static func displayText(mode: String, temperature: Double?, battery: BatteryInfo?, fanLoadPercent: Int?) -> String {
        let temperatureText = temperature.map { String(format: "%.0f°", $0) } ?? "--°"
        switch effectiveDisplayMode(mode, hasBattery: battery != nil, hasFans: fanLoadPercent != nil) {
        case "none":
            return ""
        case "power":
            // What the whole Mac draws, as the popover's Power card shows it.
            return battery?.systemPowerWatts.map { String(format: "%.1fW", $0) } ?? "--W"
        case "fanSpeedPercentage":
            return fanLoadPercent.map { "\($0)%" } ?? temperatureText
        default:
            return temperatureText
        }
    }

    @objc private func statusBarButtonClicked(_ sender: NSButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    /// The item's menu, on a right or Control-click: Quit FanMac last on ⌘Q,
    /// as other menu bar items have it. The popover has no menu of its own;
    /// its actions are here.
    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let editItem = NSMenuItem(
            title: "Edit Widgets",
            action: #selector(contextMenuEditWidgets),
            keyEquivalent: ""
        )
        editItem.target = self
        editItem.isEnabled = canEditWidgets()
        menu.addItem(editItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(contextMenuOpenSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let hideItem = NSMenuItem(
            title: "Hide Menu Bar Icon",
            action: #selector(contextMenuHideIcon),
            keyEquivalent: ""
        )
        hideItem.target = self
        menu.addItem(hideItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit FanMac",
            action: #selector(contextMenuQuitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func showMenu() {
        closePopover()
        // Shown as the item's own menu, so the menu bar places it and shows
        // the item pressed, as it does every other item's.
        guard let statusItem else { return }
        statusItem.menu = contextMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func contextMenuEditWidgets() {
        showPopover(editingWidgets: true)
    }

    @objc private func contextMenuOpenSettings() {
        onOpenSettings?()
    }

    @objc private func contextMenuHideIcon() {
        onHideIcon?()
    }

    @objc private func contextMenuQuitApp() {
        onQuitApp?()
    }

    private func togglePopover() {
        if popover?.isShown == true {
            closePopover()
        } else {
            showPopover(editingWidgets: false)
        }
    }

    private func showPopover(editingWidgets: Bool) {
        guard let button = statusItem?.button, let popover, !popover.isShown else { return }
        // Content is built on open and released on close, so the SwiftUI
        // hierarchy does not keep rendering in the background.
        guard let popoverContentProvider else {
            print("StatusBar: Popover content provider is nil")
            return
        }
        popover.contentViewController = popoverContentProvider(editingWidgets)

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // macOS draws the item pressed while its popover is open.
        // A transient popover closes on a click elsewhere only while its app
        // is active, and a status item's click doesn't activate the app.
        // The deprecated call is deliberate: measured on macOS 27.2, plain
        // `activate()` left the app in front frontmost, while this one made
        // FanMac frontmost with the popover key.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        // Activation is the system's to grant, so a click in any other app
        // also closes the popover, as other menu bar items' popovers do; a click
        // in FanMac's own windows still reaches the transient behaviour.
        stopWatchingOutsideClicks()
        outsideClicks = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePopover() }
        }
    }
    
    func closePopover() {
        popover?.performClose(nil)
    }

    private func stopWatchingOutsideClicks() {
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }
    
    deinit {
        refreshTimer?.invalidate()
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
    }
}

/// Releases popover content when the popover closes. NSPopover retains its
/// contentViewController, so without this the SwiftUI hierarchy keeps rendering
/// (and holding a Metal pipeline) while the popover is hidden.
private final class PopoverCloseObserver: NSObject, NSPopoverDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func popoverDidClose(_ notification: Notification) { onClose() }
}
