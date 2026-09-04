import SwiftUI

struct CloseHoldingSheet: View {
    @EnvironmentObject var storageService: StorageService
    @EnvironmentObject var stockService: StockService

    let portfolioId: UUID
    let holding: Holding
    let quote: StockQuote?
    let onDismiss: () -> Void

    @State private var sellQuantity: String
    @State private var sellPrice: String
    @State private var sellDate: Date = Date()
    @State private var validationError: String?

    init(portfolioId: UUID, holding: Holding, quote: StockQuote?, onDismiss: @escaping () -> Void) {
        self.portfolioId = portfolioId
        self.holding = holding
        self.quote = quote
        self.onDismiss = onDismiss

        let defaultPrice = quote?.price ?? (holding.avgPrice > 0 ? holding.avgPrice : 0.0)
        _sellQuantity = State(initialValue: StorageService.formatNumber(holding.quantity, decimals: -1))
        _sellPrice = State(initialValue: defaultPrice > 0 ? String(format: "%.2f", defaultPrice) : "")
    }

    private var parsedQty: Double {
        Double(sellQuantity.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var parsedPrice: Double {
        Double(sellPrice.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var estimatedCost: Double {
        parsedQty * holding.avgPrice
    }

    private var estimatedProceeds: Double {
        parsedQty * parsedPrice
    }

    private var estimatedRealizedPnl: Double {
        (estimatedProceeds - estimatedCost) * (holding.leverage ?? 1.0)
    }

    private var estimatedPnlPercent: Double {
        estimatedCost > 0 ? (estimatedRealizedPnl / estimatedCost) * 100 : 0
    }

    var body: some View {
        SheetShell(title: "Close Position: \(StockService.beautifiedSymbol(holding.symbol))", onCancel: onDismiss) {
            VStack(alignment: .leading, spacing: 16) {
                // Info Banner
                HStack(spacing: 12) {
                    SymbolLogo(symbol: holding.symbol, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(StockService.beautifiedSymbol(holding.symbol))
                            .font(DS.bodyStrong)
                            .foregroundStyle(DS.ink)
                        Text("Available to sell: \(StorageService.formatNumber(holding.quantity, decimals: -1)) shares")
                            .font(DS.caption)
                            .foregroundStyle(DS.inkSecondary)
                    }
                    Spacer()
                    if holding.avgPrice > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Cost Basis / sh")
                                .font(DS.micro)
                                .foregroundStyle(DS.inkTertiary)
                            Text(StorageService.formatAmount(holding.avgPrice, symbol: "$", decimals: 2))
                                .font(DS.figure)
                                .foregroundStyle(DS.ink)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(DS.cardAlt))

                // Input Fields
                VStack(alignment: .leading, spacing: 12) {
                    // Sell Quantity
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Shares to Sell")
                                .font(DS.caption)
                                .foregroundStyle(DS.inkSecondary)
                            Spacer()
                            Button("Sell All") {
                                sellQuantity = StorageService.formatNumber(holding.quantity, decimals: -1)
                            }
                            .buttonStyle(.borderless)
                            .font(DS.micro)
                            .foregroundStyle(DS.brand)
                        }

                        TextField("Quantity", text: $sellQuantity)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Sell Price
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Selling Price per Share")
                                .font(DS.caption)
                                .foregroundStyle(DS.inkSecondary)
                            Spacer()
                            if let qPrice = quote?.price, qPrice > 0 {
                                Button("Use Current Price (\(StorageService.formatAmount(qPrice, symbol: "$", decimals: 2)))") {
                                    sellPrice = String(format: "%.2f", qPrice)
                                }
                                .buttonStyle(.borderless)
                                .font(DS.micro)
                                .foregroundStyle(DS.brand)
                            }
                        }

                        TextField("Price", text: $sellPrice)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Sell Date
                    DatePicker("Sell Date", selection: $sellDate, displayedComponents: .date)
                        .font(DS.caption)
                        .foregroundStyle(DS.inkSecondary)
                }

                Divider()

                // Realized P&L Preview
                if parsedQty > 0 && parsedPrice > 0 {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Proceeds (Tiền thu về):")
                                .font(DS.caption)
                                .foregroundStyle(DS.inkSecondary)
                            Spacer()
                            Text(StorageService.formatAmount(estimatedProceeds, symbol: "$", decimals: 2))
                                .font(DS.figure)
                                .foregroundStyle(DS.ink)
                        }

                        HStack {
                            Text("Realized P&L (Lãi/Lỗ đã chốt):")
                                .font(DS.caption)
                                .foregroundStyle(DS.inkSecondary)
                            Spacer()
                            Text(StorageService.formatAmount(estimatedRealizedPnl, symbol: "$", decimals: 2, signed: true))
                                .font(DS.figure)
                                .foregroundStyle(DS.pnlColor(estimatedRealizedPnl))

                            ChangePill(
                                value: estimatedPnlPercent,
                                text: String(format: "%+.2f%%", estimatedPnlPercent)
                            )
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(DS.cardAlt))
                }

                if let error = validationError {
                    Text(error)
                        .font(DS.micro)
                        .foregroundStyle(DS.down)
                }

                // Actions Footer
                HStack {
                    Button("Cancel") { onDismiss() }
                        .buttonStyle(.borderless)

                    Spacer()

                    PrimaryButton(
                        title: "Confirm Sell",
                        enabled: parsedQty > 0 && parsedQty <= holding.quantity && parsedPrice > 0,
                        action: executeClose
                    )
                }
            }
        }
    }

    private func executeClose() {
        guard parsedQty > 0 else {
            validationError = "Quantity must be greater than 0."
            return
        }
        guard parsedQty <= holding.quantity else {
            validationError = "Quantity cannot exceed available shares (\(holding.quantity))."
            return
        }
        guard parsedPrice > 0 else {
            validationError = "Selling price must be greater than 0."
            return
        }

        storageService.recordSellTrade(
            portfolioId: portfolioId,
            holdingId: holding.id,
            sellQuantity: parsedQty,
            sellPrice: parsedPrice,
            sellDate: sellDate
        )

        onDismiss()
    }
}
