import SwiftUI

struct AddBinancePortfolioSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var storageService: StorageService
    var onCreated: ((Portfolio) -> Void)?

    @State private var portfolioName: String = "Binance Portfolio"
    @State private var apiKey: String = ""
    @State private var secretKey: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(spacing: 18) {
            // Header
            HStack {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.title2)
                    .foregroundColor(.yellow)
                Text("Connect Binance Account")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Security note banner
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Read-Only Security Notice")
                        .font(.subheadline)
                        .bold()
                    Text("Please create an API Key on Binance with ONLY 'Enable Reading' permission. Never enable Trading or Withdrawal permissions.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.1))
            .cornerRadius(8)

            // Form Fields
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Portfolio Name")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Portfolio Name", text: $portfolioName)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Binance API Key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Enter API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Binance Secret Key")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("Enter Secret Key", text: $secretKey)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let errorMessage = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                    Spacer()
                }
            }

            Spacer(minLength: 8)

            // Actions
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(action: connectBinance) {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "link")
                            Text("Connect Binance")
                        }
                    }
                    .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty ||
                          secretKey.trimmingCharacters(in: .whitespaces).isEmpty ||
                          portfolioName.trimmingCharacters(in: .whitespaces).isEmpty ||
                          isLoading)
            }
        }
        .padding(20)
        .frame(width: 440, height: 420)
    }

    private func connectBinance() {
        let trimmedName = portfolioName.trimmingCharacters(in: .whitespaces)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
        let trimmedSecret = secretKey.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty, !trimmedKey.isEmpty, !trimmedSecret.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let portfolio = try await storageService.createBinancePortfolio(
                    name: trimmedName,
                    apiKey: trimmedKey,
                    secretKey: trimmedSecret
                )
                await MainActor.run {
                    isLoading = false
                    onCreated?(portfolio)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
