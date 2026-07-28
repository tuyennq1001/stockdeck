import SwiftUI

/// A staging sheet: nothing is persisted until the user chooses Apply.
struct WatchlistMetricCustomizer: View {
    let initialMetrics: [WatchlistMetric]
    let onApply: ([WatchlistMetric]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var metrics: [WatchlistMetric]

    init(initialMetrics: [WatchlistMetric], onApply: @escaping ([WatchlistMetric]) -> Void) {
        self.initialMetrics = initialMetrics
        self.onApply = onApply
        _metrics = State(initialValue: initialMetrics)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Customize columns").font(.inter(22, weight: .bold, relativeTo: .title2))
                    Text("Choose up to 8 metrics, then drag to set their order.")
                        .font(DS.body).foregroundStyle(DS.inkSecondary)
                }
                Spacer()
                Text("\(metrics.count)/8")
                    .font(DS.figure.monospacedDigit())
                    .foregroundStyle(metrics.count == 8 ? DS.brand : DS.inkSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(DS.cardAlt))
            }

            GroupBox("Shown columns") {
                if metrics.isEmpty {
                    Text("Pick a metric below to add it.")
                        .font(DS.body).foregroundStyle(DS.inkTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    List {
                        ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(DS.caption.monospacedDigit()).foregroundStyle(DS.inkTertiary)
                                    .frame(width: 20)
                                Text(metric.title).font(DS.bodyStrong)
                                Spacer()
                                Button { metrics.removeAll { $0 == metric } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(DS.inkTertiary)
                                }
                                .buttonStyle(.plain).pointingHandCursor()
                            }
                        }
                        .onMove { metrics.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .listStyle(.plain)
                    .frame(height: min(CGFloat(metrics.count) * 36 + 8, 180))
                }
            }

            ForEach(WatchlistMetricCategory.allCases) { category in
                VStack(alignment: .leading, spacing: 8) {
                    Text(category.rawValue).font(DS.label).foregroundStyle(DS.inkTertiary)
                    metricButtons(category: category)
                }
                if category != .chart { Divider().overlay(DS.hairline) }
            }

            HStack {
                Button("Reset") { metrics = WatchlistMetric.defaultSelection }
                    .buttonStyle(.plain).foregroundStyle(DS.brand).pointingHandCursor()
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain).foregroundStyle(DS.inkSecondary).pointingHandCursor()
                Button("Apply changes") {
                    onApply(metrics)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.brand)
                .disabled(metrics.isEmpty)
                .pointingHandCursor()
            }
        }
        .padding(24)
        .frame(width: 660)
    }

    @ViewBuilder
    private func metricButtons(category: WatchlistMetricCategory) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(WatchlistMetric.allCases.filter { $0.category == category }) { metric in
                let selected = metrics.contains(metric)
                Button {
                    if selected {
                        metrics.removeAll { $0 == metric }
                    } else if metrics.count < 8 {
                        metrics.append(metric)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(metric.title)
                        if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                    }
                    .font(DS.bodyStrong)
                    .foregroundStyle(selected ? DS.brand : DS.ink)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Capsule().fill(selected ? DS.brand.opacity(0.12) : DS.cardAlt))
                }
                .buttonStyle(.plain)
                .disabled(!selected && metrics.count >= 8)
                .pointingHandCursor()
            }
        }
    }
}

/// Lightweight wrapping layout for the metric chips.
private struct FlowLayout: Layout {
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
