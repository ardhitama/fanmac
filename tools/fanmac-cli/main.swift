//
//  main.swift
//  fanmac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  The FanMac command. It ships inside FanMac.app (Contents/Helpers) and
//  asks the running app to read and change the fans, so one installation
//  gives both the menu bar app and the terminal.
//

import Foundation

let usage = """
Usage: fanmac [command]

Commands:
  watch                     Live view with keyboard control (the default in a terminal)
  status [--json]           Print temperatures, fan speeds and who controls the fans
  manual [RPM] [--fan N]    Hold the fans at RPM: every fan, or only fan N (from 1)
  auto [--from °C] [--max RPM] [--response 0–3]
                            Let fan speed follow temperature, and change the curve
  version                   Show the version, copyright and license
  help                      Show this help

watch, manual and auto start FanMac if it isn't running.
"""

/// The version of the FanMac.app this command ships in (Contents/Helpers),
/// with the notices the GPL asks an interactive program to show.
func versionText() -> String {
    let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
    let app = executable?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let info = app.flatMap { Bundle(url: $0) }?.infoDictionary ?? [:]
    let version = (info["CFBundleShortVersionString"] as? String).map { "fanmac \($0)" }
        ?? "fanmac (not inside FanMac.app, so its version is unknown)"
    return """
    \(version)
    Copyright (C) 2026 Ardhitama
    License GPLv3+: GNU GPL version 3 or later <https://gnu.org/licenses/gpl.html>.
    This is free software: you are free to change and redistribute it.
    There is NO WARRANTY, to the extent permitted by law.
    The license doesn't cover the FanMac name or icon; see NOTICE in FanMac.app.
    """
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("fanmac: \(message)\n".utf8))
    exit(code)
}

func usageError(_ message: String) -> Never {
    fail("\(message)\n\n\(usage)", code: 2)
}

/// Reads `--name value` pairs after the positional arguments.
func parseOptions(_ args: ArraySlice<String>, allowed: Set<String>) -> (positional: [String], options: [String: String]) {
    var positional: [String] = []
    var options: [String: String] = [:]
    var iterator = args.makeIterator()
    while let arg = iterator.next() {
        if arg.hasPrefix("--") {
            let name = String(arg.dropFirst(2))
            guard allowed.contains(name) else { usageError("Unknown option \(arg).") }
            guard let value = iterator.next() else { usageError("\(arg) needs a value.") }
            options[name] = value
        } else {
            positional.append(arg)
        }
    }
    return (positional, options)
}

func number<T: LosslessStringConvertible>(_ text: String, _ what: String) -> T {
    guard let value = T(text) else { usageError("\(what) must be a number, not “\(text)”.") }
    return value
}

/// Sends a change, starting FanMac if needed, and prints the outcome.
func change(_ request: FanMacControl.Request) -> Never {
    let palette = Palette(fd: STDOUT_FILENO)
    do {
        let response = try Client.sendStartingApp(request) { note in
            FileHandle.standardError.write(Data("\(note)\n".utf8))
        }
        if let error = response.error { fail(error) }
        if let status = response.status {
            print(palette.paint(status.summary, .text))
            if status.mode == .auto, let curve = status.curveSummary { print(palette.paint(curve, .secondary)) }
        }
        exit(0)
    } catch let error as ClientError {
        fail(error.message)
    } catch {
        fail("Couldn’t reach FanMac.")
    }
}

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? (isatty(STDOUT_FILENO) == 1 ? "watch" : "status")
let rest = args.dropFirst()

switch command {
case "watch":
    guard rest.isEmpty else { usageError("watch takes no arguments.") }
    exit(WatchSession().run())

case "status":
    let (positional, _) = parseOptions(rest.filter { $0 != "--json" }, allowed: [])
    guard positional.isEmpty else { usageError("status takes only --json.") }
    do {
        let response = try Client.send(FanMacControl.Request(.status))
        guard let status = response.status else { fail(response.error ?? "FanMac sent no status.") }
        if rest.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(status), as: UTF8.self))
        } else {
            print(statusReport(status, palette: Palette(fd: STDOUT_FILENO)))
        }
    } catch let error as ClientError where error.message == ClientError.notRunning.message {
        fail("FanMac isn’t running. Open it from Applications, or run fanmac watch to start it.")
    } catch let error as ClientError {
        fail(error.message)
    }

case "manual":
    let (positional, options) = parseOptions(rest, allowed: ["fan"])
    guard positional.count <= 1 else { usageError("manual takes one speed in RPM.") }
    var request = FanMacControl.Request(.setManualSpeed)
    if let rpm = positional.first { request.rpm = number(rpm, "The speed") }
    if let fan = options["fan"] {
        let index: Int = number(fan, "--fan")
        guard index >= 1 else { usageError("--fan counts from 1.") }
        guard request.rpm != nil else { usageError("Give a speed for fan \(index), such as fanmac manual 3000 --fan \(index).") }
        request.fan = index - 1
    }
    change(request)

case "auto":
    let (positional, options) = parseOptions(rest, allowed: ["from", "max", "response"])
    guard positional.isEmpty else { usageError("auto takes only --from, --max and --response.") }
    var request = FanMacControl.Request(.setAuto)
    if let from = options["from"] { request.speedUpFrom = number(from, "--from") }
    if let max = options["max"] { request.maxSpeed = number(max, "--max") }
    if let response = options["response"] { request.response = number(response, "--response") }
    change(request)

case "version", "--version":
    guard rest.isEmpty else { usageError("version takes no arguments.") }
    print(versionText())

case "help", "-h", "--help":
    print(usage)

default:
    usageError("Unknown command “\(command)”.")
}
