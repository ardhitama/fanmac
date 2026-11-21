//
//  Watch.swift
//  fanmac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  `fanmac watch`: a live view of the fans with keyboard control, in the
//  popover's order and wording.
//

import Foundation

final class WatchSession {
    private enum Setting: Hashable {
        case manualAll
        case manualFan(Int)
        case speedUpFrom
        case maxSpeed
        case response

        var label: String {
            switch self {
            case .manualAll: return "Target speed"
            case .manualFan(let index): return "Fan \(index + 1) target"
            case .speedUpFrom: return "Speed up from"
            case .maxSpeed: return "Max speed"
            case .response: return "Response"
            }
        }

        var step: Double {
            switch self {
            case .manualAll, .manualFan, .maxSpeed: return 100
            case .speedUpFrom: return 5
            case .response: return 0.1
            }
        }
    }

    private let palette = Palette(fd: STDOUT_FILENO)
    private var status: FanMacControl.Status? {
        didSet {
            // A mode change, from here or the menu bar, shows other settings:
            // start at the first, and drop unsent changes to the old mode's.
            if status?.mode != oldValue?.mode {
                selection = 0
                pending = [:]
            }
        }
    }
    private var selection = 0
    /// Changes made with ←→ but not sent yet; sent once the keys go quiet.
    private var pending: [Setting: Double] = [:]
    private var lastAdjust = Date.distantPast
    private var nextRefresh = Date.distantPast
    private var triedLaunch = false
    private var notice: (text: String, role: Palette.Role, until: Date)?
    /// The last screen written; the loop wakes often, but redraws only on change.
    private var lastFrame = ""

    func run() -> Int32 {
        guard RawTerminal.enter() else {
            FileHandle.standardError.write(Data("fanmac: watch needs a terminal. Use fanmac status instead.\n".utf8))
            return 2
        }
        defer { RawTerminal.restore() }

        while true {
            let now = Date()
            if !pending.isEmpty, now.timeIntervalSince(lastAdjust) > 0.35 {
                sendPending()
            }
            if now >= nextRefresh {
                refresh()
                nextRefresh = Date().addingTimeInterval(1)
            }
            render()
            for key in readKeys(timeout: 120) where !handle(key) {
                if !pending.isEmpty { sendPending() }
                return 0
            }
        }
    }

    // MARK: - Input

    /// Returns false to quit.
    private func handle(_ key: Key) -> Bool {
        switch key {
        case .escape, .interrupt, .character("q"), .character("Q"):
            return false
        case .character("m"), .character("M"):
            send(modeRequest(.manual))
        case .character("a"), .character("A"):
            send(modeRequest(.auto))
        case .up, .character("k"):
            selection = max(0, selection - 1)
        case .down, .character("j"):
            selection = min(max(0, settings.count - 1), selection + 1)
        case .left, .character("h"), .character("-"), .character("_"):
            adjust(by: -1)
        case .right, .character("l"), .character("+"), .character("="):
            adjust(by: 1)
        default:
            break
        }
        return true
    }

    private func modeRequest(_ mode: FanMacControl.Mode) -> FanMacControl.Request {
        var request = FanMacControl.Request(.setMode)
        request.mode = mode
        return request
    }

    private var settings: [Setting] {
        guard let status, status.hasNoFans != true else { return [] }
        switch status.mode {
        case .manual:
            return status.perFan ? status.fans.indices.map { .manualFan($0) } : [.manualAll]
        case .auto:
            return [.speedUpFrom, .maxSpeed, .response]
        }
    }

    private func value(of setting: Setting, in status: FanMacControl.Status) -> Double {
        if let value = pending[setting] { return value }
        switch setting {
        case .manualAll:
            return Double(status.manualSpeed)
        case .manualFan(let index):
            let speeds = status.manualSpeedPerFan ?? []
            return Double(index < speeds.count ? speeds[index] : status.manualSpeed)
        case .speedUpFrom:
            return status.speedUpFrom
        case .maxSpeed:
            return Double(status.maxSpeed)
        case .response:
            return status.response
        }
    }

