//
//  DashboardStoreTests.swift
//  fanTests
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//

import AppKit
import XCTest
@testable import FanMac

final class DashboardStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "DashboardStoreTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultLayoutWithBattery() {
        let layout = DashboardStore.defaultLayout(hasBattery: true)
        XCTAssertTrue(layout.placedKinds.contains(.cpuTemperature))
        XCTAssertTrue(layout.placedKinds.contains(.powerOrSystem))
        XCTAssertTrue(layout.placedKinds.contains(.fanControl))
        XCTAssertFalse(layout.placedKinds.contains(.gpuTemperature))
        // Battery and System are opt-in from the gallery.
        XCTAssertFalse(layout.placedKinds.contains(.batteryInfo))
        XCTAssertFalse(layout.placedKinds.contains(.systemInfo))
    }

    func testDefaultLayoutDesktop() {
        let layout = DashboardStore.defaultLayout(hasBattery: false)
        XCTAssertTrue(layout.placedKinds.contains(.gpuTemperature))
        XCTAssertFalse(layout.placedKinds.contains(.batteryInfo))
    }

    func testEncodeDecodeRoundTrip() throws {
        var layout = DashboardStore.defaultLayout(hasBattery: true)
        layout.rows[0].widgets[0].id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(DashboardLayout.self, from: data)

        XCTAssertEqual(decoded, layout)
    }

    func testAddWidgetPreventsDuplicates() {
        defaults.set(nil, forKey: "dashboardLayout")
        let store = DashboardStore(defaults: defaults)
        guard let rowID = store.layout.rows.first?.id else {
            XCTFail("Expected default row")
            return
        }

        XCTAssertFalse(store.addWidget(.cpuTemperature, toRow: rowID))
    }

    func testAddAndRemoveWidget() {
        defaults.removeObject(forKey: "dashboardLayout")
        let store = DashboardStore(defaults: defaults)

        store.addRow(columns: 2)
        guard let rowID = store.layout.rows.last?.id else {
            XCTFail("Expected new row")
            return
        }

        // The default layout differs with and without a battery, so add a
        // kind it left out.
        guard let kind = DashboardWidgetKind.allCases.first(where: {
            !store.isKindPlaced($0) && DashboardWidget(kind: $0).columnSpan <= 2
        }) else {
            XCTFail("Expected a widget kind the default layout leaves out")
            return
        }
        XCTAssertTrue(store.addWidget(kind, toRow: rowID))
        XCTAssertTrue(store.isKindPlaced(kind))
        XCTAssertFalse(store.addWidget(kind, toRow: rowID), "a kind is placed at most once")

        guard let widgetID = store.layout.rows.last?.widgets.first?.id else {
            XCTFail("Expected the added widget")
            return
        }
        store.removeWidget(id: widgetID)
        XCTAssertFalse(store.isKindPlaced(kind))
    }

    func testSetRowColumns() {
        defaults.removeObject(forKey: "dashboardLayout")
        let store = DashboardStore(defaults: defaults)
        guard let rowID = store.layout.rows.first?.id else { return }

        store.setRowColumns(rowID: rowID, columns: 1)
        XCTAssertEqual(store.layout.rows.first?.columns, 1)
    }

    func testApplyDropReordersWithinRow() {
        defaults.removeObject(forKey: "dashboardLayout")
        let store = DashboardStore(defaults: defaults)
        guard let row = store.layout.rows.first, row.widgets.count >= 2 else { return }

        let first = row.widgets[0]
        let second = row.widgets[1]
        store.applyDrop(widgetID: second.id, to: DropSlotID(rowID: row.id, index: 0))

        XCTAssertEqual(store.layout.rows.first?.widgets.first?.id, second.id)
        XCTAssertEqual(store.layout.rows.first?.widgets[1].id, first.id)
    }

    func testRenderSegmentsPairsHalfWidthWidgets() {
        let row = DashboardRow(columns: 2, widgets: [
            DashboardWidget(kind: .cpuTemperature),
            DashboardWidget(kind: .gpuTemperature)
        ])
        let segments = DashboardLayoutEngine.renderSegments(for: row)
        XCTAssertTrue(segments.contains { if case .pair = $0 { return true } else { return false } })
    }

    func testResolveDropSlotPicksNearest() {
        let rowID = UUID()
        let slot = DropSlotID(rowID: rowID, index: 1)
        let frames: [DropSlotID: CGRect] = [
            DropSlotID(rowID: rowID, index: 0): CGRect(x: 0, y: 0, width: 300, height: 12),
            slot: CGRect(x: 0, y: 80, width: 300, height: 12)
        ]
        let layout = DashboardLayout(rows: [
            DashboardRow(id: rowID, columns: 2, widgets: [
                DashboardWidget(kind: .cpuTemperature),
                DashboardWidget(kind: .gpuTemperature)
            ])
        ])
        let widgetID = layout.rows[0].widgets[0].id
        let resolved = DashboardLayoutEngine.resolveDropSlot(
            at: CGPoint(x: 150, y: 86),
            slotFrames: frames,
            excludingWidgetID: widgetID,
            layout: layout
        )
        XCTAssertEqual(resolved, slot)
    }

    func testDevicePowerProfileMapping() {
        let monitor = BatteryMonitor.shared
        if monitor.hasBattery {
            XCTAssertEqual(monitor.devicePowerProfile, .battery)
        } else {
            XCTAssertEqual(monitor.devicePowerProfile, .desktop)
        }
    }

    /// A row of widgets that draw nothing must not show: it would still add a
    /// gap under the last card. Manual hides the Auto curve's row; a Mac
    /// without fans shows only its temperatures and power.
    func testRowsThatDrawNothingAreHidden() {
        let rows = DashboardStore.defaultLayout(hasBattery: true).rows
        func shown(hasFans: Bool, isAuto: Bool) -> [[DashboardWidgetKind]] {
            rows.filter { $0.isShown(hasBattery: true, hasFans: hasFans, isAuto: isAuto) }.map { $0.widgets.map(\.kind) }
        }
        XCTAssertEqual(shown(hasFans: true, isAuto: true), [[.cpuTemperature, .powerOrSystem], [.fanControl], [.autoModeSettings]])
        XCTAssertEqual(shown(hasFans: true, isAuto: false), [[.cpuTemperature, .powerOrSystem], [.fanControl]])
        XCTAssertEqual(shown(hasFans: false, isAuto: true), [[.cpuTemperature, .powerOrSystem]])
    }

    /// A name SF Symbols doesn't have draws nothing, leaving a gap in the
    /// gallery where the icon goes.
    func testEveryGalleryIconExists() {
        for kind in DashboardWidgetKind.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: kind.galleryIcon, accessibilityDescription: nil),
                            "\(kind): no symbol named \(kind.galleryIcon)")
        }
    }

    /// The gallery doesn't offer fan widgets on a Mac without fans.
    func testFanWidgetsNeedFans() {
        for kind in DashboardWidgetKind.allCases {
            let needsFans = kind == .fanControl || kind == .autoModeSettings
            XCTAssertEqual(kind.isAvailable(hasBattery: true, hasFans: false), !needsFans, kind.rawValue)
            XCTAssertTrue(kind.isAvailable(hasBattery: true, hasFans: true), kind.rawValue)
        }
    }

    /// The card shows the battery's power, or fan load without a battery;
    /// with neither, it has nothing to show.
    func testPowerOrFanLoadNeedsABatteryOrFans() {
        XCTAssertTrue(DashboardWidgetKind.powerOrSystem.isAvailable(hasBattery: true, hasFans: false))
        XCTAssertTrue(DashboardWidgetKind.powerOrSystem.isAvailable(hasBattery: false, hasFans: true))
        XCTAssertFalse(DashboardWidgetKind.powerOrSystem.isAvailable(hasBattery: false, hasFans: false))
    }
}
