//
//  LegalNotices.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  FanMac's version, copyright and license notices. The GPL asks a program
//  with an interactive interface to show them (section 5(d)); Settings does.
//

import Foundation

enum LegalNotices {
    static let copyright = "Copyright © 2026 Ardhitama"
    static let sourceCode = URL(string: "https://github.com/ardhitama/fanmac")!

    /// A text file the build copies from the repository into the app's
    /// Resources (the "Copy legal notices" build phase).
    enum Document: String, Identifiable, CaseIterable {
        case license = "LICENSE"
        case notice = "NOTICE"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .license: return "GNU General Public License"
            case .notice: return "Notices"
            }
        }

        /// The file's text, or nil if this copy of FanMac lacks it.
        func text(in bundle: Bundle = .main) -> String? {
            guard let url = bundle.url(forResource: rawValue, withExtension: nil) else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    /// "1.0.0 (16)": the version and build in the app's Info.plist.
    static func version(of bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        guard let build = info["CFBundleVersion"] as? String else { return version }
        return "\(version) (\(build))"
    }
}
