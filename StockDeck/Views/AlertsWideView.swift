import SwiftUI

/// Desktop Alerts page (under Utilities): a table of every price alert with
/// columns # / Symbol / Alert contents / Actions, individual edit, delete and
/// on–off controls, and a header checkbox that selects all rows so multiple
/// alerts can be deleted or toggled on/off at once. The batch-action bar is
/// always visible.
struct AlertsWideView: View {
    @EnvironmentObject var storageService: StorageService

    /// The set of rows selected for batch actions.
    @State private var selected = Set<UUID>()
    @State private var editingAlert: PriceAlert? = nil

    private var currencySymbol: String {
        StorageService.currencySymbol(for: storageService.preferredCurrency)
    }

    var body: some View {
        PageScaffold("Alerts", caption: "Price alerts you've set on your watchlist symbols.") {
            EmptyView()
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if storageService.alerts.isEmpty {
                        emptyState
                    } else {
                        alertsTable
                    }
                }
                .pageColumn()
                .padding(.top, 4)
            }
        }
        .navigationTitle("Alerts")
        .sheet(item: $editingAlert) { alert in
            PriceAlertSheet(symbol: alert.symbol, editing: alert) { editingAlert = nil }
                .environmentObject(StockService.shared)
                .environmentObject(storageService)
        }
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

    private var alertsTable: some View {
        VStack(spacing: 0) {
            headerRow
            Divider().overlay(DS.hairline)
            batchBar
            Divider().overlay(DS.hairline)
            rowsList
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.hairline, lineWidth: 0.5))
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 12) {
            selectAllButton
                .frame(width: 24)
            Text("#").font(DS.label).foregroundStyle(DS.inkTertiary).frame(width: 26, alignment: .trailing)
            Text("Symbol").font(DS.label).foregroundStyle(DS.inkTertiary).frame(width: 180, alignment: .leading)
            Text("Alert contents").font(DS.label).foregroundStyle(DS.inkTertiary).frame(maxWidth: .infinity, alignment: .leading)
            Text("Actions").font(DS.label).foregroundStyle(DS.inkTertiary).frame(width: 148, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .tracking(0.8)
        .textCase(.uppercase)
    }

    /// The header checkbox: acts as select-all.
    private var selectAllButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                if selected.count == storageService.alerts.count {
                    selected.removeAll()
                } else {
                    selected = Set(storageService.alerts.map(\.id))
                }
            }
        } label: {
            Image(systemName: selectAllIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(!selected.isEmpty ? DS.brand : DS.inkTertiary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(selected.count == storageService.alerts.count ? "Deselect all" : "Select all")
    }

    private var selectAllIcon: String {
        if selected.isEmpty { return "square" }
        if selected.count == storageService.alerts.count { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    // MARK: - Batch bar

    private var batchBar: some View {
        let count = selected.count
        return HStack(spacing: 10) {
            Text("\(count) selected")
                .font(DS.caption)
                .foregroundStyle(DS.inkSecondary)
            Spacer()
            Button {
                toggleSelected()
            } label: {
                Text(batchToggleTitle)
                    .font(.inter(11.5, weight: .semibold, relativeTo: .caption))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.brand)
            .pointingHandCursor()
            .disabled(count == 0)
            .opacity(count == 0 ? 0.4 : 1)
            Button {
                storageService.removeAlerts(ids: selected)
                selected.removeAll()
            } label: {
                Text("Delete (\(count))")
                    .font(.inter(11.5, weight: .semibold, relativeTo: .caption))
            }
            .buttonStyle(.plain)
            .foregroundStyle(count == 0 ? DS.inkTertiary : DS.down)
            .pointingHandCursor()
            .disabled(count == 0)
            .opacity(count == 0 ? 0.5 : 1)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(DS.cardAlt.opacity(0.5))
    }

    private var selectedAlerts: [PriceAlert] {
        storageService.alerts.filter { selected.contains($0.id) }
    }

    private var allSelectedEnabled: Bool {
        let list = selectedAlerts
        return !list.isEmpty && list.allSatisfy(\.isEnabled)
    }

    private var batchToggleTitle: String {
        let n = selected.count
        return allSelectedEnabled ? "Turn off (\(n))" : "Turn on (\(n))"
    }

    private func toggleSelected() {
        let enable = !allSelectedEnabled
        for alert in selectedAlerts {
            storageService.setAlertEnabled(id: alert.id, enabled: enable)
        }
    }

    // MARK: - Rows

    private var rowsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(storageService.alerts.enumerated()), id: \.element.id) { idx, alert in
                    alertRow(alert, position: idx + 1)
                    if idx < storageService.alerts.count - 1 {
                        Divider().overlay(DS.hairline.opacity(0.5)).padding(.leading, 50)
                    }
                }
            }
        }
        .frame(minHeight: 220)
    }

    private func alertRow(_ alert: PriceAlert, position: Int) -> some View {
        let currency = StorageService.currencySymbol(
            for: StockService.shared.quotes[alert.symbol]?.currency ?? storageService.preferredCurrency)
        return HStack(spacing: 12) {
            rowCheckbox(alert)
                .frame(width: 24)
            Text("\(position)")
                .font(DS.figure)
                .foregroundStyle(DS.inkTertiary)
                .frame(width: 26, alignment: .trailing)
            HStack(spacing: 8) {
                SymbolLogo(symbol: alert.symbol, size: 22)
                Text(StockService.beautifiedSymbol(alert.symbol))
                    .font(DS.bodyStrong)
                    .foregroundStyle(DS.ink)
                    .lineLimit(1)
            }
            .frame(width: 180, alignment: .leading)
            HStack(spacing: 8) {
                Image(systemName: alert.condition.systemImage)
                    .font(.inter(10, relativeTo: .caption))
                    .foregroundStyle(alert.isEnabled ? DS.brand : DS.inkTertiary)
                Text(AlertEvaluator.describe(alert, currencySymbol: currency))
                    .font(DS.caption)
                    .foregroundStyle(DS.inkSecondary)
                    .lineLimit(1)
                if !alert.isEnabled {
                    Text("triggered")
                        .font(DS.micro)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            rowActions(alert)
                .frame(width: 148, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func rowCheckbox(_ alert: PriceAlert) -> some View {
        Button {
            if selected.contains(alert.id) {
                selected.remove(alert.id)
            } else {
                selected.insert(alert.id)
            }
        } label: {
            Image(systemName: selected.contains(alert.id) ? "checkmark.square.fill" : "square")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected.contains(alert.id) ? DS.brand : DS.inkTertiary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func rowActions(_ alert: PriceAlert) -> some View {
        HStack(spacing: 6) {
            Button {
                editingAlert = alert
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.inkSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(DS.cardAlt))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Edit alert")

            Toggle("", isOn: Binding(
                get: { alert.isEnabled },
                set: { storageService.setAlertEnabled(id: alert.id, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(alert.isEnabled ? "Enabled" : "Re-arm alert")

            Button {
                storageService.removeAlert(id: alert.id)
                selected.remove(alert.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.inkSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(DS.cardAlt))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Delete alert")
        }
    }
}
