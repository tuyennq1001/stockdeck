import SwiftUI

struct ImportExportWideView: View {
    @EnvironmentObject var storageService: StorageService
    @EnvironmentObject var stockService: StockService
    @ObservedObject private var syncService = iCloudSyncService.shared

    let onImportStandard: () -> Void
    let onImportJapaneseFunds: () -> Void
    let onImportWatchlist: () -> Void
    let onDownloadSample: () -> Void
    let onDownloadJapaneseFundSample: () -> Void
    let onDownloadWatchlistSample: () -> Void
    let onExportPortfolios: () -> Void
    let onExportPortfoliosMD: () -> Void
    let onExportWatchlists: () -> Void
    let onExportWatchlistsMD: () -> Void
    let onExportTransactions: () -> Void
    let onExportTransactionsMD: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(DS.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import / Export Hub")
                            .font(.inter(20, weight: .bold, relativeTo: .title2))
                            .foregroundStyle(DS.ink)
                        Text("Manage your watchlists and portfolios import, export data, and download sample templates.")
                            .font(DS.body)
                            .foregroundStyle(DS.inkSecondary)
                    }
                    Spacer()
                }
                .padding(.bottom, 4)

                // Section 0: iCloud Sync
                iCloudSyncSection

                // Section 1: Import Data
                HubTableSection(sectionTitle: "IMPORT DATA", actionHeader: "IMPORT ACTION") {
                    HubTableRow(
                        index: "1",
                        icon: "star.fill",
                        title: "Import Watchlist",
                        subtitle: "Import symbol list into a Watchlist from CSV, Excel (.xlsx), or text file",
                        buttonIcon: "square.and.arrow.down",
                        buttonTitle: "Import Watchlist…",
                        action: onImportWatchlist
                    )

                    Divider().overlay(DS.hairline)

                    HubTableRow(
                        index: "2",
                        icon: "briefcase.fill",
                        title: "Import Standard Portfolio",
                        subtitle: "Import holdings from CSV or Excel (.xlsx) file with Portfolio Name, Symbol, Quantity, Avg Price, Purchase Date",
                        buttonIcon: "square.and.arrow.down",
                        buttonTitle: "Import Portfolio…",
                        action: onImportStandard
                    )

                    Divider().overlay(DS.hairline)

                    HubTableRow(
                        index: "3",
                        icon: "doc.text.fill",
                        title: "Import Transaction History",
                        subtitle: "Import broker trade history CSV or Excel (.xlsx) file (Rakuten, SBI, Japanese Mutual Funds & Stocks)",
                        buttonIcon: "square.and.arrow.down",
                        buttonTitle: "Import History…",
                        action: onImportJapaneseFunds
                    )
                }

                // Section 2: Download Sample Templates
                HubTableSection(sectionTitle: "DOWNLOAD SAMPLE TEMPLATES", actionHeader: "SAMPLE TEMPLATE") {
                    HubTableRow(
                        index: "1",
                        icon: "star.fill",
                        title: "Watchlist Template",
                        subtitle: "Sample file supporting multiple watchlists and grouped symbols (.xlsx)",
                        buttonIcon: "arrow.down.doc.fill",
                        buttonTitle: "Download XLSX",
                        action: onDownloadWatchlistSample
                    )

                    Divider().overlay(DS.hairline)

                    HubTableRow(
                        index: "2",
                        icon: "briefcase.fill",
                        title: "Standard Portfolio Template",
                        subtitle: "Sample file with Portfolio Name, Symbol, Quantity, Avg Price, Purchase Date (.xlsx)",
                        buttonIcon: "arrow.down.doc.fill",
                        buttonTitle: "Download XLSX",
                        action: onDownloadSample
                    )

                    Divider().overlay(DS.hairline)

                    HubTableRow(
                        index: "3",
                        icon: "doc.text.fill",
                        title: "Transaction History Template",
                        subtitle: "Sample trade history file for broker trades, stocks, and Japanese mutual funds (.xlsx)",
                        buttonIcon: "arrow.down.doc.fill",
                        buttonTitle: "Download XLSX",
                        action: onDownloadJapaneseFundSample
                    )
                }

                // Section 3: Export Data
                HubTableSection(sectionTitle: "EXPORT DATA", actionHeader: "EXPORT ACTION") {
                    HubExportTableRow(
                        index: "1",
                        icon: "star.fill",
                        title: "Export Watchlists",
                        subtitle: "Export all your watchlists and symbols to Excel (.xlsx) or AI-friendly Markdown (.md)",
                        onExportXLSX: onExportWatchlists,
                        onExportMD: onExportWatchlistsMD
                    )

                    Divider().overlay(DS.hairline)

                    HubExportTableRow(
                        index: "2",
                        icon: "briefcase.fill",
                        title: "Export Portfolios",
                        subtitle: "Export all your portfolios and holdings to Excel (.xlsx) or AI-friendly Markdown (.md)",
                        onExportXLSX: onExportPortfolios,
                        onExportMD: onExportPortfoliosMD
                    )

                    Divider().overlay(DS.hairline)

                    HubExportTableRow(
                        index: "3",
                        icon: "doc.text.fill",
                        title: "Export Transactions",
                        subtitle: "Export all your logged transactions and broker trade history to Excel (.xlsx) or AI-friendly Markdown (.md)",
                        onExportXLSX: onExportTransactions,
                        onExportMD: onExportTransactionsMD
                    )
                }
            }
            .padding(24)
        }
        .background(DS.ground)
    }

    private var iCloudSyncSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ICLOUD SYNCHRONIZATION")
                .font(DS.label)
                .foregroundStyle(DS.inkTertiary)
                .tracking(0.8)

            VStack(alignment: .leading, spacing: 16) {
                // Toggle Row
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(DS.brand)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(DS.brand.opacity(0.1)))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("iCloud Sync")
                            .font(.inter(13, weight: .semibold, relativeTo: .body))
                            .foregroundStyle(DS.ink)
                        Text("Automatically synchronizes portfolios, watchlists, alerts, and notes across all your Macs, iPhones, and iPads via iCloud.")
                            .font(DS.micro)
                            .foregroundStyle(DS.inkSecondary)
                    }

                    Spacer()

                    Toggle("", isOn: $storageService.iCloudSyncEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: storageService.iCloudSyncEnabled) {
                            syncService.onSyncToggleChanged(enabled: storageService.iCloudSyncEnabled)
                        }
                }

                if storageService.iCloudSyncEnabled {
                    Divider().overlay(DS.hairline)

                    if !syncService.isiCloudAvailable {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(DS.gold)
                                .font(.system(size: 14))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("iCloud Not Signed In")
                                    .font(DS.bodyStrong)
                                    .foregroundStyle(DS.ink)
                                Text("This device is not signed in to an Apple ID. Please sign in to iCloud in macOS System Settings to enable sync.")
                                    .font(DS.micro)
                                    .foregroundStyle(DS.inkSecondary)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(DS.gold.opacity(0.12)))

                        Divider().overlay(DS.hairline)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(syncService.syncStatus.contains("Fail") ? Color.red : Color.green)
                                    .frame(width: 7, height: 7)
                                Text(syncService.syncStatus)
                                    .font(.inter(11, weight: .semibold, relativeTo: .subheadline))
                                    .foregroundStyle(DS.ink)
                            }
                            if let lastDate = syncService.lastSyncDate {
                                Text("Last sync: \(lastDate.formatted(date: .abbreviated, time: .shortened))")
                                    .font(DS.micro)
                                    .foregroundStyle(DS.inkSecondary)
                            } else {
                                Text("Not synced yet")
                                    .font(DS.micro)
                                    .foregroundStyle(DS.inkTertiary)
                            }
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            Button {
                                syncService.pushLocalData()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.icloud")
                                        .font(.system(size: 11))
                                    Text("Push to iCloud")
                                        .font(DS.caption)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .pointingHandCursor()

                            Button {
                                syncService.pullAndMerge(force: true)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down.icloud")
                                        .font(.system(size: 11))
                                    Text("Pull from iCloud")
                                        .font(DS.caption)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .pointingHandCursor()

                            Button {
                                syncService.pullAndMerge(force: true)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 11))
                                    Text(syncService.isSyncing ? "Syncing…" : "Sync Now")
                                        .font(DS.caption)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(DS.brand)
                            .controlSize(.small)
                            .pointingHandCursor()
                            .disabled(syncService.isSyncing)
                        }
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(DS.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct HubTableSection<Content: View>: View {
    let sectionTitle: String
    let actionHeader: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(sectionTitle)
                .font(DS.label)
                .foregroundStyle(DS.inkTertiary)
                .tracking(0.8)

            VStack(spacing: 0) {
                // Table Header
                HStack(spacing: 14) {
                    Text("#")
                        .font(DS.label)
                        .tracking(0.8)
                        .foregroundStyle(DS.inkTertiary)
                        .frame(width: 32, alignment: .center)

                    Text("TYPE")
                        .font(DS.label)
                        .tracking(0.8)
                        .foregroundStyle(DS.inkTertiary)

                    Spacer()

                    Text(actionHeader)
                        .font(DS.label)
                        .tracking(0.8)
                        .foregroundStyle(DS.inkTertiary)
                        .frame(width: 160, alignment: .trailing)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(DS.cardAlt.opacity(0.5))

                Divider().overlay(DS.hairline)

                content()
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(DS.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.hairline, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

private struct HubTableRow: View {
    let index: String
    let icon: String
    let title: String
    let subtitle: String
    let buttonIcon: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(index)
                .font(.inter(12, weight: .medium, relativeTo: .caption).monospacedDigit())
                .foregroundStyle(DS.inkTertiary)
                .frame(width: 32, alignment: .center)

            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(DS.brand)
                .frame(width: 28, height: 28)
                .background(Circle().fill(DS.brand.opacity(0.08)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.inter(13, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(DS.ink)
                Text(subtitle)
                    .font(DS.micro)
                    .foregroundStyle(DS.inkSecondary)
            }

            Spacer()

            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: buttonIcon)
                        .font(.system(size: 11))
                    Text(buttonTitle)
                        .font(DS.caption)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .pointingHandCursor()
            .frame(width: 160, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct HubExportTableRow: View {
    let index: String
    let icon: String
    let title: String
    let subtitle: String
    let onExportXLSX: () -> Void
    let onExportMD: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(index)
                .font(.inter(12, weight: .medium, relativeTo: .caption).monospacedDigit())
                .foregroundStyle(DS.inkTertiary)
                .frame(width: 32, alignment: .center)

            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(DS.brand)
                .frame(width: 28, height: 28)
                .background(Circle().fill(DS.brand.opacity(0.08)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.inter(13, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(DS.ink)
                Text(subtitle)
                    .font(DS.micro)
                    .foregroundStyle(DS.inkSecondary)
            }

            Spacer()

            HStack(spacing: 8) {
                Button(action: onExportXLSX) {
                    HStack(spacing: 4) {
                        Image(systemName: "tablecells")
                            .font(.system(size: 11))
                        Text("Excel (.xlsx)")
                            .font(DS.caption)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()

                Button(action: onExportMD) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 11))
                        Text("Markdown (.md)")
                            .font(DS.caption)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
