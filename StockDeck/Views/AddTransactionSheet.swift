import SwiftUI

struct AddTransactionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var storageService: StorageService

    let portfolioId: UUID

    @State private var type: TransactionType = .buy
    @State private var symbol: String = ""
    @State private var quantity: String = ""
    @State private var price: String = ""
    @State private var date: Date = Date()
    @State private var account: String = ""
    @State private var notes: String = ""

    private var isValid: Bool {
        !symbol.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (Double(quantity) ?? 0) > 0 &&
        (Double(price) ?? 0) >= 0
    }

    private var calculatedAmount: Double {
        let q = Double(quantity) ?? 0
        let p = Double(price) ?? 0
        return q * p
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Transaction")
                    .font(DS.title)
                    .foregroundStyle(DS.ink)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DS.inkTertiary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            Divider().overlay(DS.hairline)

            // Form
            Form {
                Picker("Transaction Type", selection: $type) {
                    ForEach(TransactionType.allCases, id: \.self) { t in
                        Text(t.displayName).tag(t)
                    }
                }

                TextField("Symbol (e.g. AAPL, SPGI, 2559.T)", text: $symbol)

                TextField("Quantity", text: $quantity)

                TextField("Unit Price", text: $price)

                DatePicker("Date", selection: $date, displayedComponents: [.date])

                TextField("Account (e.g. NISA, Tokutei, Ippan)", text: $account)

                TextField("Notes (Optional)", text: $notes)

                if calculatedAmount > 0 {
                    let currSym = StorageService.currencySymbol(for: storageService.preferredCurrency)
                    HStack {
                        Text("Total Amount:")
                            .font(DS.caption)
                            .foregroundStyle(DS.inkSecondary)
                        Spacer()
                        Text(StorageService.formatAmount(calculatedAmount, symbol: currSym, decimals: storageService.amountDecimals))
                            .font(DS.figure)
                            .foregroundStyle(DS.ink)
                    }
                }
            }
            .formStyle(.grouped)

            Divider().overlay(DS.hairline)

            // Footer
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save Transaction") {
                    saveTransaction()
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.brand)
                .disabled(!isValid)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 420, minHeight: 460)
        .background(DS.card)
    }

    private func saveTransaction() {
        guard let q = Double(quantity), let p = Double(price) else { return }
        let tx = Transaction(
            date: date,
            symbol: symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            type: type,
            quantity: q,
            price: p,
            amount: q * p,
            currency: storageService.preferredCurrency,
            account: account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : account.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        storageService.addTransactionsBatch([tx], to: portfolioId)
        dismiss()
    }
}
