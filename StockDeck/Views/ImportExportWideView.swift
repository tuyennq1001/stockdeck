import SwiftUI

struct ImportExportWideView: View {
    @EnvironmentObject var storageService: StorageService
    @EnvironmentObject var stockService: StockService

    let onImportStandard: () -> Void
    let onImportJapaneseFunds: () -> Void
    let onImportWatchlist: () -> Void
    let onDownloadSample: () -> Void
    let onDownloadJapaneseFundSample: () -> Void
    let onDownloadWatchlistSample: () -> Void
    let onExportPortfolios: () -> Void
    let onExportWatchlists: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(DS.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import / Export Hub")
                            .font(.inter(20, weight: .bold, relativeTo: .title2))
                            .foregroundStyle(DS.ink)
                        Text("Manage your portfolios and watchlists import, export data, and download sample templates.")
                            .font(DS.body)
                            .foregroundStyle(DS.inkSecondary)
                    }
                    Spacer()
                }
                .padding(.bottom, 8)

                // Section 1: Import Data
                VStack(alignment: .leading, spacing: 12) {
                    Text("IMPORT DATA")
                        .font(DS.label)
                        .foregroundStyle(DS.inkTertiary)
                        .tracking(0.8)

                    VStack(spacing: 10) {
                        ImportActionRow(
                            icon: "briefcase.fill",
                            title: "Import Standard Portfolio",
                            subtitle: "Import holdings from CSV or Excel (.xlsx) file with Portfolio Name, Symbol, Quantity, Avg Cost, Purchase Date",
                            buttonTitle: "Import Portfolio…",
                            action: onImportStandard
                        )

                        Divider().overlay(DS.hairline)

                        ImportActionRow(
                            icon: "doc.text.fill",
                            title: "Import 投資信託 (Japanese Funds)",
                            subtitle: "Import Japanese mutual funds trade history CSV or Excel (.xlsx) file",
                            buttonTitle: "Import 投資信託…",
                            action: onImportJapaneseFunds
                        )

                        Divider().overlay(DS.hairline)

                        ImportActionRow(
                            icon: "star.fill",
                            title: "Import Watchlist",
                            subtitle: "Import symbol list into a Watchlist from CSV, Excel (.xlsx), or text file",
                            buttonTitle: "Import Watchlist…",
                            action: onImportWatchlist
                        )
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 10).fill(DS.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.hairline, lineWidth: 1))
                }

                // Section 2: Download Templates
                VStack(alignment: .leading, spacing: 12) {
                    Text("DOWNLOAD SAMPLE TEMPLATES")
                        .font(DS.label)
                        .foregroundStyle(DS.inkTertiary)
                        .tracking(0.8)

                    HStack(spacing: 12) {
                        TemplateCard(
                            title: "Standard Portfolio Template",
                            subtitle: "Sample .xlsx file for standard portfolios",
                            action: onDownloadSample
                        )

                        TemplateCard(
                            title: "投資信託 Template",
                            subtitle: "Sample .xlsx file for Japanese mutual funds",
                            action: onDownloadJapaneseFundSample
                        )

                        TemplateCard(
                            title: "Watchlist Template",
                            subtitle: "Sample .xlsx file for watchlists",
                            action: onDownloadWatchlistSample
                        )
                    }
                }

                // Section 3: Export Data
                VStack(alignment: .leading, spacing: 12) {
                    Text("EXPORT DATA")
                        .font(DS.label)
                        .foregroundStyle(DS.inkTertiary)
                        .tracking(0.8)

                    VStack(spacing: 10) {
                        ImportActionRow(
                            icon: "square.and.arrow.up.fill",
                            title: "Export Portfolios",
                            subtitle: "Export all your portfolios and holdings to Excel (.xlsx)",
                            buttonTitle: "Export Portfolios (XLSX)…",
                            action: onExportPortfolios
                        )

                        Divider().overlay(DS.hairline)

                        ImportActionRow(
                            icon: "square.and.arrow.up.fill",
                            title: "Export Watchlists",
                            subtitle: "Export all your watchlists and symbols to Excel (.xlsx)",
                            buttonTitle: "Export Watchlists (XLSX)…",
                            action: onExportWatchlists
                        )
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 10).fill(DS.card))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.hairline, lineWidth: 1))
                }
            }
            .padding(24)
        }
        .background(DS.ground)
    }
}

private struct ImportActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(DS.brand)
                .frame(width: 32, height: 32)
                .background(Circle().fill(DS.brand.opacity(0.1)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.inter(14, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(DS.ink)
                Text(subtitle)
                    .font(DS.caption)
                    .foregroundStyle(DS.inkSecondary)
            }

            Spacer()

            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .tint(DS.brand)
                .controlSize(.small)
                .pointingHandCursor()
        }
    }
}

private struct TemplateCard: View {
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 16))
                    .foregroundStyle(DS.brand)
                Spacer()
            }
            Text(title)
                .font(.inter(13, weight: .semibold, relativeTo: .body))
                .foregroundStyle(DS.ink)
            Text(subtitle)
                .font(DS.micro)
                .foregroundStyle(DS.inkSecondary)

            Spacer()

            Button(action: action) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.doc")
                    Text("Download XLSX")
                }
                .font(DS.caption)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointingHandCursor()
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(RoundedRectangle(cornerRadius: 10).fill(DS.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.hairline, lineWidth: 1))
    }
}
