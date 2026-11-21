//
//  DashboardGridView.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Widget dashboard with layout-engine-driven drop targeting and visual row packing.
//

import SwiftUI

// MARK: - Drag state

private struct WidgetDragState: Equatable {
    var widgetID: UUID
    var sourceRowID: UUID
    var kind: DashboardWidgetKind
    var columnSpan: Int
    var location: CGPoint
    var grabOffset: CGSize
    var sourceSize: CGSize
}

// MARK: - Grid view

struct DashboardGridView: View {
    @ObservedObject var store: DashboardStore
    @ObservedObject var viewModel: FanControlViewModel
    @ObservedObject var battery: BatteryMonitor
    @Binding var isEditing: Bool

    @State private var galleryRowID: UUID?
    @State private var showGallery = false

    @State private var dragState: WidgetDragState?
    @State private var activeDropSlot: DropSlotID?

    @State private var widgetFrames: [UUID: CGRect] = [:]
    @State private var dropSlotFrames: [DropSlotID: CGRect] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let gridSpace: CoordinateSpace = .named("dashboardGrid")

    var body: some View {
        VStack(spacing: FanMacTheme.containerInset) {
            // Editing shows every row, so a hidden widget can still be moved
            // or removed.
            ForEach(store.layout.rows.filter { isEditing || isShown($0) }) { row in
                dashboardRow(row)
            }

            if isEditing {
                addRowButton
            }
        }
        .coordinateSpace(name: "dashboardGrid")
        .onPreferenceChange(WidgetFramePreferenceKey.self) { widgetFrames = $0 }
        .onPreferenceChange(DropSlotFramePreferenceKey.self) { dropSlotFrames = $0 }
        .overlay(alignment: .topLeading) {
            dragPreview
        }
        .animation(FanMacMotion.panel(reduceMotion: reduceMotion), value: store.layout)
        .animation(FanMacMotion.selection(reduceMotion: reduceMotion), value: activeDropSlot)
        .sheet(isPresented: $showGallery) {
            if let rowID = galleryRowID {
                WidgetGallerySheet(store: store, targetRowID: rowID, hasBattery: battery.hasBattery, hasFans: !viewModel.hasNoFans)
            }
        }
        .onChange(of: isEditing) { _, editing in
            if !editing {
                dragState = nil
                activeDropSlot = nil
            }
        }
    }

    // MARK: - Row

    private func isShown(_ row: DashboardRow) -> Bool {
        row.isShown(
            hasBattery: battery.hasBattery,
            hasFans: !viewModel.hasNoFans,
            isAuto: viewModel.controlMode == .automatic
        )
    }

