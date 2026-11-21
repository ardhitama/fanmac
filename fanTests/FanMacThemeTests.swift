//
//  FanMacThemeTests.swift
//  FanMacTests
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Every role FanMac draws text or marks in reads on the surfaces it sits
//  on, the canvas and the popover's frost: text at 4.5:1, marks at 3:1
//  (WCAG, as Ardvis's theming rules ask).
//
//  The system's colours resolve under the dark appearance. AppKit hands out
//  its high-contrast variant only while Increase Contrast is on, so the
//  palette's Increase Contrast twins are checked by value, on the same
//  surfaces; the system lifts its own colours under that setting.
//

import AppKit
import SwiftUI
import XCTest
@testable import FanMac

final class FanMacThemeTests: XCTestCase {
    private typealias Twin = (standard: UInt32, increased: UInt32)

    func testSystemTextReadsOnEverySurface() {
        for (surfaceName, surface) in surfaces {
            for (role, color) in [("text", FanMacTheme.text), ("secondaryText", FanMacTheme.secondaryText)] {
                let ratio = contrast(resolved(color), on: surface)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(role) on \(surfaceName): \(ratio)")
            }
        }
    }

    /// The warning is text on a card ("Hot"), the red a notice's title, and
    /// the accent a slider's or switch's fill, all on the popover's frost.
    func testPaletteTextReadsOnEverySurface() {
        let twins: [(String, Twin)] = [
            ("accent", FanMacTheme.Twin.accent),
            ("warning", FanMacTheme.Twin.warning),
            ("destructive", FanMacTheme.Twin.destructive),
        ]
        for (role, twin) in twins {
            for hex in [twin.standard, twin.increased] {
                for (surfaceName, surface) in surfaces {
                    let ratio = contrast(rgba(hex), on: surface)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(role) \(String(hex, radix: 16)) on \(surfaceName): \(ratio)")
                }
            }
        }
    }

    func testStandardPaletteIsWhatDraws() {
        XCTAssertEqual(resolved(FanMacTheme.accent), rgba(FanMacTheme.Twin.accent.standard))
        XCTAssertEqual(resolved(FanMacTheme.warning), rgba(FanMacTheme.Twin.warning.standard))
        XCTAssertEqual(resolved(FanMacTheme.destructive), rgba(FanMacTheme.Twin.destructive.standard))
    }

    func testProminentButtonLabelReadsOnTheAccent() {
        let label = resolved(FanMacTheme.accentText)
        for hex in [FanMacTheme.Twin.accent.standard, FanMacTheme.Twin.accent.increased] {
            let ratio = contrast(label, on: rgba(hex))
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "accentText on \(String(hex, radix: 16)): \(ratio)")
        }
    }

    /// AppKit draws a selected segment's label white on the tint, whatever
    /// the tint is. On the grey accent that read 2.3:1 in a key window.
    func testSegmentedControlLabelReadsOnItsSelection() {
        let ratio = contrast(RGBA(r: 1, g: 1, b: 1, a: 1), on: resolved(FanMacTheme.segmentSelection))
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "white on segmentSelection: \(ratio)")
    }

    func testChromeAccentMarksReadOnEverySurface() {
        let standard = resolved(FanMacTheme.chromeAccent)
        var increased = rgba(FanMacTheme.Twin.accent.increased)
        increased.a = standard.a
        for mark in [standard, increased] {
            for (surfaceName, surface) in surfaces {
                let ratio = contrast(mark, on: surface)
                XCTAssertGreaterThanOrEqual(ratio, 3, "chromeAccent on \(surfaceName): \(ratio)")
            }
        }
    }

    // MARK: - Colour arithmetic

    private struct RGBA: Equatable {
        var r, g, b, a: Double

        static func == (x: RGBA, y: RGBA) -> Bool {
            [x.r - y.r, x.g - y.g, x.b - y.b, x.a - y.a].allSatisfy { abs($0) < 0.002 }
        }
    }

    /// The popover's frost (`FanMacFrost`, the `.sheet` material) in the dark
    /// appearance over a white, a yellow (#FFD600), a green (#337326) and a
    /// black window, sampled in sRGB from screen captures of a key NSPopover
    /// on macOS 27.2 (20 November 2026). The system's own popover glass came
    /// out #696969, #7A6A1C, #3F5F31 and #2B2B2B there, where the secondary
    /// text read 2.8 to 3.4:1 over the bright windows.
    private static let measuredFrost: [(String, UInt32)] = [
        ("white", 0x303030), ("yellow", 0x313027), ("green", 0x2B2E29), ("black", 0x282828),
    ]

    private var surfaces: [(String, RGBA)] {
        [("canvas", resolved(FanMacTheme.canvas))]
            + Self.measuredFrost.map { name, hex in ("the frost over \(name)", rgba(hex)) }
    }

    private func rgba(_ hex: UInt32) -> RGBA {
        RGBA(
            r: Double((hex >> 16) & 0xFF) / 255,
            g: Double((hex >> 8) & 0xFF) / 255,
            b: Double(hex & 0xFF) / 255,
            a: 1
        )
    }

    /// `color` in sRGB as it draws under the dark appearance.
    private func resolved(_ color: Color) -> RGBA {
        var out = RGBA(r: 0, g: 0, b: 0, a: 0)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            let c = NSColor(color).usingColorSpace(.sRGB)!
            out = RGBA(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
        }
        return out
    }

    /// The WCAG contrast of `ink`, composited over an opaque `background`.
    private func contrast(_ ink: RGBA, on background: RGBA) -> Double {
        XCTAssertEqual(background.a, 1, accuracy: 0.001, "a surface must be opaque")
        func mix(_ f: Double, _ b: Double) -> Double { f * ink.a + b * (1 - ink.a) }
        let top = RGBA(r: mix(ink.r, background.r), g: mix(ink.g, background.g), b: mix(ink.b, background.b), a: 1)
        let (l1, l2) = (luminance(top), luminance(background))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private func luminance(_ c: RGBA) -> Double {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.r) + 0.7152 * linear(c.g) + 0.0722 * linear(c.b)
    }
}