    private func range(of setting: Setting, in status: FanMacControl.Status) -> ClosedRange<Double> {
        switch setting {
        case .manualAll, .maxSpeed:
            return Double(status.minRPM)...Double(max(status.maxRPM, status.minRPM))
        case .manualFan(let index):
            guard index < status.fans.count else { return 0...0 }
            let fan = status.fans[index]
            return Double(fan.minRPM)...Double(max(fan.maxRPM, fan.minRPM))
        case .speedUpFrom:
            return FanMacControl.speedUpFromRange
        case .response:
            return FanCurve.responseRange
        }
    }

    private func adjust(by direction: Double) {
        guard let status, selection < settings.count else { return }
        let setting = settings[selection]
        let range = range(of: setting, in: status)
        var next = value(of: setting, in: status) + direction * setting.step
        next = min(range.upperBound, max(range.lowerBound, next))
        if setting == .response { next = (next * 10).rounded() / 10 }
        pending[setting] = next
        lastAdjust = Date()
    }

    // MARK: - Requests

    private func sendPending() {
        let changes = pending
        pending = [:]
        var auto = FanMacControl.Request(.setAuto)
        var hasAutoChange = false
        for (setting, value) in changes {
            switch setting {
            case .manualAll:
                var request = FanMacControl.Request(.setManualSpeed)
                request.rpm = Int(value)
                send(request)
            case .manualFan(let index):
                var request = FanMacControl.Request(.setManualSpeed)
                request.rpm = Int(value)
                request.fan = index
                send(request)
            case .speedUpFrom:
                auto.speedUpFrom = value
                hasAutoChange = true
            case .maxSpeed:
                auto.maxSpeed = Int(value)
                hasAutoChange = true
            case .response:
                auto.response = value
                hasAutoChange = true
            }
        }
        if hasAutoChange { send(auto) }
    }

    private func send(_ request: FanMacControl.Request) {
        do {
            let response = try Client.send(request)
            if let status = response.status { self.status = status }
            if let error = response.error {
                show(error, .destructive)
            }
            selection = min(selection, max(0, settings.count - 1))
        } catch let error as ClientError {
            show(error.message, .destructive)
        } catch {
            show("Couldn’t reach FanMac.", .destructive)
        }
    }

    private func refresh() {
        do {
            let response = try Client.send(FanMacControl.Request(.status))
            status = response.status
            selection = min(selection, max(0, settings.count - 1))
        } catch let error as ClientError where error.message == ClientError.notRunning.message {
            guard !triedLaunch else {
                show("Couldn’t reach FanMac. Open it from Applications; this view reconnects on its own.", .destructive)
                return
            }
            triedLaunch = true
            show("Starting FanMac…", .secondary)
            render()
            if Client.launchApp() {
                notice = nil
                refresh()
            } else {
                show("Couldn’t start FanMac. Open it from Applications; this view reconnects on its own.", .destructive)
            }
        } catch let error as ClientError {
            show(error.message, .destructive)
        } catch {
            show("Couldn’t reach FanMac.", .destructive)
        }
    }

    private func show(_ text: String, _ role: Palette.Role) {
        notice = (text, role, Date().addingTimeInterval(6))
    }

    // MARK: - Drawing

    private func render() {
        let (columns, rows) = terminalSize()
        let width = max(20, columns)
        var body: [StyledLine] = []

        var header = StyledLine(" FanMac", .text, bold: true)
        if let status {
            header.add("   ")
            header.add(status.summary, .secondary)
        }
        body.append(header)
        body.append(StyledLine())

        if let status {
            body += noticeLines(status, width: width)
            body += readingLines(status, width: width)
            // Without fans there is nothing to show or set; the header says so.
            if status.hasNoFans != true {
                body.append(StyledLine())
                body += fanLines(status)
                body.append(StyledLine())
                body += settingLines(status)
            }
        } else {
            body.append(StyledLine(" Connecting to FanMac…", .secondary))
        }

        var footer: [StyledLine] = []
        if let notice, notice.until > Date() {
            footer += wrap(notice.text, width: width - 2).map { StyledLine(" " + $0, notice.role) }
        }
        footer.append(keyHints())

        let bodyRows = max(0, rows - footer.count)
        var screen = Array(body.prefix(bodyRows))
        screen += Array(repeating: StyledLine(), count: bodyRows - screen.count)
        screen += footer

        var out = "\u{1B}[H"
        for (index, line) in screen.prefix(rows).enumerated() {
            out += line.render(palette, maxWidth: width) + "\u{1B}[K"
            if index < rows - 1 { out += "\r\n" }
        }
        guard out != lastFrame else { return }
        lastFrame = out
        writeOut(out)
    }

