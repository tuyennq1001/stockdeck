import SwiftUI

/// Desktop Alerts page (under Utilities): lists every price alert with its
/// enable/re-arm toggle, and lets the user clear them all at once. Alerts are
/// created from a symbol's context menu ("Set Price Alert…").
struct AlertsWideView: View {
    @EnvironmentObject var storageService: StorageService
    @State private var showClearAlerts = false

    var body: some View {
        PageScaffold("Alerts", caption: "Price alerts you've set on your watchlist symbols.") {
            EmptyView()
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if storageService.alerts.isEmpty {
                        emptyState
                    } else {
                        alertsCard
                    }
                }
                .pageColumn()
                .padding(.top, 4)
            }
        }
        .navigationTitle("Alerts")
        .dsAlert($showClearAlerts, title: "Clear all alerts",
                 message: "This will delete all your price alerts. This cannot be undone.",
                 confirmTitle: "Clear all", destructive: true) { storageService.removeAllAlerts() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.slash")
                .font(.system(size: 30))
                .foregroundStyle(DS.inkTertiary)
            Text("No alerts")
                .font(DS.title)
                .foregroundStyle(DS.ink)
            Text("Right-click a stock in any watchlist and choose “Set Price Alert…” to add one.")
                .font(DS.body)
                .foregroundStyle(DS.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.card))
    }

    private var alertsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(storageService.alerts) { alert in
                AlertRow(alert: alert)
                if alert.id != storageService.alerts.last?.id { Divider().overlay(DS.hairline) }
            }
            Divider().overlay(DS.hairline)
            HStack {
                Spacer()
                Button("Clear all alerts") { showClearAlerts = true }
                    .buttonStyle(.plain)
                    .font(.inter(11, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(DS.down)
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.card))
    }
}