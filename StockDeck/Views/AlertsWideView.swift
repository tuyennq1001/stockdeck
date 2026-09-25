import SwiftUI

/// Desktop Alerts page (under Utilities): a unified table of every price alert and
/// buy target with columns # / Symbol / Type / Alert contents / Actions, individual
/// edit, delete and on–off controls, and a header checkbox that selects all rows so
/// multiple items can be deleted or toggled on/off at once.
struct AlertsWideView: View {
    @EnvironmentObject var storageService: StorageService

    enum AlertItem: Identifiable {
        case priceAlert(PriceAlert)
        case buyTarget(StockTarget)

        var id: UUID {
            switch self {
            case .priceAlert(let a): return a.id
            case .buyTarget(let t): return t.id
            }
        }

        var symbol: String {
            switch self {
            case .priceAlert(let a): return a.symbol
            case .buyTarget(let t): return t.symbol
            }
        }

        var isEnabled: Bool {
            switch self {
            case .priceAlert(let a): return a.isEnabled
            case .buyTarget(let t): return t.notifyWhenReached
            }
        }
    }

    /// The set of rows selected for batch actions.
    @State private var selected = Set<UUID>()
    @State private var editingAlert: PriceAlert? = nil
    @State private var editingTarget: StockTarget? = nil
    @State private var showAddAlert = false
    @State private var showAddTarget = false

    private var allItems: [AlertItem] {
        var items: [AlertItem] = []
        for alert in storageService.alerts {
            items.append(.priceAlert(alert))
        }
        for (_, target) in storageService.stockTargets {
            items.append(.buyTarget(target))
        }
        return items
    }

    private var currencySymbol: String {
        StorageService.currencySymbol(for: storageService.preferredCurrency)
    }