    private func dashboardRow(_ row: DashboardRow) -> some View {
        VStack(spacing: FanMacSpacing.space2) {
            if isEditing {
                rowToolbar(row)
            }

            ForEach(DashboardLayoutEngine.renderSegments(for: row)) { segment in
                switch segment {
                case .dropZone(let index):
                    dropZone(row: row, index: index)
                case .widget(let widget):
                    widgetCell(widget, in: row)
                        .opacity(dragState?.widgetID == widget.id ? 0.15 : 1)
                case .pair(let left, let right):
                    HStack(spacing: FanMacTheme.containerInset) {
                        widgetCell(left, in: row)
                            .frame(maxWidth: .infinity)
                            .opacity(dragState?.widgetID == left.id ? 0.15 : 1)
                        widgetCell(right, in: row)
                            .frame(maxWidth: .infinity)
                            .opacity(dragState?.widgetID == right.id ? 0.15 : 1)
                    }
                    // Both cards take the taller one's height and end level.
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func dropZone(row: DashboardRow, index: Int) -> some View {
        if isEditing {
            let slot = DropSlotID(rowID: row.id, index: index)
            DashboardDropZone(slot: slot, isActive: activeDropSlot == slot)
        }
    }

    // MARK: - Widget cell

    private func widgetCell(_ widget: DashboardWidget, in row: DashboardRow) -> some View {
        let isDragging = dragState?.widgetID == widget.id

        return ZStack(alignment: .topTrailing) {
            DashboardWidgetView(
                widget: widget,
                viewModel: viewModel,
                battery: battery,
                isEditing: isEditing
            )

            if isEditing && !isDragging {
                WidgetRemoveBadge {
                    withAnimation(FanMacMotion.panel(reduceMotion: reduceMotion)) {
                        store.removeWidget(id: widget.id)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .trackWidgetFrame(id: widget.id, in: gridSpace)
        .highPriorityGesture(isEditing ? dragGesture(for: widget, in: row) : nil)
    }

    // MARK: - Drag

    private func dragGesture(for widget: DashboardWidget, in row: DashboardRow) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: gridSpace)
            .onChanged { value in
                guard isEditing else { return }

                if dragState == nil {
                    let frame = widgetFrames[widget.id] ?? .zero
                    dragState = WidgetDragState(
                        widgetID: widget.id,
                        sourceRowID: row.id,
                        kind: widget.kind,
                        columnSpan: widget.columnSpan,
                        location: value.location,
                        grabOffset: CGSize(
                            width: value.startLocation.x - frame.minX,
                            height: value.startLocation.y - frame.minY
                        ),
                        sourceSize: frame.size == .zero ? CGSize(width: 148, height: 72) : frame.size
                    )
                } else {
                    dragState?.location = value.location
                }

                activeDropSlot = DashboardLayoutEngine.resolveDropSlot(
                    at: value.location,
                    slotFrames: dropSlotFrames,
                    excludingWidgetID: widget.id,
                    layout: store.layout
                )
            }
            .onEnded { _ in
                commitDrop()
            }
    }

    private func commitDrop() {
        defer {
            dragState = nil
            activeDropSlot = nil
        }

        guard let drag = dragState,
              let slot = activeDropSlot,
              !DashboardLayoutEngine.isNoOpDrop(
                slot: slot,
                draggedWidgetID: drag.widgetID,
                sourceRowID: drag.sourceRowID,
                layout: store.layout
              )
        else { return }

        withAnimation(FanMacMotion.panel(reduceMotion: reduceMotion)) {
            store.applyDrop(widgetID: drag.widgetID, to: slot)
        }
    }

    // MARK: - Drag preview (uses measured source size)

    @ViewBuilder
    private var dragPreview: some View {
        if let drag = dragState {
            let widget = DashboardWidget(
                id: drag.widgetID,
                kind: drag.kind,
                columnSpan: drag.columnSpan
            )
            let origin = CGPoint(
                x: drag.location.x - drag.grabOffset.width,
                y: drag.location.y - drag.grabOffset.height
            )

            DashboardWidgetView(
                widget: widget,
                viewModel: viewModel,
                battery: battery,
                isEditing: true
            )
            .frame(width: drag.sourceSize.width, height: drag.sourceSize.height)
            .offset(x: origin.x, y: origin.y)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Toolbar

    /// A row's columns and actions. They sit on the popover's frost, so each
    /// is a bordered fill, never glass.
    private func rowToolbar(_ row: DashboardRow) -> some View {
        HStack(spacing: FanMacSpacing.space4) {
            FanMacSegmentedPicker(
                title: "Columns",
                options: [(1, "1 Column"), (2, "2 Columns")],
                selection: Binding(
                    get: { row.columns },
                    set: { columns in
                        withAnimation(FanMacMotion.panel(reduceMotion: reduceMotion)) {
                            store.setRowColumns(rowID: row.id, columns: columns)
                        }
                    }
                )
            )
            .fixedSize()

            Spacer()

            Button {
                galleryRowID = row.id
                showGallery = true
            } label: {
                Label("Add Widget", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .help("Add Widget")

            if store.layout.rows.count > 1 {
                Button {
                    withAnimation(FanMacMotion.panel(reduceMotion: reduceMotion)) { store.removeRow(id: row.id) }
                } label: {
                    Label("Remove Row", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .help("Remove Row")
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.small)
    }

    private var addRowButton: some View {
        Button {
            withAnimation(FanMacMotion.panel(reduceMotion: reduceMotion)) { store.addRow(columns: 2) }
        } label: {
            Label("Add Row", systemImage: "plus")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}
