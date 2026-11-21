//
//  FanReleaseWatchdog.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Hands the fans back to macOS when FanMac dies without doing it itself.
//

import Foundation

/// A crash, a force quit or `kill -9` ends FanMac before it can hand the
/// fans back, which would leave them at its last speed with macOS's thermal
/// manager held off. The watchdog is a small shell process that waits on a
/// pipe only FanMac can write to. However FanMac exits, the kernel closes its
/// end, the shell reads end-of-file and runs the helper's `auto` for each fan.
/// A clean quit hands the fans back itself, then sends `disarm` so the shell
/// exits without touching them.
///
/// It uses the same passwordless `sudo -n` rule as FanMac, so it never asks
/// for a password, and it lives only as long as FanMac does. If something
/// ends the watchdog alone, FanMac starts another.
nonisolated final class FanReleaseWatchdog: @unchecked Sendable {
    /// Arguments: fan count, a `pgrep -f` pattern matching speed writes, then
    /// the command that hands one fan back when given `auto <fan>`.
    static let script = #"""
    fans=$1 writes=$2
    shift 2
    # Closing a terminal or pressing Control-C reaches this process too; only
    # FanMac's pipe decides when it acts.
    trap '' HUP INT
    IFS= read -r line
    [ "$line" = disarm ] && exit 0
    # A speed write FanMac started can outlive it and take a fan again, so
    # let it finish first (at most 5 s). pgrep leaves out its own ancestors,
    # so this shell, whose arguments hold the pattern, never matches.
    pids=$(pgrep -f -- "$writes" | paste -sd , -)
    tries=0
    while [ -n "$pids" ] && [ "$tries" -lt 50 ] && ps -p "$pids" >/dev/null 2>&1; do
        sleep 0.1
        tries=$((tries + 1))
    done
    fan=0
    while [ "$fan" -lt "$fans" ]; do
        "$@" auto "$fan" >/dev/null 2>&1
        fan=$((fan + 1))
    done
    """#

    private let lock = NSLock()
    private var process: Process?
    /// FanMac's end of the pipe; -1 once closed.
    private var writeEnd: Int32 = -1
    /// The watchdog's arguments after the script, kept for a restart.
    private var arguments: [String] = []
    /// When the current watchdog started, in seconds of system uptime.
    private var startedAt: TimeInterval = 0

    deinit {
        // Like FanMac exiting: the watchdog reads end-of-file and acts.
        if writeEnd >= 0 { close(writeEnd) }
    }

    /// Whether the watchdog process is running.
    var isWatching: Bool {
        lock.withLock { process?.isRunning ?? false }
    }

    /// Starts the watchdog unless one was started already. `command` hands
    /// one fan back when given `auto <fan>`; `writePattern` matches a speed
    /// write still running in `pgrep -f`. Returns whether it started one.
    @discardableResult
    func arm(fanCount: Int, command: [String], writePattern: String) -> Bool {
        lock.withLock {
            guard process == nil, fanCount > 0, !command.isEmpty else { return false }
            arguments = ["\(fanCount)", writePattern] + command
            return start()
        }
    }

    /// Starts a watchdog process with `arguments`. Holds `lock`.
    private func start() -> Bool {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else {
            print("FanReleaseWatchdog: couldn’t create a pipe: \(String(cString: strerror(errno)))")
            return false
        }
        // Neither the watchdog nor any process FanMac starts later may
        // hold FanMac's end, or the pipe would stay open after FanMac
        // exits. Writing after the watchdog is gone must not raise
        // SIGPIPE, which would kill FanMac.
        _ = fcntl(ends[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(ends[1], F_SETNOSIGPIPE, 1)
        let readEnd = FileHandle(fileDescriptor: ends[0], closeOnDealloc: true)
        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = ["-c", Self.script, "fanmac-watchdog"] + arguments
        watchdog.standardInput = readEnd
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        watchdog.terminationHandler = { [weak self] ended in
            self?.restart(after: ended)
        }
        do {
            try watchdog.run()
        } catch {
            print("FanReleaseWatchdog: couldn’t start: \(error)")
            close(ends[1])
            return false
        }
        try? readEnd.close()
        process = watchdog
        writeEnd = ends[1]
        startedAt = ProcessInfo.processInfo.systemUptime
        return true
    }

    /// A watchdog that exits while FanMac still holds its pipe was ended by
    /// something else (a disarmed one finds the pipe closed). Without a new
    /// one, a later crash would leave the fans at FanMac's last speed. One
    /// that ended within a second isn't restarted here, so a watchdog that
    /// can't run doesn't loop; FanMac's next speed write arms it again.
    private func restart(after ended: Process) {
        lock.withLock {
            guard ended === process, writeEnd >= 0 else { return }
            close(writeEnd)
            writeEnd = -1
            process = nil
            guard ProcessInfo.processInfo.systemUptime - startedAt >= 1 else {
                print("FanReleaseWatchdog: the watchdog ended at once; the next write arms it again")
                return
            }
            print("FanReleaseWatchdog: the watchdog ended early; starting another")
            _ = start()
        }
    }

    /// FanMac has handed the fans back: the watchdog exits without acting.
    func disarm() {
        let fd: Int32 = lock.withLock {
            defer { writeEnd = -1 }
            return writeEnd
        }
        guard fd >= 0 else { return }
        let message = Array("disarm\n".utf8)
        _ = message.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }
}