    var body: some View {
        PageScaffold("Alerts", caption: "Price alerts & buy targets you've set on your symbols.", trailing: {
            Menu {
                Button {
                    showAddAlert = true
                } label: {
                    Label("Add Price Alert…", systemImage: "bell")
                }
                Button {
                    showAddTarget = true
                } label: {
                    Label("Set Buy Target…", systemImage: "target")
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("Add")
                        .font(DS.bodyStrong)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(DS.brand))
            }
            .menuStyle(.borderlessButton)
            .pointingHandCursor()
            .help("Add a price alert or buy target")
        }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if allItems.isEmpty {
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
        .sheet(isPresented: $showAddAlert) {
            PriceAlertSheet {
                showAddAlert = false
            }
            .environmentObject(StockService.shared)
            .environmentObject(storageService)
        }
        .sheet(item: $editingAlert) { alert in
            PriceAlertSheet(symbol: alert.symbol, editing: alert) { editingAlert = nil }
                .environmentObject(StockService.shared)
                .environmentObject(storageService)
        }
        .sheet(isPresented: $showAddTarget) {
            StockTargetSheet {
                showAddTarget = false
            }
            .environmentObject(StockService.shared)
            .environmentObject(storageService)
        }
        .sheet(item: $editingTarget) { target in
            StockTargetSheet(symbol: target.symbol) { editingTarget = nil }
                .environmentObject(StockService.shared)
                .environmentObject(storageService)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.slash")
                .font(.system(size: 30))
                .foregroundStyle(DS.inkTertiary)
            Text("No alerts or targets")
                .font(DS.title)
                .foregroundStyle(DS.ink)
            Text("Right-click a stock in any watchlist or click below to add a price alert or buy target.")
                .font(DS.body)
                .foregroundStyle(DS.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 10) {
                Button {
                    showAddAlert = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bell")
                            .font(.system(size: 11, weight: .bold))
                        Text("Add price alert")
                            .font(DS.bodyStrong)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(DS.brand))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                Button {
                    showAddTarget = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "target")
                            .font(.system(size: 11, weight: .bold))
                        Text("Set buy target")
                            .font(DS.bodyStrong)
                    }
                    .foregroundStyle(DS.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(DS.cardAlt))
                    .overlay(Capsule().strokeBorder(DS.hairline))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.card))
    }

    private var alertsTable: some View {
        VStack(spacing: 0) {
            tableToolbar
            Divider().overlay(DS.hairline)
            headerRow
            Divider().overlay(DS.hairline)
            rowsList
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(DS.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(DS.hairline, lineWidth: 0.5))
    }

    private var tableToolbar: some View {
        HStack(spacing: 8) {
            if selected.isEmpty {
                let count = allItems.count
                Text("\(count) item\(count == 1 ? "" : "s")")
                    .font(DS.caption)
                    .foregroundStyle(DS.inkSecondary)
            } else {
                let count = selected.count
                HStack(spacing: 8) {
                    Text("\(count) selected")
                        .font(DS.caption)
                        .foregroundStyle(DS.ink)
                    Text("·").font(DS.caption).foregroundStyle(DS.inkTertiary)
                    Button {
                        toggleSelected()
                    } label: {
                        Text(batchToggleTitle)
                            .font(.inter(11.5, weight: .semibold, relativeTo: .caption))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.brand)
                    .pointingHandCursor()

                    Text("·").font(DS.caption).foregroundStyle(DS.inkTertiary)
                    Button {
                        deleteSelected()
                    } label: {
                        Text("Delete (\(count))")
                            .font(.inter(11.5, weight: .semibold, relativeTo: .caption))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.down)
                    .pointingHandCursor()

                    Text("·").font(DS.caption).foregroundStyle(DS.inkTertiary)
                    Button {
                        selected.removeAll()
                    } label: {
                        Text("Clear")
                            .font(.inter(11.5, weight: .semibold, relativeTo: .caption))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.inkSecondary)
                    .pointingHandCursor()
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 12) {
            selectAllButton
            Text("#").font(DS.label).foregroundStyle(DS.inkTertiary).frame(width: 24, alignment: .leading)
            Text("Symbol").font(DS.label).foregroundStyle(DS.inkTertiary).frame(width: 170, alignment: .leading)
            Text("Type").font(DS.label).foregroundStyle(DS.inkTertiary).frame(width: 105, alignment: .leading)
            Text("Alert contents / Target").font(DS.label).foregroundStyle(DS.inkTertiary).frame(maxWidth: .infinity, alignment: .leading)
            Text("Actions").font(DS.label).foregroundStyle(DS.inkTertiary).frame(width: 148, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .textCase(.uppercase)
    }

    /// The header checkbox: acts as select-all.
    private var selectAllButton: some View {
        Image(systemName: selectAllIcon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(!selected.isEmpty ? DS.brand : DS.inkTertiary)
            .frame(width: 22, alignment: .leading)
            .contentShape(Rectangle())
            .highPriorityGesture(
                TapGesture().onEnded {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if selected.count == allItems.count && !allItems.isEmpty {
                            selected.removeAll()
                        } else {
                            selected = Set(allItems.map(\.id))
                        }
                    }
                }
            )
            .pointingHandCursor()
            .help(selected.count == allItems.count && !allItems.isEmpty ? "Deselect all" : "Select all")
    }

    private var selectAllIcon: String {
        if selected.isEmpty { return "square" }
        if selected.count == allItems.count && !allItems.isEmpty { return "checkmark.square.fill" }
        return "minus.square.fill"
    }

    private var selectedItems: [AlertItem] {
        allItems.filter { selected.contains($0.id) }
    }

    private var allSelectedEnabled: Bool {
        let list = selectedItems
        return !list.isEmpty && list.allSatisfy(\.isEnabled)
    }

    private var batchToggleTitle: String {
        let n = selected.count
        return allSelectedEnabled ? "Turn off (\(n))" : "Turn on (\(n))"
    }

    private func toggleSelected() {
        let enable = !allSelectedEnabled
        for item in selectedItems {
            switch item {
            case .priceAlert(let a):
                storageService.setAlertEnabled(id: a.id, enabled: enable)
            case .buyTarget(let t):
                storageService.setBuyTargetNotify(symbol: t.symbol, notify: enable)
            }
        }
    }

    private func deleteSelected() {
        var alertIds: Set<UUID> = []
        var targetSymbols: [String] = []
        for item in selectedItems {
            switch item {
            case .priceAlert(let a): alertIds.insert(a.id)
            case .buyTarget(let t): targetSymbols.append(t.symbol)
            }
        }
        if !alertIds.isEmpty {
            storageService.removeAlerts(ids: alertIds)
        }
        if !targetSymbols.isEmpty {
            storageService.removeBuyTargets(symbols: targetSymbols)
        }
        selected.removeAll()
    }

    // MARK: - Rows

    private var rowsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(allItems.enumerated()), id: \.element.id) { idx, item in
                    rowView(item: item, position: idx + 1)
                    if idx < allItems.count - 1 {
                        Divider().overlay(DS.hairline.opacity(0.5)).padding(.leading, 50)
                    }
                }
            }
        }
        .frame(minHeight: 220)
    }

    private func rowView(item: AlertItem, position: Int) -> some View {
        let currency = StorageService.currencySymbol(
            for: StockService.shared.quotes[item.symbol]?.currency ?? storageService.preferredCurrency)
        return HStack(spacing: 12) {
            itemCheckbox(item)
            Text("\(position)")
                .font(DS.micro.monospacedDigit())
                .foregroundStyle(DS.inkTertiary)
                .frame(width: 24, alignment: .leading)
            HStack(spacing: 8) {
                SymbolLogo(symbol: item.symbol, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(StockService.beautifiedSymbol(item.symbol))
                        .font(DS.bodyStrong)
                        .foregroundStyle(DS.ink)
                        .lineLimit(1)
                }
            }
            .frame(width: 170, alignment: .leading)

            // Column: Type
            typeBadge(for: item)
                .frame(width: 105, alignment: .leading)

            // Column: Alert contents / Target
            contentCell(for: item, currency: currency)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Column: Actions
            itemActions(item)
                .frame(width: 148, alignment: .trailing)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func typeBadge(for item: AlertItem) -> some View {
        switch item {
        case .priceAlert:
            HStack(spacing: 4) {
                Image(systemName: "bell.fill").font(.system(size: 8))
                Text("Price Alert").font(DS.micro.weight(.semibold))
            }
            .foregroundStyle(DS.brand)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(DS.brand.opacity(0.12)))
        case .buyTarget:
            HStack(spacing: 4) {
                Image(systemName: "target").font(.system(size: 8.5))
                Text("Buy Target").font(DS.micro.weight(.semibold))
            }
            .foregroundStyle(DS.up)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(DS.up.opacity(0.12)))
        }
    }

    @ViewBuilder
    private func contentCell(for item: AlertItem, currency: String) -> some View {
        switch item {
        case .priceAlert(let alert):
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
        case .buyTarget(let target):
            let quote = StockService.shared.quotes[target.symbol]
            let currentPrice = quote?.effectivePrice ?? quote?.price ?? 0
            let currSym = StorageService.currencySymbol(for: quote?.currency ?? storageService.preferredCurrency)
            let dec = storageService.resolvedPriceDecimals(symbol: target.symbol, price: target.targetPrice)
            let targetStr = "\(currSym)\(StorageService.formatNumber(target.targetPrice, decimals: dec))"
            let isBuyZone = target.isInBuyZone(currentPrice: currentPrice)
            let dist = target.percentDistance(from: currentPrice)

            HStack(spacing: 8) {
                Text(targetStr)
                    .font(DS.figure.monospacedDigit())
                    .fontWeight(.semibold)
                    .foregroundStyle(DS.ink)

                if isBuyZone {
                    Text("🎯 IN BUY ZONE")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(DS.up)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(DS.up.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                } else if let dist {
                    Text(String(format: "(%+.1f%% to target)", dist))
                        .font(DS.micro.monospacedDigit())
                        .foregroundStyle(DS.inkTertiary)
                }

                if let note = target.note, !note.isEmpty {
                    Text("• \(note)")
                        .font(DS.caption)
                        .foregroundStyle(DS.inkTertiary)
                        .lineLimit(1)
                }

                if currentPrice > 0 {
                    Text("• Current: \(currSym)\(StorageService.formatNumber(currentPrice, decimals: dec))")
                        .font(DS.micro)
                        .foregroundStyle(DS.inkTertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func itemCheckbox(_ item: AlertItem) -> some View {
        Image(systemName: selected.contains(item.id) ? "checkmark.square.fill" : "square")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(selected.contains(item.id) ? DS.brand : DS.inkTertiary)
            .frame(width: 22, alignment: .leading)
            .contentShape(Rectangle())
            .highPriorityGesture(
                TapGesture().onEnded {
                    if selected.contains(item.id) {
                        selected.remove(item.id)
                    } else {
                        selected.insert(item.id)
                    }
                }
            )
            .pointingHandCursor()
    }

    @ViewBuilder
    private func itemActions(_ item: AlertItem) -> some View {
        HStack(spacing: 6) {
            Button {
                switch item {
                case .priceAlert(let a): editingAlert = a
                case .buyTarget(let t): editingTarget = t
                }
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.inkSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(DS.cardAlt))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Edit")

            Toggle("", isOn: Binding(
                get: { item.isEnabled },
                set: { val in
                    switch item {
                    case .priceAlert(let a):
                        storageService.setAlertEnabled(id: a.id, enabled: val)
                    case .buyTarget(let t):
                        storageService.setBuyTargetNotify(symbol: t.symbol, notify: val)
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(item.isEnabled ? "Notification enabled" : "Notification disabled")

            Button {
                switch item {
                case .priceAlert(let a):
                    storageService.removeAlert(id: a.id)
                    selected.remove(a.id)
                case .buyTarget(let t):
                    storageService.removeBuyTarget(for: t.symbol)
                    selected.remove(t.id)
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.inkSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(DS.cardAlt))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Delete")
        }
    }
}
