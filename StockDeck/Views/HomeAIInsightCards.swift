import SwiftUI

// MARK: - Hero Pulse Card

/// Hero card displaying the overall daily market / portfolio AI pulse.
struct AIInsightPulseHeroCard: View {
    let insight: HomeAIInsight
    let isLoading: Bool
    let onRefresh: () -> Void

    @Environment(\.locale) private var locale

    private var formattedDate: String {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: insight.date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(DS.brand)
                    Text("DAILY MARKET PULSE")
                        .font(.inter(10, weight: .bold, relativeTo: .caption2))
                        .tracking(1.2)
                        .foregroundStyle(DS.brand)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(DS.brand.opacity(0.12))
                )

                Text("· \(formattedDate)")
                    .font(DS.caption)
                    .foregroundStyle(DS.inkTertiary)

                Spacer()

                Button(action: onRefresh) {
                    HStack(spacing: 4) {
                        if isLoading {
                            DSSpinner(size: 11)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        Text("Phân tích lại")
                            .font(DS.caption)
                    }
                    .foregroundStyle(DS.brand)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(DS.cardAlt))
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
            }

            Text(insight.portfolioSummary)
                .font(.inter(14, weight: .medium, relativeTo: .body))
                .foregroundStyle(DS.ink)
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.brand)
                Text("Luận điểm sinh tự động dựa trên tin tức 24h & giá đóng cửa phiên chính.")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkTertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DS.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(DS.brand.opacity(0.15), lineWidth: 1)
                )
        )
    }
}

// MARK: - Market Section Header

/// Header for a market category section (US, JP, VN, CRYPTO).
struct MarketSectionHeader: View {
    let category: MarketCategory
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(category.icon)
                .font(.system(size: 15))
            Text(category.title)
                .font(.inter(13, weight: .bold, relativeTo: .subheadline))
                .foregroundStyle(DS.ink)

            Text("\(count)")
                .font(.inter(10, weight: .semibold, relativeTo: .caption2).monospacedDigit())
                .foregroundStyle(DS.inkSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(DS.cardAlt)
                )

            Spacer()
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

/// Banner/card displaying the AI market context for a specific market category (e.g. S&P 500, Nasdaq, Nikkei, VN-Index, Bitcoin).
struct MarketOverviewCard: View {
    let category: MarketCategory
    let overview: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.brand)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Bối cảnh chung thị trường")
                    .font(.inter(10, weight: .bold, relativeTo: .caption2))
                    .tracking(0.8)
                    .foregroundStyle(DS.brand)

                Text(overview)
                    .font(.inter(12.5, weight: .medium, relativeTo: .body))
                    .foregroundStyle(DS.ink)
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.cardAlt.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(DS.brand.opacity(0.12), lineWidth: 1)
                )
        )
    }
}

// MARK: - Symbol Insight Card

/// Card showing the specific AI reasoning and drivers for a single symbol's price movement.
struct SymbolInsightCard: View {
    let item: SymbolInsightItem
    let onOpenURL: (URL) -> Void
    @State private var hovered = false

    private var changeColor: Color {
        DS.pnlColor(item.changePercent)
    }

    private var sentimentColor: Color {
        switch item.sentiment {
        case .positive: return DS.up
        case .negative: return DS.down
        case .neutral: return DS.inkSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Symbol, Name, Change Badge, Sentiment Chip
            HStack(alignment: .center, spacing: 10) {
                SymbolLogo(symbol: item.symbol, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.symbol)
                            .font(.inter(14, weight: .bold, relativeTo: .body))
                            .foregroundStyle(DS.ink)
                        Text(item.name)
                            .font(DS.caption)
                            .foregroundStyle(DS.inkSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Sentiment Badge
                Text(item.sentiment.displayLabel)
                    .font(.inter(9.5, weight: .semibold, relativeTo: .caption2))
                    .foregroundStyle(sentimentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule()
                            .fill(sentimentColor.opacity(0.12))
                    )

                // Change % Pill
                HStack(spacing: 2) {
                    Image(systemName: item.changePercent >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                    Text(String(format: "%+0.2f%%", item.changePercent))
                        .font(.inter(11, weight: .bold, relativeTo: .caption).monospacedDigit())
                }
                .foregroundStyle(changeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(changeColor.opacity(0.12))
                )
            }

            Divider()

            // Core Driver Statement
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(DS.gold)
                    Text("Luận điểm cốt lõi")
                        .font(.inter(10.5, weight: .bold, relativeTo: .caption2))
                        .foregroundStyle(DS.gold)
                }

                Text(item.coreDriver)
                    .font(.inter(13, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(DS.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DS.cardAlt)
            )

            // Bullet Points
            if !item.bulletPoints.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(item.bulletPoints, id: \.self) { point in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .font(.inter(12, weight: .bold, relativeTo: .body))
                                .foregroundStyle(DS.brand)
                            Text(point)
                                .font(DS.body)
                                .foregroundStyle(DS.inkSecondary)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            Spacer(minLength: 0)

            // Sources
            if !item.sources.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nguồn tin kiểm chứng:")
                        .font(.inter(9.5, weight: .medium, relativeTo: .caption2))
                        .foregroundStyle(DS.inkTertiary)

                    HStack(spacing: 6) {
                        ForEach(item.sources) { src in
                            if let urlStr = src.url, let url = URL(string: urlStr) {
                                Button {
                                    onOpenURL(url)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "newspaper.fill")
                                            .font(.system(size: 9))
                                        Text(src.publisher.isEmpty ? src.title : src.publisher)
                                            .font(DS.micro)
                                            .lineLimit(1)
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 8))
                                    }
                                    .foregroundStyle(DS.brand)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(DS.brand.opacity(0.10))
                                    )
                                }
                                .buttonStyle(.plain)
                            } else {
                                Text(src.publisher.isEmpty ? src.title : src.publisher)
                                    .font(DS.micro)
                                    .foregroundStyle(DS.inkTertiary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(DS.cardAlt)
                                    )
                            }
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DS.card)
        )
        .premiumCard(elevated: hovered)
        .contentShape(Rectangle())
        .onHover { inside in
            hovered = inside
        }
    }
}

// MARK: - Missing Configuration Card

/// Guide banner shown when the user hasn't configured an AI API key.
struct AIInsightMissingConfigCard: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16))
                    .foregroundStyle(DS.brand)
                Text("Kích hoạt Luận điểm Phân tích AI")
                    .font(DS.bodyStrong)
                    .foregroundStyle(DS.ink)
                Spacer()
            }

            Text("Để xem phân tích tự động vì sao các mã trong danh mục tăng/giảm theo tin tức 24h, vui lòng thêm API Key của bạn trong Cài đặt → AI Review. Hỗ trợ OpenAI, DeepSeek, Groq, OpenRouter và các chuẩn tương thích.")
                .font(DS.caption)
                .foregroundStyle(DS.inkSecondary)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button(action: onOpenSettings) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape")
                        Text("Cài đặt AI Review")
                    }
                    .font(.inter(11.5, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(DS.brand))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(DS.brand.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - Loading Card

struct AIInsightLoadingCard: View {
    var body: some View {
        VStack(spacing: 14) {
            DSSpinner(size: 24)
            Text("AI đang tổng hợp tin tức 24h & phân tích luận điểm biến động…")
                .font(DS.caption)
                .foregroundStyle(DS.inkSecondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DS.card)
        )
    }
}
