//
//  ControlServer.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Serves the `fanmac` command over a UNIX socket (see FanMacControl). The
//  command changes fans only through here, so the app stays their one driver.
//

import Darwin
import Foundation

final class ControlServer {
    typealias Request = FanMacControl.Request
    typealias Response = FanMacControl.Response

    private let viewModel: FanControlViewModel
    private let permissions = PermissionsManager.shared
    private let socketPath = FanMacControl.socketURL.path
    private var listenSocket: Int32 = -1

    init(viewModel: FanControlViewModel) {
        self.viewModel = viewModel
    }

    /// Starts listening, unless another FanMac already serves the socket.
    func start() {
        let directory = FanMacControl.socketURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            print("ControlServer: couldn’t prepare \(directory.path): \(error)")
            return
        }

        if let existing = FanMacControl.connect() {
            close(existing)
            print("ControlServer: another FanMac already serves \(socketPath)")
            return
        }
        unlink(socketPath) // a stale socket left by a crash

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("ControlServer: socket() failed: \(String(cString: strerror(errno)))")
            return
        }
        let bound = FanMacControl.withSocketAddress(socketPath) { bind(fd, $0, $1) }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(fd, 8) == 0 else {
            print("ControlServer: couldn’t listen on \(socketPath): \(String(cString: strerror(errno)))")
            close(fd)
            return
        }
        listenSocket = fd

        // Requests arrive on the server thread; the view model lives on main.
        let handler: @Sendable (Request) -> Response = { [weak self] request in
            // `fanmac` starts FanMac and sends its change at once, before
            // FanMac has read the fans. Applied then, a speed would clamp to
            // placeholder limits and the answer would say macOS controls the
            // fans, so a change waits for FanMac to be ready: until it has
            // read the fans, or found that the Mac has none. The wait is
            // bounded because an SMC that never answers leaves FanMac
            // waiting; `fanmac` waits 5 s.
            if request.command != .status {
                let deadline = Date().addingTimeInterval(3)
                while Date() < deadline, !DispatchQueue.main.sync(execute: {
                    MainActor.assumeIsolated { self?.viewModel.fanController.isReady ?? true }
                }) {
                    usleep(50_000)
                }
            }
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    self?.respond(to: request) ?? Response(status: nil, error: "FanMac is quitting.")
                }
            }
        }
        Thread.detachNewThread {
            Self.acceptLoop(fd, handler: handler)
        }
        print("ControlServer: listening on \(socketPath)")
    }

    func stop() {
        guard listenSocket >= 0 else { return }
        close(listenSocket)
        listenSocket = -1
        unlink(socketPath)
    }

    // MARK: - Socket thread

    nonisolated private static func acceptLoop(_ fd: Int32, handler: @Sendable (Request) -> Response) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return // stop() closed the socket
            }
            serve(client, handler: handler)
            close(client)
        }
    }

    /// Answers one client. Internal so tests can serve a socket directly.
    nonisolated static func serve(
        _ client: Int32,
        handler: @Sendable (FanMacControl.Request) -> FanMacControl.Response
    ) {
        // The socket is already private to this user; check the peer anyway.
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }

        // Writing to a client that hung up raises SIGPIPE, which kills
        // FanMac. macOS refuses this option once the client has hung up,
        // as `fanmac` and a second FanMac do after checking that FanMac
        // runs; there is no one left to answer then.
        var noSigPipe: Int32 = 1
        guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let response: Response
        if let message = FanMacControl.readMessage(from: client),
           let request = try? JSONDecoder().decode(Request.self, from: message) {
            response = handler(request)
        } else {
            response = Response(status: nil, error: "FanMac couldn’t read the request. Update fanmac and FanMac to the same version.")
        }
        if let data = try? JSONEncoder().encode(response) {
            FanMacControl.writeMessage(data, to: client)
        }
    }

    // MARK: - Requests

    func respond(to request: Request) -> Response {
        let error = apply(request)
        return Response(status: status(), error: error)
    }

    /// Checks the whole request before changing anything. Returns an error to
    /// show the person, or nil once the change is under way.
    private func apply(_ request: Request) -> String? {
        let vm = viewModel
        // The controller is the source of truth; the view model receives its
        // changes a run loop turn later, after this reply is built.
        let controller = vm.fanController
        if request.command != .status, controller.hasNoFans {
            return FanMacControl.noFansMessage
        }
        switch request.command {
        case .status:
            return nil

        case .setMode:
            guard let mode = request.mode else { return "Choose manual or auto." }
            if let problem = helperProblem { return problem }
            vm.setControlMode(mode == .manual ? .manual : .automatic)

        case .setManualSpeed:
            if let problem = helperProblem { return problem }
            if let rpm = request.rpm, rpm <= 0 {
                return "Give the speed in RPM, such as 3000."
            }
            if let fan = request.fan {
                guard (0..<vm.numberOfFans).contains(fan) else {
                    return vm.numberOfFans == 1
                        ? "This Mac has one fan."
                        : "This Mac has \(vm.numberOfFans) fans. Choose one from 1 to \(vm.numberOfFans)."
                }
                guard request.rpm != nil else { return "Give a speed for fan \(fan + 1)." }
            }
            if let rpm = request.rpm {
                controller.switchToManual(speed: rpm, fan: request.fan)
            } else if controller.mode != .manual {
                vm.setControlMode(.manual)
            }

        case .setAuto:
            if let problem = helperProblem { return problem }
            if let start = request.speedUpFrom, !FanMacControl.speedUpFromRange.contains(start) {
                return "Speed up from must be 40–90 °C."
            }
            if let response = request.response, !FanCurve.responseRange.contains(response) {
                return "Response must be 0–3."
            }
            if let maxSpeed = request.maxSpeed, maxSpeed <= 0 {
                return "Give the max speed in RPM, such as 5000."
            }
            if controller.mode != .automatic {
                vm.setControlMode(.automatic)
            }
            if let start = request.speedUpFrom { vm.setAutoThreshold(start) }
            if let maxSpeed = request.maxSpeed { vm.setAutoMaxSpeed(maxSpeed) }
            if let response = request.response { vm.setAutoAggressiveness(response) }
        }
        return nil
    }

    private var helperProblem: String? {
        if !permissions.isHelperInstalled {
            return "The helper isn’t installed. Click the FanMac menu bar icon, then Install Helper."
        }
        if permissions.isHelperOutdated {
            return "The helper needs an update. Click the FanMac menu bar icon, then Update Helper."
        }
        return nil
    }

    /// Sensor readings come from the view model; control state from the
    /// controller, so a reply reflects the change it answers.
    private func status() -> FanMacControl.Status {
        let vm = viewModel
        let controller = vm.fanController
        let fans = (0..<vm.numberOfFans).map { i in
            FanMacControl.Fan(
                rpm: i < vm.fanSpeeds.count ? vm.fanSpeeds[i] : 0,
                target: controller.isControlEnabled && i < controller.appliedTargets.count ? controller.appliedTargets[i] : nil,
                minRPM: vm.minRPM(atFan: i),
                maxRPM: vm.maxRPM(atFan: i)
            )
        }
        return FanMacControl.Status(
            mode: controller.mode == .manual ? .manual : .auto,
            controlledByFanMac: controller.isControlEnabled,
            helperInstalled: permissions.isHelperInstalled,
            helperNeedsUpdate: permissions.isHelperOutdated,
            cpuTemperature: vm.cpuTemperature,
            gpuTemperature: vm.gpuTemperature,
            thermalPressure: vm.thermalState.title,
            thermalPressureLimitsPerformance: vm.thermalState.limitsPerformance,
            fans: fans,
            manualSpeed: controller.manualSpeed,
            manualSpeedPerFan: controller.perFanManualControl && vm.numberOfFans > 1 ? controller.manualSpeeds : nil,
            speedUpFrom: controller.autoThreshold,
            maxSpeed: controller.autoMaxSpeed,
            response: controller.autoAggressiveness,
            problem: controller.lastFailure.map { "\($0.summary) \($0.recovery)" },
            hasNoFans: controller.hasNoFans
        )
    }
}
