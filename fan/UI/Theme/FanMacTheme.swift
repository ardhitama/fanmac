//
//  FanMacTheme.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Ardvis Dark palette and the few shapes FanMac draws itself.
//

import AppKit
import SwiftUI

/// Ardvis Dark roles, as `ArdvisTheme.ardvisDark` defines them in Ardvis Kit
/// 0.94, a design system FanMac follows but doesn't link, so a palette change
/// there needs the same change here.
///
/// Surfaces and text are the system's semantic colours, so they follow the
/// dark appearance and Increase Contrast by themselves. The palette defines
/// only what the system has no role for: the grey accent and the status
/// colours, each with its Increase Contrast twin. Text comes in two roles at
/// full strength; never fade it with opacity, since the system's tertiary
/// label reads under 4.5:1.
enum FanMacTheme {
    // Surfaces. Regions part by one step in tone, never by a drawn line.
    /// The system's background.
    static let canvas = system(.windowBackgroundColor)
    // The popover is one frosted surface, `FanMacFrost`, over its whole
    // shape, arrow included, and cards draw no fill on it (the person,
    // 20 November 2026: "use full frost", "no need background color", "the
    // tip at the top should use the same color as the rest"). Ardvis leaves
    // a popover the system's glass, but that glass is clear: measured over a
    // white, yellow, green and black window, the secondary text read only
    // 2.8 to 3.4:1 on it over the bright ones. On the frost every text role
    // reads at 4.5:1 and the accent's marks at 3:1 (`FanMacThemeTests`).
    /// A well inside a card, such as a meter's track: the system's fill,
    /// which steps up from whatever surface it is drawn on.
    static let fill = system(.systemFill)

    // Text.
    static let text = system(.labelColor)
    static let secondaryText = system(.secondaryLabelColor)

    // Accent and status. Full strength only for what needs the person; a calm
    // status or an active marker takes `chromeAccent` or plain text.
    /// A neutral grey: a control that is on, selected or primary stands out by
    /// tone, and colour is left to status.
    static let accent = adaptive(Twin.accent)
    /// Text on the accent.
    static let accentText = canvas
    static let warning = adaptive(Twin.warning)
    static let destructive = adaptive(Twin.destructive)

    /// Each palette colour, as `0xRRGGBB`, and its Increase Contrast twin:
    /// the same hue, lighter.
    enum Twin {
        static let accent: (standard: UInt32, increased: UInt32) = (0xA3A3A3, 0xBCBCBC)
        static let warning: (standard: UInt32, increased: UInt32) = (0xE2C08D, 0xECD6B6)
        static let destructive: (standard: UInt32, increased: UInt32) = (0xFF664A, 0xFF917D)
    }

    /// The accent dimmed to 75%, 3:1 on every surface: for marks that ask
    /// nothing of the person, such as a drop target's.
    static let chromeAccent = accent.opacity(0.75)

    /// A segmented control's tint: the grey the system gives the selected
    /// segment in an inactive window, so a selection is a dim highlight in
    /// every window state. AppKit draws the label white on whatever the tint
    /// is, which on the accent came out at 2.3:1 in a key window; on this
    /// grey it measured 5.9:1.
    static let segmentSelection = Color(nsColor: NSColor(hex: 0x5B5B5B))

    /// The padding between a container's edge and what it holds, and the
    /// margin round it (Ardvis's `containerInset`, Spotlight's). A card's
    /// corner is concentric with the text inside, which counts as 0.
    static let containerInset: CGFloat = 10
    static let cardCornerRadius: CGFloat = containerInset
    /// Leading inset of text outside cards, so it lines up with the cards' text.
    static let chromeInset: CGFloat = containerInset * 2
    /// The Mac's smallest control, and an icon button's square.
    static let controlSize: CGFloat = 24

    /// Puts every window, popover, menu and alert under the dark appearance.
    @MainActor
    static func applyToApplication() {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    /// A role the system's semantic colour plays, resolved as it draws.
    private static func system(_ color: NSColor) -> Color {
        Color(nsColor: color)
    }

    /// The standard colour, or its twin while Increase Contrast swaps the
    /// app's dark appearance for its high-contrast variant.
    private static func adaptive(_ twin: (standard: UInt32, increased: UInt32)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let highContrast = appearance.bestMatch(from: [.darkAqua, .accessibilityHighContrastDarkAqua])
                == .accessibilityHighContrastDarkAqua
            return NSColor(hex: highContrast ? twin.increased : twin.standard)
        })
    }
}

