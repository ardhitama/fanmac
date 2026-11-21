//
//  SettingsWindowController.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Opens the settings window from AppKit (menu bar context menu, app reopen, etc.).
//

import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private weak var viewModel: FanControlViewModel?

    private override init() {
        super.init()
    }

    func bind(viewModel: FanControlViewModel) {
        self.viewModel = viewModel
    }

  /// Presents the settings window, creating it on first use.
    func openSettings() {
        guard let viewModel else {
            print("SettingsWindowController: no view model bound")
            return
        }

        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = Self.makeWindow(for: SettingsWindowView(viewModel: viewModel))
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    /// The Settings window around `content`, which sets the window's size.
    static func makeWindow(for content: some View) -> NSWindow {
        let hosting = WholePointHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize]

        // The system's window: its background and title bar, which the dark
        // appearance colours.
        let window = NSWindow(contentViewController: hosting)
        window.title = "FanMac Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        // Size it before centring: until the form lays out, the window is
        // 1 pt wide, and centring that opened Settings right of centre.
        window.setContentSize(WholePointHostingController<AnyView>.wholePoints(
            hosting.sizeThatFits(in: NSSize(width: 500, height: 10_000))
        ))
        window.center()
        window.isReleasedWhenClosed = false
        return window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

/// Asks for a whole number of points, for Settings and the popover, whose
/// windows take their content's size. A window is a whole number of points
/// tall, and SwiftUI can measure a fraction: Settings measured 904.5 pt. Its
/// window then alternated between 904 and 905, each size asked for 904.5
/// again, and after 128 rounds AppKit stopped FanMac with an exception.
final class WholePointHostingController<Content: View>: NSHostingController<Content> {
    override var preferredContentSize: NSSize {
        get { Self.wholePoints(super.preferredContentSize) }
        set { super.preferredContentSize = newValue }
    }

    static func wholePoints(_ size: NSSize) -> NSSize {
        NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
    }
}
