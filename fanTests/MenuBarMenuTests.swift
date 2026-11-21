//
//  MenuBarMenuTests.swift
//  fanTests
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//

import XCTest
@testable import FanMac

final class MenuBarMenuTests: XCTestCase {
    /// The menu bar item's menu, on a right or Control-click, holds the
    /// popover's actions and ends with Quit FanMac on ⌘Q.
    /// Each item runs its own action.
    func testTheMenuEndsWithQuitFanMac() throws {
        let manager = StatusBarManager()
        var ran: [String] = []
        manager.onOpenSettings = { ran.append("settings") }
        manager.onHideIcon = { ran.append("hide") }
        manager.onQuitApp = { ran.append("quit") }

        let menu = manager.contextMenu()
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "—" : $0.title },
                       ["Edit Widgets", "—", "Settings…", "Hide Menu Bar Icon", "—", "Quit FanMac"])
        XCTAssertEqual(menu.items.map(\.keyEquivalent), ["", "", ",", "", "", "q"])
        let quit = try XCTUnwrap(menu.items.last)
        XCTAssertEqual(quit.keyEquivalentModifierMask, .command)
        XCTAssertEqual(menu.items[2].keyEquivalentModifierMask, .command)

        // Edit Widgets opens the popover, which needs the menu bar item.
        for item in menu.items.dropFirst() where !item.isSeparatorItem {
            let action = try XCTUnwrap(item.action, item.title)
            XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item), item.title)
        }
        XCTAssertEqual(ran, ["settings", "hide", "quit"])
    }

    /// Edit Widgets is there only while the popover shows widgets to arrange.
    func testEditWidgetsNeedsTheWidgets() {
        let manager = StatusBarManager()
        var canEdit = false
        manager.canEditWidgets = { canEdit }
        XCTAssertEqual(manager.contextMenu().items.first?.isEnabled, false)
        canEdit = true
        XCTAssertEqual(manager.contextMenu().items.first?.isEnabled, true)
        // The menu keeps the other items available either way.
        canEdit = false
        XCTAssertTrue(manager.contextMenu().items.filter { !$0.isSeparatorItem }.dropFirst().allSatisfy(\.isEnabled))
    }
}
