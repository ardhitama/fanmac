//
//  Client.swift
//  fanmac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Talks to FanMac.app over its control socket, starting the app if needed.
//

import Foundation

struct ClientError: Error {
    let message: String

    static let notRunning = ClientError(message: "FanMac isn’t running.")
    static let noAnswer = ClientError(
        message: "Couldn’t get an answer from FanMac. Quit and reopen FanMac, then try again."
    )
}

enum Client {
    /// FanMac.app's bundle identifier, for `open` when this command runs
    /// outside the app bundle (a development build).
    private static let appBundleIdentifier = "com.ardhitama.fanmac.app"

    /// Sends one request and returns FanMac's answer.
    static func send(_ request: FanMacControl.Request) throws -> FanMacControl.Response {
        guard let fd = FanMacControl.connect() else { throw ClientError.notRunning }
        defer { close(fd) }
        // Fan changes return at once; the helper applies them afterwards.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        guard let data = try? JSONEncoder().encode(request),
              FanMacControl.writeMessage(data, to: fd),
              let reply = FanMacControl.readMessage(from: fd),
              let response = try? JSONDecoder().decode(FanMacControl.Response.self, from: reply)
        else { throw ClientError.noAnswer }
        return response
    }

    /// Sends `request`, starting FanMac first if it isn't running.
    static func sendStartingApp(_ request: FanMacControl.Request, announce: (String) -> Void) throws -> FanMacControl.Response {
        do {
            return try send(request)
        } catch let error as ClientError where error.message == ClientError.notRunning.message {
            announce("Starting FanMac…")
            guard launchApp() else {
                throw ClientError(message: "Couldn’t start FanMac. Open it from Applications, then try again.")
            }
            return try send(request)
        }
    }

    /// Opens FanMac in the background and waits for its socket.
    static func launchApp(timeout: TimeInterval = 15) -> Bool {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let app = enclosingApp() {
            open.arguments = ["-g", app.path]
        } else {
            open.arguments = ["-g", "-b", appBundleIdentifier]
        }
        open.standardError = FileHandle.nullDevice
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            return false
        }
        guard open.terminationStatus == 0 else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let fd = FanMacControl.connect() {
                close(fd)
                return true
            }
            usleep(200_000)
        }
        return false
    }

    /// The FanMac.app this command ships in. It lives at
    /// FanMac.app/Contents/Helpers/fanmac, usually reached through a symlink
    /// on PATH, so resolve the real executable path first.
    static func enclosingApp() -> URL? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        var url = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" { return url }
        }
        return nil
    }
}
