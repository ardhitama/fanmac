//
//  LegacyIdentity.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  The app FanMac replaces, and FanMac's early builds, had the bundle
//  identifier tests.fan.
//

import Foundation

/// macOS keys an app's settings and its login item by bundle identifier, so
/// FanMac under its own identifier starts without either. The first launch
/// carries the settings over; the caller turns Open at login back on, which
/// macOS gives no way to read from the old identifier.
enum LegacyIdentity {
    static let bundleIdentifier = "tests.fan"
    private static let carriedOverKey = "carriedOverFromTestsFan"

    /// Copies the old settings into `domain` once, keeping any setting
    /// already there. Returns whether there were old settings, that is,
    /// whether FanMac replaced the tests.fan app.
    @discardableResult
    static func carryOverSettings(
        _ defaults: UserDefaults = .standard,
        into domain: String,
        from legacyDomain: String = bundleIdentifier
    ) -> Bool {
        let current = defaults.persistentDomain(forName: domain) ?? [:]
        guard current[carriedOverKey] == nil else { return false }
        let old = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        var merged = old.merging(current) { _, kept in kept }
        merged[carriedOverKey] = true
        defaults.setPersistentDomain(merged, forName: domain)
        return !old.isEmpty
    }
}
