//
//  CommandLineToolTests.swift
//  FanMacTests
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//

import XCTest
@testable import FanMac

final class CommandLineToolTests: XCTestCase {
    private var root: URL!
    private var bundled: URL!
    private var ownLink: String!
    private var brewLink: String!

    override func setUpWithError() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("CommandLineToolTests-\(UUID().uuidString)")
        let helpers = root.appendingPathComponent("Applications/FanMac.app/Contents/Helpers")
        try fm.createDirectory(at: helpers, withIntermediateDirectories: true)
        bundled = helpers.appendingPathComponent("fanmac")
        XCTAssertTrue(fm.createFile(atPath: bundled.path, contents: Data(), attributes: [.posixPermissions: 0o755]))
        for dir in ["usr-local-bin", "homebrew-bin", "Caskroom/fanmac/0.1.0"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        ownLink = root.appendingPathComponent("usr-local-bin/fanmac").path
        brewLink = root.appendingPathComponent("homebrew-bin/fanmac").path
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private var state: CommandLineTool.State {
        CommandLineTool.state(bundled: bundled, linkPaths: [ownLink, brewLink])
    }

    func testNothingLinkedIsNotInstalled() {
        XCTAssertEqual(state, .notInstalled)
    }

    func testSettingsLinkIsInstalled() throws {
        try FileManager.default.createSymbolicLink(atPath: ownLink, withDestinationPath: bundled.path)
        XCTAssertEqual(state, .installed)
    }

    /// Homebrew links through the Caskroom, whose FanMac.app is itself a link
    /// to the copy in Applications.
    func testHomebrewLinkThroughCaskroomIsInstalled() throws {
        let fm = FileManager.default
        let caskApp = root.appendingPathComponent("Caskroom/fanmac/0.1.0/FanMac.app")
        try fm.createSymbolicLink(atPath: caskApp.path, withDestinationPath: root.appendingPathComponent("Applications/FanMac.app").path)
        try fm.createSymbolicLink(atPath: brewLink, withDestinationPath: caskApp.appendingPathComponent("Contents/Helpers/fanmac").path)
        XCTAssertEqual(state, .installed)

        // A stale link at /usr/local/bin doesn't matter while Homebrew's works.
        try fm.createSymbolicLink(atPath: ownLink, withDestinationPath: "/nonexistent/fanmac")
        XCTAssertEqual(state, .installed)
    }

    func testLinkToAnotherCopyIsOtherFile() throws {
        try FileManager.default.createSymbolicLink(atPath: ownLink, withDestinationPath: "/nonexistent/fanmac")
        XCTAssertEqual(state, .otherFile)
    }

    func testPlainFileIsOtherFile() {
        XCTAssertTrue(FileManager.default.createFile(atPath: ownLink, contents: Data()))
        XCTAssertEqual(state, .otherFile)
    }

    func testHomebrewLinkToAnotherCopyDoesNotCount() throws {
        try FileManager.default.createSymbolicLink(atPath: brewLink, withDestinationPath: "/nonexistent/fanmac")
        XCTAssertEqual(state, .notInstalled)
    }
}
