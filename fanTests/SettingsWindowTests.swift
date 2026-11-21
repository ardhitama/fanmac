//
//  SettingsWindowTests.swift
//  FanMacTests
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//

import SwiftUI
import XCTest
@testable import FanMac

final class SettingsWindowTests: XCTestCase {
    /// Settings is as tall as its form. A fixed 640 pt window was 7 pt short
    /// on a Mac with fans, so the form scrolled and the last section's bottom
    /// margin was cut short. On a screen too short for the form (under about
    /// 910 pt), the window stops short of it and the form scrolls, as it
    /// should, so the test skips there.
    func testTheWindowFitsTheForm() throws {
        _ = NSApplication.shared // xctest has no app until something asks
        let controller = SettingsWindowController.shared
        let viewModel = FanControlViewModel(systemMonitor: SystemMonitor()) // held weakly
        controller.bind(viewModel: viewModel)
        controller.openSettings()
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "FanMac Settings" })
        defer { window.close() }
        let opened = window.frame
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        func scrollView(in view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap(scrollView).first
        }
        let form = try XCTUnwrap(scrollView(in: try XCTUnwrap(window.contentView)))
        let content = try XCTUnwrap(form.documentView).frame.height
        let needed = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 1, height: content)).height
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main).visibleFrame.height
        try XCTSkipIf(needed > screen, "the screen (\(Int(screen)) pt) is shorter than the form (\(Int(needed)) pt)")

        // It opens at its size, centred; centring it before the form laid
        // out left it 250 pt right of centre.
        XCTAssertEqual(window.frame, opened, "the window moved or resized after it opened")
        window.center()
        XCTAssertEqual(window.frame, opened, "the window opened away from where centring puts it")

        XCTAssertGreaterThan(content, 400, "the form laid out")
        XCTAssertEqual(form.contentView.bounds.height, content, accuracy: 1, "the form scrolls inside its own window")
    }

    /// The defect: in FanMac itself the form measured 904.5 pt once its rows
    /// came in. A window is a whole number of points tall, so it alternated
    /// between 904 and 905 until AppKit stopped FanMac, each time Settings
    /// opened. The loop needs FanMac's own window and screen, and doesn't
    /// happen here, so this checks what prevents it: the window asks for
    /// whole points.
    func testTheWindowAsksForWholePoints() throws {
        _ = NSApplication.shared
        let window = SettingsWindowController.makeWindow(for: Color.clear.frame(width: 500, height: 404.5))
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(window.contentViewController?.preferredContentSize, NSSize(width: 500, height: 405))
    }
}