/// The one spacing scale (Ardvis's `ArdvisSpacing`): every padding, gap and
/// inset FanMac sets itself is a step of it, so edges line up across cards.
enum FanMacSpacing {
    static let space1: CGFloat = 2
    static let space2: CGFloat = 4
    static let space3: CGFloat = 6
    static let space4: CGFloat = 8
    static let space5: CGFloat = 12
    static let space6: CGFloat = 16
    static let space7: CGFloat = 20
    static let space8: CGFloat = 24
}

/// Motion (Ardvis's `ArdvisMotion`): each token is nil under Reduce Motion.
enum FanMacMotion {
    /// A layout change, such as a card added, removed or moved.
    static func panel(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    /// A small mark that changes under the pointer, such as a drop target.
    static func selection(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.18)
    }
}

extension NSColor {
    /// An sRGB colour written as `0xRRGGBB`.
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// The popover's background: the system's `.sheet` frosted material, which
/// blurs what lies behind the popover and holds the text at 4.5:1 over any
/// window (see `FanMacTheme.canvas`). Under Reduce Transparency the system
/// makes it opaque.
struct FanMacFrost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sheet
        view.blendingMode = .behindWindow
        // Frosted whether or not the popover is the key window.
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

extension View {
    /// A card on the popover's frost: its content inset, with no fill,
    /// border or shadow. It fills the height its row gives it, so cards side
    /// by side end level.
    func fanMacCard() -> some View {
        padding(FanMacTheme.containerInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A card's title: the secondary text, so the value under it leads.
    func fanMacCardTitle() -> some View {
        font(.subheadline.weight(.semibold))
            .foregroundStyle(FanMacTheme.secondaryText)
            .accessibilityAddTraits(.isHeader)
    }

    /// The one primary action: the system's bordered prominent button in the
    /// accent, its label in the accent's text colour so it reads on the grey.
    /// On the popover's frost a button is a bordered fill, never glass.
    func fanMacProminentButton() -> some View {
        buttonStyle(FanMacProminentButtonStyle())
    }
}

/// AppKit draws a prominent button's label white over any foreground style
/// set on the button, which on the grey accent read 2.5:1 in a key window, so
/// the style colours the label itself.
private struct FanMacProminentButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FanMacProminentButton(configuration: configuration)
    }
}

private struct FanMacProminentButton: View {
    let configuration: PrimitiveButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.foregroundStyle(label)
        }
        .buttonStyle(.borderedProminent)
        .tint(FanMacTheme.accent)
    }

    /// A disabled button, or one in an inactive window, loses the accent for
    /// the system's grey, so its label takes the system's text colour.
    private var label: Color {
        guard isEnabled else { return FanMacTheme.secondaryText }
        return controlActiveState == .inactive ? FanMacTheme.text : FanMacTheme.accentText
    }
}

extension Binding where Value == Double {
    /// Snaps to `step` from the range's start, as `Slider(step:)` does, without
    /// the tick marks `step:` draws.
    func snapped(to step: Double, in range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { wrappedValue },
            set: { newValue in
                let steps = ((newValue - range.lowerBound) / step).rounded()
                wrappedValue = Swift.min(range.upperBound, Swift.max(range.lowerBound, range.lowerBound + steps * step))
            }
        )
    }
}

/// A thin capsule meter: the system's fill as its track.
struct FanMacMeter: View {
    /// Fraction filled, clamped to 0...1.
    let fraction: Double
    var fill: Color = FanMacTheme.secondaryText

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(FanMacTheme.fill)
                Capsule()
                    .fill(fill)
                    .frame(width: geo.size.width * min(1, max(0, fraction.isFinite ? fraction : 0)))
            }
        }
        .frame(height: FanMacSpacing.space2)
        .accessibilityHidden(true)
    }
}

/// A few mutually exclusive choices in a row: the system's segmented control,
/// or a menu where the labels can't all fit (Ardvis's `ArdvisSegmentedPicker`).
struct FanMacSegmentedPicker<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker.pickerStyle(.segmented).fixedSize().tint(FanMacTheme.segmentSelection)
            picker.pickerStyle(.menu).fixedSize()
        }
    }

    private var picker: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
        }
        .labelsHidden()
    }
}

extension ProcessInfo.ThermalState {
    /// The names macOS uses for thermal pressure.
    var title: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Moderate"
        case .serious: return "Heavy"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    /// From heavy pressure on, macOS lowers CPU and GPU clocks to shed heat.
    var limitsPerformance: Bool {
        self == .serious || self == .critical
    }
}
