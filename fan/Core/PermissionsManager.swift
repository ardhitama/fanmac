//
//  PermissionsManager.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Manages installation of the helper tool
//

import Foundation
import Security
import AppKit
import Combine

class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()
    
    @Published var isHelperInstalled = false
    /// The installed helper differs from the one bundled with this app.
    @Published var isHelperOutdated = false
    /// Why the last install or update failed. It lives here rather than in
    /// the popover, because the password prompt can close the popover, and
    /// the reason must still show when it opens again.
    @Published private(set) var installError: String?
    
    /// sudoers grants passwordless root to whatever file sits at this path, so
    /// every directory on it must be writable only by root. /usr/local/bin is
    /// not safe for this: Homebrew makes it user-writable on Intel Macs.
    nonisolated static let helperPath = "/Library/PrivilegedHelperTools/fanmac-smc-helper"
    /// Earlier releases installed here (setuid root via scripts/install.sh).
    nonisolated private static let legacyHelperPath = "/usr/local/bin/smc-helper"
    nonisolated private static let sudoersPath = "/etc/sudoers.d/smc-fan-helper"
    
    private init() {
        checkInstallation()
    }
    
    func checkInstallation() {
        // Run on background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let fileManager = FileManager.default
            let helperExists = fileManager.fileExists(atPath: Self.helperPath)
            
            if !helperExists {
                DispatchQueue.main.async {
                    self.isHelperInstalled = false
                    self.isHelperOutdated = false
                }
                return
            }
            
            let bundledPath = Bundle.main.url(forResource: "smc-helper", withExtension: nil)?.path
            let outdated = Self.helperNeedsUpdate(
                installedPath: Self.helperPath,
                bundledPath: bundledPath,
                requirement: Self.helperRequirement(teamIdentifier: Self.ownTeamIdentifier)
            )
            
            // If helper exists, assume it's installed (sudoers verification can be flaky from GUI apps)
            // The actual passwordless sudo will be tested when FanController runs
            DispatchQueue.main.async {
                self.isHelperInstalled = true
                self.isHelperOutdated = outdated
            }
        }
    }
    
    func installHelper(completion: @escaping (Bool, String?) -> Void = { _, _ in }) {
        installError = nil
        let completion: (Bool, String?) -> Void = { [weak self] success, error in
            if !success { self?.installError = error ?? "The installer stopped before it finished." }
            completion(success, error)
        }

        // 1. Locate the helper in the App Bundle
        guard let bundledHelperURL = Bundle.main.url(forResource: "smc-helper", withExtension: nil) else {
            completion(false, "App Bundle missing smc-helper. Re-build app.")
            return
        }
        
        // 2. Construct the installation script
        // We handle everything in one root shell script behind a single prompt.
        let script = Self.administratorScript(Self.installCommand(
            bundledHelperPath: bundledHelperURL.path,
            requirement: Self.helperRequirement(teamIdentifier: Self.ownTeamIdentifier)
        ))
        
        // 3. Execute
        DispatchQueue.global(qos: .userInitiated).async {
             var error: NSDictionary?
             if let scriptObject = NSAppleScript(source: script) {
                 _ = scriptObject.executeAndReturnError(&error)
                 
                 DispatchQueue.main.async {
                     if let error = error {
                         let msg = error["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
                         completion(false, msg)
                     } else {
                         self.checkInstallation() // Refresh state
                         completion(true, nil)
                     }
                 }
             } else {
                 DispatchQueue.main.async {
                     completion(false, "Failed to create installation script")
                 }
             }
        }
    }
    
    /// Whether the root-owned helper differs from the copy bundled with this
    /// app. An app update can ship a fixed helper, but the installed copy only
    /// changes when the user reinstalls it, so a difference asks for an update.
    nonisolated static func helperNeedsUpdate(installedPath: String, bundledPath: String?, requirement: String? = nil) -> Bool {
        // Never prompt to install a bundled helper whose signature is broken,
        // or that isn't FanMac's: something else could have put it there to
        // get the person's password behind a genuine FanMac prompt.
        guard let bundledPath, let bundledHash = codeHash(atPath: bundledPath, requirement: requirement) else { return false }
        // A missing, unsigned, or tampered installed helper has no hash: repair it.
        return codeHash(atPath: installedPath, requirement: requirement) != bundledHash
    }
    
    /// CDHash of validly signed code at `path` that meets `requirement`, or
    /// nil. It covers the code and signing identity but not the signing time,
    /// so re-signing an unchanged helper for each release does not trigger an
    /// update prompt.
    nonisolated static func codeHash(atPath path: String, requirement: String? = nil) -> Data? {
        var secRequirement: SecRequirement?
        if let requirement {
            guard SecRequirementCreateWithString(requirement as CFString, [], &secRequirement) == errSecSuccess else { return nil }
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, [], secRequirement) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
    }
    
    /// The team that signed this copy of FanMac, or nil for a build signed
    /// to run locally, which has none.
    nonisolated static var ownTeamIdentifier: String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The code requirement a helper must meet to be installed: FanMac's
    /// helper, signed by the team that signed this app. Nil when the app has
    /// no team, as a local build doesn't, so there is nothing to compare.
    nonisolated static func helperRequirement(teamIdentifier: String?) -> String? {
        guard let team = teamIdentifier, !team.isEmpty,
              team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return "identifier \"smc-helper\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Root shell script that installs the bundled helper, points the sudoers
    /// rule at it, and removes the legacy /usr/local/bin helper.
    ///
    /// The bundled helper and the person's temporary folder can be changed by
    /// anything running as the person, so both files are staged in the
    /// root-only folder they go live in, under names nothing reads (sudo skips
    /// names with a dot), checked there, and renamed into place. The helper
    /// must meet `requirement`, when there is one, after it is staged.
    nonisolated static func installCommand(bundledHelperPath: String, requirement: String? = nil) -> String {
        // Every interpolated value is shell-quoted: the bundle path is
        // user-controlled (the app can live anywhere) and runs as root here.
        let helper = shellQuoted(helperPath)
        let helperDirectory = (helperPath as NSString).deletingLastPathComponent
        let sudoersDirectory = (sudoersPath as NSString).deletingLastPathComponent
        let rule = shellQuoted("%admin ALL=(root) NOPASSWD: \(helperPath)")
        var lines = [
            "set -e",
            "/bin/mkdir -p -m 755 \(shellQuoted(helperDirectory)) \(shellQuoted(sudoersDirectory))",
            "umask 077",
            "staged=$(/usr/bin/mktemp \(shellQuoted(helperDirectory + "/.fanmac-smc-helper.XXXXXX")))",
            "rule=$(/usr/bin/mktemp \(shellQuoted(sudoersDirectory + "/.smc-fan-helper.XXXXXX")))",
            "trap '/bin/rm -f \"$staged\" \"$rule\"' EXIT",
            "/bin/cp \(shellQuoted(bundledHelperPath)) \"$staged\"",
        ]
        if let requirement {
            lines.append("/usr/bin/codesign --verify --strict -R \(shellQuoted("=" + requirement)) \"$staged\"")
        }
        lines += [
            "/usr/sbin/chown root:wheel \"$staged\"",
            "/bin/chmod 755 \"$staged\"",
            "/bin/mv -f \"$staged\" \(helper)",
            // Validate the rule before it goes live: a malformed file in
            // sudoers.d breaks sudo for the whole system.
            "/usr/bin/printf '%s\\n' \(rule) > \"$rule\"",
            "/usr/sbin/visudo -c -q -f \"$rule\"",
            "/usr/sbin/chown root:wheel \"$rule\"",
            "/bin/chmod 440 \"$rule\"",
            "/bin/mv -f \"$rule\" \(shellQuoted(sudoersPath))",
            "/bin/rm -f \(shellQuoted(legacyHelperPath))",
        ]
        return lines.joined(separator: "\n")
    }
    
    /// Single-quotes `value` for /bin/sh so it stays one literal word, even if
    /// it contains spaces, quotes, or `$`.
    nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    
    /// AppleScript source that runs `command` with /bin/sh as root after an
    /// admin password prompt.
    nonisolated static func administratorScript(_ command: String) -> String {
        let literal = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(literal)\" with administrator privileges"
    }
}
