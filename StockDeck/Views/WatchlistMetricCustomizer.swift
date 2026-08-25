import SwiftUI

/// Preset configurations for quick selection in Watchlist Customizer
enum MetricPreset: String, CaseIterable, Identifiable {
    case custom = "Custom"
    case defaultPreset = "Default"
    case overview = "Overview"
    case technical = "Technical"

    var id: String { rawValue }

    var metrics: [WatchlistMetric] {
        switch self {
        case .custom:
            return WatchlistMetric.defaultSelection
        case .defaultPreset:
            return [.ext, .todayChange, .oneMonth, .threeMonths, .chart7d]
        case .overview:
            return [.ext, .todayChange, .oneMonth, .oneYear, .ath, .chart7d]
        case .technical:
            return [.ext, .todayChange, .ytd, .ath, .fromAth, .atl, .fromAtl, .chart30d]
        }
    }
}

/// A staging sheet: nothing is persisted until the user chooses Apply.
struct WatchlistMetricCustomizer: View {
    let initialMetrics: [WatchlistMetric]
    let onApply: ([WatchlistMetric]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var metrics: [WatchlistMetric]
    @State private var selectedPreset: MetricPreset = .custom
    @State private var draggingMetric: WatchlistMetric?

    init(initialMetrics: [WatchlistMetric], onApply: @escaping ([WatchlistMetric]) -> Void) {
        self.initialMetrics = initialMetrics
        self.onApply = onApply
        _metrics = State(initialValue: initialMetrics)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Customize Columns")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(DS.ink)
                    Text("Add, delete and sort metrics just how you need it")
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
                    ForEach(MetricPreset.allCases) { preset in
                        Button(preset.rawValue) {
                            selectedPreset = preset
                            if preset != .custom {
                                metrics = preset.metrics
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
                        metrics = initialMetrics
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

            // Selected Metrics Box (Top Container)
            VStack(alignment: .leading, spacing: 0) {
                if metrics.isEmpty {
                    Text("No columns selected. Click metrics below to add.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DS.inkTertiary)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    FlowLayout(spacing: 8) {
                        ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                            selectedMetricPill(metric: metric, index: index + 1)
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
                    ForEach(WatchlistMetricCategory.allCases) { category in
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
                    onApply(metrics)
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
                .disabled(metrics.isEmpty)
                .pointingHandCursor()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        #if os(macOS)
        .frame(width: 720, height: 600)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(DS.ground)
    }

    // MARK: - Selected Metric Pill in Top Container

    @ViewBuilder
    private func selectedMetricPill(metric: WatchlistMetric, index: Int) -> some View {
        HStack(spacing: 6) {
            Text("\(index)")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(DS.ink)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.white))
                .shadow(color: .black.opacity(0.06), radius: 1, y: 1)

            Text(metric.title)
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
                metrics.removeAll { $0 == metric }
                selectedPreset = .custom
            }
        }
        .onDrag {
            self.draggingMetric = metric
            return NSItemProvider(object: metric.rawValue as NSString)
        }
        .onDrop(of: [.text], delegate: MetricPillDropDelegate(
            targetMetric: metric,
            draggingMetric: $draggingMetric,
            onMove: { src, tgt in
                if let srcIdx = metrics.firstIndex(of: src),
                   let tgtIdx = metrics.firstIndex(of: tgt) {
                    withAnimation(.spring(response: 0.2)) {
                        metrics.move(fromOffsets: IndexSet(integer: srcIdx), toOffset: tgtIdx > srcIdx ? tgtIdx + 1 : tgtIdx)
                    }
                }
            }
        ))
        .pointingHandCursor()
    }

    // MARK: - Category Section & Pills

    @ViewBuilder
    private func categorySection(category: WatchlistMetricCategory) -> some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 24) {
            Text(category.rawValue)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DS.inkSecondary)
                .frame(width: 110, alignment: .leading)
                .padding(.top, 6)

            categoryPills(category: category)
        }
        #else
        VStack(alignment: .leading, spacing: 8) {
            Text(category.rawValue)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(DS.inkSecondary)
                .padding(.top, 4)

            categoryPills(category: category)
        }
        #endif
    }

    @ViewBuilder
    private func categoryPills(category: WatchlistMetricCategory) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(WatchlistMetric.allCases.filter { $0 != .today && $0 != .price && $0.category == category }) { metric in
                let isSelected = metrics.contains(metric)
                Button {
                    withAnimation(.spring(response: 0.2)) {
                        if isSelected {
                            metrics.removeAll { $0 == metric }
                        } else {
                            metrics.append(metric)
                        }
                        selectedPreset = .custom
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(metric.title)
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

private struct MetricPillDropDelegate: DropDelegate {
    let targetMetric: WatchlistMetric
    @Binding var draggingMetric: WatchlistMetric?
    let onMove: (WatchlistMetric, WatchlistMetric) -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggingMetric = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingMetric, dragging != targetMetric else { return }
        onMove(dragging, targetMetric)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

/// Lightweight wrapping layout for the metric chips.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + (x > 0 ? spacing : 0)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
