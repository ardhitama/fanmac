//
//  CommandLineTool.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Links the `fanmac` command bundled in Contents/Helpers into /usr/local/bin,
//  which is on the default PATH, so the app install also installs the command.
//  A Homebrew install links it into Homebrew's bin instead.
//

import Foundation

enum CommandLineTool {
    static let linkPath = "/usr/local/bin/fanmac"
    /// Every place a link to this copy counts as installed: the link Settings
    /// makes, and the one `brew install --cask fanmac` makes on Apple silicon.
    /// Homebrew on Intel links at `linkPath` itself.
    static let installedLinkPaths = [linkPath, "/opt/homebrew/bin/fanmac"]

    enum State: Equatable {
        /// This build has no bundled command (a broken or partial build).
        case unavailable
        case notInstalled
        case installed
        /// Something else is at the link path, such as a link to another copy.
        case otherFile
    }

    static var bundledURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/fanmac")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var state: State {
        state(bundled: bundledURL, linkPaths: installedLinkPaths)
    }

    /// The state for a bundled command and the links that would install it;
    /// `linkPaths.first` is the one Settings makes.
    static func state(bundled: URL?, linkPaths: [String]) -> State {
        guard let bundled, let ownLink = linkPaths.first else { return .unavailable }
        let bundledPath = bundled.resolvingSymlinksInPath().path
        if linkPaths.contains(where: { resolvedLink($0)?.path == bundledPath }) {
            return .installed
        }
        let fm = FileManager.default
        // A dangling link isn't a file, but it still blocks the install.
        let occupied = fm.fileExists(atPath: ownLink) || resolvedLink(ownLink) != nil
        return occupied ? .otherFile : .notInstalled
    }

    /// Where the symbolic link at `path` finally leads, or nil if it isn't one.
    private static func resolvedLink(_ path: String) -> URL? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return nil
        }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        return URL(fileURLWithPath: destination, relativeTo: directory).resolvingSymlinksInPath()
    }

    /// Creates or replaces the link after an administrator prompt, since
    /// /usr/local/bin belongs to root. Calls back on main with an error, or nil.
    static func install(completion: @escaping (String?) -> Void) {
        guard let bundled = bundledURL else {
            completion("This copy of FanMac has no fanmac command. Download FanMac again.")
            return
        }
        let command = [
            "set -e",
            "mkdir -p /usr/local/bin",
            "ln -sfh \(PermissionsManager.shellQuoted(bundled.path)) \(PermissionsManager.shellQuoted(linkPath))",
        ].joined(separator: "\n")
        let source = PermissionsManager.administratorScript(command)

        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            let message: String? = error.map { error in
                (error["NSAppleScriptErrorNumber"] as? Int) == -128
                    ? "Installation was cancelled."
                    : (error["NSAppleScriptErrorMessage"] as? String ?? "The installer stopped before it finished.")
            }
            DispatchQueue.main.async { completion(message) }
        }
    }
}
