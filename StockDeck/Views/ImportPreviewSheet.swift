import SwiftUI

struct ParsedImportItem: Identifiable {
    let id = UUID()
    let holding: Holding
    var isChecked: Bool = true
    let isFund: Bool
    let originalAccountName: String?
}

struct ImportPreviewSheet: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService

    let initialItems: [ParsedImportItem]
    let suggestedPortfolioName: String?
    let isFundImport: Bool
    let onDismiss: () -> Void

    @State private var items: [ParsedImportItem]
    @State private var selectedPortfolioId: String // Portfolio UUID string or "NEW"
    @State private var newPortfolioName: String = ""

    init(
        items: [ParsedImportItem],
        suggestedPortfolioName: String? = nil,
        isFundImport: Bool = false,
        onDismiss: @escaping () -> Void
    ) {
        self.initialItems = items
        self.suggestedPortfolioName = suggestedPortfolioName
        self.isFundImport = isFundImport
        self.onDismiss = onDismiss
        _items = State(initialValue: items)
        _selectedPortfolioId = State(initialValue: "NEW")
    }

    var selectedCount: Int {
        items.filter { $0.isChecked }.count
    }

    var currentTargetPortfolio: Portfolio? {
        if selectedPortfolioId == "NEW" { return nil }
        return storageService.portfolios.first { $0.id.uuidString == selectedPortfolioId }
    }

    var body: some View {
        SheetShell(
            title: isFundImport ? "Import 投資信託 (Japanese Funds)" : "Import Holdings",
            onCancel: onDismiss
        ) {
            VStack(alignment: .leading, spacing: 14) {
                // Target Portfolio Selection
                VStack(alignment: .leading, spacing: 6) {
                    Text("Target Portfolio").font(DS.caption).foregroundStyle(DS.inkSecondary)
                    
                    HStack(spacing: 10) {
                        Picker("Target Portfolio", selection: $selectedPortfolioId) {
                            Text("+ Create New Portfolio…").tag("NEW")
                            Divider()
                            ForEach(storageService.portfolios) { p in
                                Text(p.name).tag(p.id.uuidString)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220)

                        if selectedPortfolioId == "NEW" {
                            TextField("Portfolio Name", text: $newPortfolioName)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 180)
                        }
                    }
                }

                Divider()

                // List Controls: Select / Deselect All & Template Download
                HStack {
                    Text("Parsed Positions (\(items.count))")
                        .font(DS.bodyStrong)
                        .foregroundStyle(DS.ink)
                    
                    Spacer()
                    
                    if isFundImport {
                        Button("Download 投資信託 Template (XLSX)") {
                            PortfolioIO.downloadJapaneseFundSample(restoreActivationPolicy: true)
                        }
                        .buttonStyle(.borderless)
                        .font(DS.caption)

                        Text("·").font(DS.caption).foregroundStyle(DS.inkTertiary)
                    }

                    Button("Select All") {
                        for i in items.indices { items[i].isChecked = true }
                    }
                    .buttonStyle(.borderless)
                    .font(DS.caption)

                    Text("·").font(DS.caption).foregroundStyle(DS.inkTertiary)

                    Button("Deselect All") {
                        for i in items.indices { items[i].isChecked = false }
                    }
                    .buttonStyle(.borderless)
                    .font(DS.caption)
                }

                // Preview List with Checkboxes
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach($items) { $item in
                            holdingRow(item: $item)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 220)

                Divider()

                // Actions Footer
                HStack {
                    Button("Cancel") { onDismiss() }
                        .buttonStyle(.borderless)

                    Spacer()

                    PrimaryButton(
                        title: selectedCount == 0
                            ? "No Items Selected"
                            : "Import \(selectedCount) Item\(selectedCount > 1 ? "s" : "")",
                        enabled: selectedCount > 0 && (selectedPortfolioId != "NEW" || !newPortfolioName.trimmingCharacters(in: .whitespaces).isEmpty),
                        action: executeImport
                    )
                }
            }
        }
        .onAppear {
            if let first = storageService.portfolios.first {
                selectedPortfolioId = first.id.uuidString
            } else {
                selectedPortfolioId = "NEW"
                newPortfolioName = suggestedPortfolioName ?? (isFundImport ? "NISA Portfolio" : "My Portfolio")
            }
            if newPortfolioName.isEmpty {
                newPortfolioName = suggestedPortfolioName ?? (isFundImport ? "NISA Portfolio" : "My Portfolio")
            }
        }
    }

    @ViewBuilder
    private func holdingRow(item: Binding<ParsedImportItem>) -> some View {
        let h = item.wrappedValue.holding
        let symbol = h.symbol
        let isExisting = currentTargetPortfolio?.holdings.contains(where: { $0.symbol == symbol }) ?? false
        let currency = isFundImport ? "JPY" : stockService.detectedCurrency(for: symbol)
        let currSym = StorageService.currencySymbol(for: currency)

        HStack(spacing: 10) {
            Toggle("", isOn: item.isChecked)
                .toggleStyle(.checkbox)
                .labelsHidden()

            SymbolLogo(symbol: symbol, size: 22)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(symbol).font(DS.bodyStrong).foregroundStyle(DS.ink)
                    if isExisting {
                        Text("Existing")
                            .font(DS.micro)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(DS.cardAlt).stroke(DS.inkSecondary.opacity(0.3), lineWidth: 1))
                            .foregroundStyle(DS.inkSecondary)
                    }
                }
                if let acct = item.wrappedValue.originalAccountName {
                    Text(acct).font(DS.micro).foregroundStyle(DS.inkTertiary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("Qty: \(StorageService.formatNumber(h.quantity, decimals: -1))")
                    .font(.inter(11, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(DS.ink)

                if h.avgPrice > 0 {
                    Text("Avg: \(currSym)\(StorageService.formatNumber(h.avgPrice, decimals: isFundImport ? 0 : 2))")
                        .font(.inter(9, relativeTo: .caption).monospacedDigit())
                        .foregroundStyle(DS.inkSecondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(item.wrappedValue.isChecked ? DS.cardAlt : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            item.wrappedValue.isChecked.toggle()
        }
    }

    private func executeImport() {
        let selectedHoldings = items.filter { $0.isChecked }.map { $0.holding }
        guard !selectedHoldings.isEmpty else { return }

        let targetId: UUID
        if selectedPortfolioId == "NEW" {
            let finalName = newPortfolioName.trimmingCharacters(in: .whitespaces).isEmpty ? "Imported Portfolio" : newPortfolioName.trimmingCharacters(in: .whitespaces)
            let newP = storageService.createPortfolio(name: finalName)
            targetId = newP.id
        } else if let uuid = UUID(uuidString: selectedPortfolioId) {
            targetId = uuid
        } else {
            return
        }

        storageService.addHoldingsBatch(selectedHoldings, to: targetId)

        let symbols = selectedHoldings.map { $0.symbol }
        Task {
            await stockService.fetchQuotes(symbols: symbols)
        }

        onDismiss()
    }
}
