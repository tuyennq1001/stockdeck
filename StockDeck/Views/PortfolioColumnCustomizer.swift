import SwiftUI

/// Preset configurations for quick selection in Portfolio Column Customizer.
enum PortfolioColumnPreset: String, CaseIterable, Identifiable {
    case custom = "Custom"
    case defaultPreset = "Default"
    case overview = "Overview"
    case minimal = "Minimal"

    var id: String { rawValue }

    var columns: [PortfolioColumnMetric] {
        switch self {
        case .custom:
            return PortfolioColumnMetric.defaultSelection
        case .defaultPreset:
            return PortfolioColumnMetric.defaultSelection
        case .overview:
            return [.price, .ext, .todayPnl, .totalPnl, .weight]
        case .minimal:
            return [.price, .totalPnl]
        }
    }
}

/// A staging sheet: nothing is persisted until the user chooses Apply.
struct PortfolioColumnCustomizer: View {
    let initialColumns: [PortfolioColumnMetric]
    let onApply: ([PortfolioColumnMetric]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var columns: [PortfolioColumnMetric]
    @State private var selectedPreset: PortfolioColumnPreset = .custom
    @State private var draggingColumn: PortfolioColumnMetric?

    init(initialColumns: [PortfolioColumnMetric], onApply: @escaping ([PortfolioColumnMetric]) -> Void) {
        self.initialColumns = initialColumns
        self.onApply = onApply
        _columns = State(initialValue: initialColumns)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Customize Columns")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(DS.ink)
                    Text("# and Symbol are always shown. Add, delete and sort the rest just how you need it.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DS.inkSecondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DS.inkSecondary)
                        .padding(8)
                        .background(Circle().fill(DS.cardAlt))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)

            // Preset Controls Bar
            HStack {
                Menu {
                    ForEach(PortfolioColumnPreset.allCases) { preset in
                        Button(preset.rawValue) {
                            selectedPreset = preset
                            if preset != .custom {
                                columns = preset.columns
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(selectedPreset.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(DS.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.cardAlt))
                }
                .menuStyle(.borderlessButton)
                .pointingHandCursor()

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.25)) {
                        columns = initialColumns
                        selectedPreset = .custom
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .bold))
                        Text("Restart")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(DS.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.cardAlt))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)

            // Fixed columns note
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DS.brand)
                Text("Fixed columns: # · Symbol")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.inkSecondary)
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)

            // Selected Columns Box (Top Container)
            VStack(alignment: .leading, spacing: 0) {
                if columns.isEmpty {
                    Text("No columns selected. Click metrics below to add.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DS.inkTertiary)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                            selectedColumnPill(column: column, index: index + 1)
                        }
                    }
                    .padding(14)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(DS.cardAlt.opacity(0.6)))
            .padding(.horizontal, 28)
            .padding(.top, 14)

            Divider()
                .overlay(DS.hairline)
                .padding(.horizontal, 28)
                .padding(.top, 18)

            // Category Sections
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(PortfolioColumnCategory.allCases) { category in
                        categorySection(category: category)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
            }

            Divider()
                .overlay(DS.hairline)

            // Footer Action Bar
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.inkSecondary)
                .pointingHandCursor()

                Button {
                    onApply(columns)
                    dismiss()
                } label: {
                    Text("Apply Changes")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(DS.brand))
                }
                .buttonStyle(.plain)
                .disabled(columns.isEmpty)
                .pointingHandCursor()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .frame(width: 720, height: 600)
        .background(DS.ground)
    }

    // MARK: - Selected Column Pill in Top Container

    @ViewBuilder
    private func selectedColumnPill(column: PortfolioColumnMetric, index: Int) -> some View {
        HStack(spacing: 6) {
            Text("\(index)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(DS.ink)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.white))
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)

            Text(column.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.ink)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DS.inkTertiary)
        }
        .padding(.leading, 6)
        .padding(.trailing, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        .onTapGesture {
            withAnimation(.spring(response: 0.2)) {
                columns.removeAll { $0 == column }
                selectedPreset = .custom
            }
        }
        .onDrag {
            self.draggingColumn = column
            return NSItemProvider(object: column.rawValue as NSString)
        }
        .onDrop(of: [.text], delegate: PortfolioColumnPillDropDelegate(
            targetColumn: column,
            draggingColumn: $draggingColumn,
            onMove: { src, tgt in
                if let srcIdx = columns.firstIndex(of: src),
                   let tgtIdx = columns.firstIndex(of: tgt) {
                    withAnimation(.spring(response: 0.2)) {
                        columns.move(fromOffsets: IndexSet(integer: srcIdx), toOffset: tgtIdx > srcIdx ? tgtIdx + 1 : tgtIdx)
                    }
                }
            }
        ))
        .pointingHandCursor()
    }

    // MARK: - Category Section & Pills

    @ViewBuilder
    private func categorySection(category: PortfolioColumnCategory) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Text(category.rawValue)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DS.inkSecondary)
                .frame(width: 110, alignment: .leading)
                .padding(.top, 6)

            FlowLayout(spacing: 8) {
                ForEach(PortfolioColumnMetric.allCases.filter { $0.category == category }) { column in
                    let isSelected = columns.contains(column)
                    Button {
                        withAnimation(.spring(response: 0.2)) {
                            if isSelected {
                                columns.removeAll { $0 == column }
                            } else {
                                columns.append(column)
                            }
                            selectedPreset = .custom
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(column.title)
                                .font(.system(size: 12.5, weight: isSelected ? .bold : .medium))
                                .foregroundStyle(isSelected ? DS.brand : DS.ink)

                            if isSelected {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(DS.brand)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(isSelected ? DS.brand.opacity(0.12) : DS.cardAlt)
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(isSelected ? DS.brand.opacity(0.3) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
        }
    }
}

private struct PortfolioColumnPillDropDelegate: DropDelegate {
    let targetColumn: PortfolioColumnMetric
    @Binding var draggingColumn: PortfolioColumnMetric?
    let onMove: (PortfolioColumnMetric, PortfolioColumnMetric) -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggingColumn = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingColumn, dragging != targetColumn else { return }
        onMove(dragging, targetColumn)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}