//
//  LaunchAtLoginManager.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Opens FanMac at login through ServiceManagement's main-app login item.
//

import Foundation
import ServiceManagement
import AppKit

final class LaunchAtLoginManager {
    static let shared = LaunchAtLoginManager()

    /// Why the last change failed, or nil after a success.
    private(set) var lastError: String?

    private init() {}

    /// Whether FanMac is a login item, including one macOS holds until the
    /// person allows it. macOS is the source of truth: the person can remove
    /// the item in System Settings at any time.
    var isRegistered: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    /// macOS won't open FanMac at login until the person allows it in
    /// System Settings → General → Login Items.
    var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    func setRegistered(_ register: Bool) {
        do {
            if register {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            print("LaunchAtLogin: \(register ? "register" : "unregister") failed: \(error)")
        }
    }

    func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