    private func noticeLines(_ status: FanMacControl.Status, width: Int) -> [StyledLine] {
        var lines: [StyledLine] = []
        if let problem = status.problem {
            lines += wrap(problem, width: width - 2).map { StyledLine(" " + $0, .destructive) }
            lines.append(StyledLine())
        }
        if status.thermalPressureLimitsPerformance {
            let remedy = status.hasNoFans == true ? "Cooler air lets it" : "Faster fans or cooler air let it"
            let text = "macOS is slowing the Mac to cool it. Thermal pressure is \(status.thermalPressure.lowercased()). \(remedy) run at full speed."
            lines += wrap(text, width: width - 2).map { StyledLine(" " + $0, .warning) }
            lines.append(StyledLine())
        }
        if !status.helperReady, status.hasNoFans != true {
            let text = status.helperInstalled
                ? "The helper needs an update. Click the FanMac menu bar icon, then Update Helper."
                : "The helper isn’t installed. Click the FanMac menu bar icon, then Install Helper."
            lines += wrap(text, width: width - 2).map { StyledLine(" " + $0, .warning) }
            lines.append(StyledLine())
        }
        return lines
    }

    private func readingLines(_ status: FanMacControl.Status, width: Int) -> [StyledLine] {
        func reading(_ label: String, _ celsius: Double?) -> StyledLine {
            var line = StyledLine(label + "  ", .secondary)
            line.add(temperatureText(celsius), temperatureRole(celsius))
            if let celsius {
                line.add("  " + TemperatureLevel(celsius: celsius).title.lowercased(), .secondary)
            }
            return line
        }
        var thermal = StyledLine("Thermal pressure  ", .secondary)
        thermal.add(status.thermalPressure, status.thermalPressureLimitsPerformance ? .warning : .text)

        let parts = [reading("CPU", status.cpuTemperature), reading("GPU", status.gpuTemperature), thermal]
        // Three columns when they fit, otherwise one reading per line.
        if width >= 72 {
            var line = StyledLine(" ")
            for (index, part) in parts.enumerated() {
                line.pad(to: 1 + index * 24)
                for run in part.runs { line.add(run.text, run.role, bold: run.bold) }
            }
            return [line]
        }
        return parts.map { part in
            var line = StyledLine(" ")
            for run in part.runs { line.add(run.text, run.role, bold: run.bold) }
            return line
        }
    }

    /// Each fan's speed and where it runs in its range, with Auto's target once
    /// when the fans share it, as the popover's Fans card shows them.
    private func fanLines(_ status: FanMacControl.Status) -> [StyledLine] {
        let autoTargets = status.autoTargets
        var title = StyledLine(" Fans", .secondary, bold: true)
        if let shared = autoTargets?.shared {
            title.pad(to: 12)
            title.add("Target \(shared.formatted()) RPM", .secondary)
        }
        var lines = [title]
        if status.fans.isEmpty {
            lines.append(StyledLine("   No fans", .secondary))
        }
        for (index, fan) in status.fans.enumerated() {
            var line = StyledLine("   Fan \(index + 1)", .secondary)
            line.pad(to: 12)
            line.add("\(fan.rpm.formatted()) RPM", .text, bold: true)
            line.pad(to: 24)
            // The meter's fill is calm, as the popover's: it asks nothing.
            let cells = 20
            let filled = Int((fan.rangeFraction * Double(cells)).rounded())
            line.add(String(repeating: "━", count: filled), .text)
            line.add(String(repeating: "─", count: cells - filled), .secondary)
            if let perFan = autoTargets?.perFan, index < perFan.count {
                line.add("  target \(perFan[index].formatted())", .secondary)
            }
            lines.append(line)
        }
        return lines
    }

