import SwiftUI

/// Sheet for creating a one-shot price alert for a given symbol.
struct AlertEditView: View {
    @EnvironmentObject var storageService: StorageService
    @EnvironmentObject var stockService: StockService

    let symbol: String
    let onDismiss: () -> Void

    @State private var condition: AlertCondition = .priceAbove
    @State private var thresholdText: String = ""

    private var quote: StockQuote? { stockService.quotes[symbol] }

    private var currencySymbol: String {
        StorageService.currencySymbol(for: quote?.currency ?? storageService.preferredCurrency)
    }

    private var thresholdUnit: String {
        switch condition.thresholdKind {
        case .price: return currencySymbol
        case .percent: return "%"
        case .ma: return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SymbolLogo(symbol: symbol, size: 28)
                Text("Alert for \(symbol)")
                    .font(.inter(13, weight: .bold, relativeTo: .headline))
                Spacer()
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Condition")
                    .font(.inter(10, relativeTo: .caption)).foregroundColor(.secondary)
                Picker("Condition", selection: $condition) {
                    ForEach(AlertCondition.allCases, id: \.self) { c in
                        Text(c.label).tag(c)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: condition) { prefillThreshold() }
            }

            if condition.thresholdKind != .ma {
                VStack(alignment: .leading, spacing: 4) {
                    Text(thresholdLabel)
                        .font(.inter(10, relativeTo: .caption)).foregroundColor(.secondary)
                    HStack(spacing: 6) {
                        TextField(placeholder, text: $thresholdText)
                            .textFieldStyle(.roundedBorder)
                        Text(thresholdUnit)
                            .font(.inter(11, relativeTo: .body)).foregroundColor(.secondary)
                    }
                }
            } else {
                Text("\(thresholdLabel): fires when the price crosses this rolling average.")
                    .font(.inter(10, relativeTo: .caption)).foregroundColor(.secondary)
            }

            if let q = quote {
                Text("Current price: \(currencySymbol)\(StorageService.formatNumber(q.effectivePrice, decimals: 2))")
                    .font(.inter(10, relativeTo: .caption)).foregroundColor(.secondary)
            }

            Spacer()

            Button("Create Alert") {
                guard let v = thresholdForCreation else { return }
                storageService.addAlert(PriceAlert(symbol: symbol, condition: condition, threshold: v))
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .pointingHandCursor()
            .disabled(thresholdForCreation == nil)
        }
        .padding()
        .onAppear { prefillThreshold() }
    }

    /// MA conditions need no threshold; others need a positive number.
    private var thresholdForCreation: Double? {
        if condition.thresholdKind == .ma { return 0 }
        guard let v = Double(thresholdText.replacingOccurrences(of: ",", with: ".")), v > 0 else { return nil }
        return v
    }

    private var thresholdLabel: String {
        switch condition {
        case .priceAbove, .priceBelow: return "Target price"
        case .dailyChangeUp, .dailyChangeDown: return "Daily change threshold"
        case .near52WeekHigh, .near52WeekLow: return "Proximity (within %)"
        case .priceAboveSMA200, .priceBelowSMA200: return "SMA 200"
        case .priceAboveEMA200, .priceBelowEMA200: return "EMA 200"
        case .priceAboveWeeklySMA200, .priceBelowWeeklySMA200: return "Weekly SMA 200"
        }
    }

    private var placeholder: String {
        condition.thresholdKind == .price ? "0.00" : "5"
    }

    /// Sensible defaults when switching condition.
    private func prefillThreshold() {
        switch condition.thresholdKind {
        case .price:
            if let q = quote { thresholdText = String(format: "%.2f", q.effectivePrice) }
        case .percent:
            switch condition {
            case .near52WeekHigh, .near52WeekLow:
                thresholdText = "2"
            default:
                thresholdText = "5"
            }
        case .ma:
            thresholdText = ""
        }
    }
}
