//
//  FanMacControl.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  The protocol between the menu bar app and the `fanmac` command. Both
//  targets compile this file. The app is the only process that drives the
//  fans; `fanmac` asks it to, so the two never fight over them.
//

import Foundation

nonisolated enum FanMacControl {
    /// The app listens here. The directory is private to the user (0700) and
    /// the socket 0600, so only the user who runs FanMac can reach it.
    static var socketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FanMac", isDirectory: true)
            .appendingPathComponent("control.sock")
    }

    /// One request per connection: a JSON object ending in a newline, answered
    /// by one JSON response ending in a newline.
    static let maxMessageBytes = 64 * 1024

    /// Range of the Auto curve's start temperature (°C).
    static let speedUpFromRange: ClosedRange<Double> = 40...90

    /// The answer to a fan change on a Mac without fans, such as a MacBook Air.
    static let noFansMessage = "This Mac has no fans, so there is nothing to control. FanMac still shows its temperatures."

    enum Command: String, Codable, Sendable {
        case status
        case setMode
        case setManualSpeed
        case setAuto
    }

    enum Mode: String, Codable, Sendable {
        case manual
        case auto
    }

    struct Request: Codable, Sendable {
        var command: Command
        var mode: Mode?
        /// setManualSpeed: the target RPM.
        var rpm: Int?
        /// setManualSpeed: 0-based fan index; nil sets every fan.
        var fan: Int?
        /// setAuto: any field left nil keeps its current value.
        var speedUpFrom: Double?
        var maxSpeed: Int?
        var response: Double?

        init(_ command: Command) {
            self.command = command
        }
    }

    struct Fan: Codable, Sendable {
        var rpm: Int
        /// FanMac's target, or nil while macOS controls the fan.
        var target: Int?
        var minRPM: Int
        var maxRPM: Int
    }

    struct Status: Codable, Sendable {
        var mode: Mode
        /// False while macOS controls the fans: before FanMac takes them,
        /// while the Mac sleeps, and when Auto has no temperature to follow.
        var controlledByFanMac: Bool
        var helperInstalled: Bool
        var helperNeedsUpdate: Bool
        var cpuTemperature: Double?
        var gpuTemperature: Double?
        var thermalPressure: String
        var thermalPressureLimitsPerformance: Bool
        var fans: [Fan]
        var manualSpeed: Int
        /// Each fan's own manual speed, when they differ by choice.
        var manualSpeedPerFan: [Int]?
        var speedUpFrom: Double
        var maxSpeed: Int
        var response: Double
        /// The last failed fan change and how to recover, written for people.
        var problem: String?
        /// The Mac has no fans, such as a MacBook Air. Nil from an older
        /// FanMac that is still running, which doesn't send it.
        var hasNoFans: Bool?
    }

    struct Response: Codable, Sendable {
        var status: Status?
        var error: String?
    }

    /// Who drives the fans right now, in one sentence.
    static func controlSummary(
        hasNoFans: Bool,
        helperInstalled: Bool,
        helperReady: Bool,
        controlledByFanMac: Bool,
        mode: Mode,
        perFan: Bool,
        manualRPM: Int
    ) -> String {
        if hasNoFans {
            return "This Mac has no fans."
        }
        if !helperReady {
            return helperInstalled
                ? "macOS controls the fans until the helper is updated: click the FanMac menu bar icon, then Update Helper."
                : "macOS controls the fans until the helper is installed: click the FanMac menu bar icon, then Install Helper."
        }
        if !controlledByFanMac {
            return "macOS is controlling the fans."
        }
        switch mode {
        case .manual:
            return perFan
                ? "Manual: each fan holds its own speed."
                : "Manual: fans hold \(manualRPM.formatted()) RPM."
        case .auto:
            return "Auto: fan speed follows temperature."
        }
    }

    /// Calls `body` with a `sockaddr_un` for `path`, or returns nil when the
    /// path is too long for one.
    static func withSocketAddress<T>(
        _ path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Opens a connection to the app's socket, or returns nil if nothing listens.
    static func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let result = withSocketAddress(socketURL.path) { Darwin.connect(fd, $0, $1) }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Reads one newline-terminated message, up to `maxMessageBytes`.
    static func readMessage(from fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < maxMessageBytes {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
            if let newline = data.firstIndex(of: 10) {
                return data[data.startIndex..<newline]
            }
        }
        return nil
    }

    /// Writes `data` and a newline, retrying short writes.
    @discardableResult
    static func writeMessage(_ data: Data, to fd: Int32) -> Bool {
        var message = data
        message.append(10)
        return message.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base + offset, raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }
}