    private func settingLines(_ status: FanMacControl.Status) -> [StyledLine] {
        var lines = [StyledLine(status.mode == .manual ? " Manual" : " Auto Curve", .secondary, bold: true)]
        if status.mode == .auto {
            lines += curveLines(status)
        }
        for (index, setting) in settings.enumerated() {
            let selected = index == selection
            var line = StyledLine(selected ? " › " : "   ", .accent)
            line.add(setting.label, selected ? .text : .secondary)
            line.pad(to: 20)
            // A value ←→ changed but not yet sent stands out by weight, as the
            // grey accent is close to the text's tone.
            line.add(valueText(setting, status), pending[setting] == nil ? .text : .accent, bold: pending[setting] != nil)
            lines.append(line)
        }
        if status.mode == .manual {
            lines.append(StyledLine("   Range \(status.minRPM.formatted())–\(status.maxRPM.formatted()) RPM", .secondary))
        }
        return lines
    }

    /// The Auto curve as block columns, one per 2 °C on the temperature meter's
    /// scale, with the current temperature's column in the text's tone, as the
    /// popover's graph marks it. Unsent ←→ changes show at once.
    private func curveLines(_ status: FanMacControl.Status) -> [StyledLine] {
        let rows = 3
        let range = TemperatureLevel.meterRange
        let temperatures = Array(stride(from: range.lowerBound, through: range.upperBound, by: 2))
        let floor = status.minRPM
        let maxSpeed = Int(value(of: .maxSpeed, in: status))
        let levels = temperatures.map { celsius in
            FanCurve.level(
                temperature: celsius,
                threshold: value(of: .speedUpFrom, in: status),
                response: value(of: .response, in: status),
                floorRPM: floor,
                ceilingRPM: min(maxSpeed, status.maxRPM),
                topRPM: status.maxRPM
            )
        }
        let marked = status.hottestTemperature.flatMap { celsius in
            temperatures.indices.min { abs(temperatures[$0] - celsius) < abs(temperatures[$1] - celsius) }
        }

        let partial: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇"]
        var lines: [StyledLine] = []
        for row in 0..<rows {
            let rowFromBottom = rows - 1 - row
            var line = StyledLine("   ")
            for (index, level) in levels.enumerated() {
                // At least one eighth, so the floor still draws a baseline.
                let eighths = max(1, Int((level * Double(rows * 8)).rounded()))
                let cell = min(8, max(0, eighths - rowFromBottom * 8))
                let glyph = cell == 0 ? " " : cell == 8 ? "█" : String(partial[cell - 1])
                line.add(glyph, index == marked ? .text : .secondary)
            }
            lines.append(line)
        }

        let low = "\(Int(range.lowerBound)) °C"
        let high = "\(Int(range.upperBound)) °C"
        var scale = StyledLine("   " + low, .secondary)
        scale.pad(to: 3 + temperatures.count - high.count)
        scale.add(high, .secondary)
        lines.append(scale)
        return lines
    }

    private func valueText(_ setting: Setting, _ status: FanMacControl.Status) -> String {
        let value = value(of: setting, in: status)
        switch setting {
        case .manualAll, .manualFan, .maxSpeed:
            return "\(Int(value).formatted()) RPM"
        case .speedUpFrom:
            return "\(Int(value)) °C"
        case .response:
            return "\(FanCurve.responseLabel(value)) (\(value.formatted(.number.precision(.fractionLength(1)))))"
        }
    }

    private func keyHints() -> StyledLine {
        var line = StyledLine(" ")
        let keys = status?.hasNoFans == true
            ? [("q", "Quit")]
            : [("m", "Manual"), ("a", "Auto"), ("↑↓", "Choose"), ("←→", "Change"), ("q", "Quit")]
        for (key, action) in keys {
            line.add(key, .text, bold: true)
            line.add(" \(action)   ", .secondary)
        }
        return line
    }
}
