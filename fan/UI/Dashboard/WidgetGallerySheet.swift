//
//  WidgetGallerySheet.swift
//  FanMac
//  Copyright (C) 2026 Ardhitama
//  SPDX-License-Identifier: GPL-3.0-or-later
//  Additional terms for the FanMac name and icon: see NOTICE.
//
//  Widget picker for the popover dashboard.
//

import SwiftUI

struct WidgetGallerySheet: View {
    @ObservedObject var store: DashboardStore
    let targetRowID: UUID
    let hasBattery: Bool
    let hasFans: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredKinds: [DashboardWidgetKind] {
        DashboardWidgetKind.allCases.filter { kind in
            kind.isAvailable(hasBattery: hasBattery, hasFans: hasFans)
                && (searchText.isEmpty
                    || kind.displayName.localizedCaseInsensitiveContains(searchText)
                    || kind.galleryDescription.localizedCaseInsensitiveContains(searchText))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: FanMacTheme.containerInset) {
                    ForEach(filteredKinds) { kind in
                        galleryRow(kind)
                    }
                    if filteredKinds.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
                .padding(FanMacTheme.chromeInset)
            }
            .navigationTitle("Add Widget")
            .searchable(text: $searchText, prompt: Text("Search widgets").foregroundStyle(FanMacTheme.secondaryText))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(width: 320, height: 420)
        .tint(FanMacTheme.accent)
    }

    private func galleryRow(_ kind: DashboardWidgetKind) -> some View {
        let placed = store.isKindPlaced(kind)

        return Button {
            if store.addWidget(kind, toRow: targetRowID) {
                dismiss()
            }
        } label: {
            HStack(spacing: FanMacSpacing.space5) {
                Image(systemName: kind.galleryIcon)
                    .font(.title3)
                    .foregroundStyle(FanMacTheme.secondaryText)
                    .frame(width: FanMacTheme.controlSize)

                VStack(alignment: .leading, spacing: FanMacSpacing.space1) {
                    Text(kind.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(placed ? FanMacTheme.secondaryText : FanMacTheme.text)
                    Text(placed ? "Already on the dashboard" : kind.galleryDescription)
                        .font(.caption)
                        .foregroundStyle(FanMacTheme.secondaryText)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)
            }
            .fanMacCard()
            .contentShape(.rect(cornerRadius: FanMacTheme.cardCornerRadius))
        }
        .buttonStyle(.plain)
        .disabled(placed)
    }
}
