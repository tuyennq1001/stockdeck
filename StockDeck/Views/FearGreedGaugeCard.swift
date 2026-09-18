import SwiftUI

// MARK: - Fear & Greed Gauge Card

struct FearGreedGaugeCard: View {
    let stockData: FearGreedData?
    let cryptoData: FearGreedData?
    @Environment(\.openURL) private var openURL
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack(alignment: .center, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "gauge.with.needle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DS.brand)
                    Text("MARKET SENTIMENT")
                        .font(.inter(10, weight: .bold, relativeTo: .caption2))
                        .tracking(1.1)
                        .foregroundStyle(DS.brand)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(DS.brand.opacity(0.12))
                )

                Spacer()

                Text("FEAR & GREED INDEX")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkTertiary)
            }

            // Dual Gauges: Stocks | Crypto
            HStack(spacing: 16) {
                SingleGaugeView(data: stockData, market: .stock)
                    .frame(maxWidth: .infinity)

                Rectangle()
                    .fill(DS.cardAlt)
                    .frame(width: 1)
                    .padding(.vertical, 4)

                SingleGaugeView(data: cryptoData, market: .crypto)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 4)

            // Footer / Source Attribution
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.inkTertiary)
                Text("Source: CNN Business (Stocks) · Alternative.me (Crypto)")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkTertiary)
                Spacer()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DS.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(DS.brand.opacity(0.12), lineWidth: 1)
                )
        )
        .premiumCard(elevated: hovered)
        .onHover { hovered = $0 }
    }
}

// MARK: - Single Gauge

private struct SingleGaugeView: View {
    let data: FearGreedData?
    let market: FearGreedData.Market
    @Environment(\.openURL) private var openURL

    private static let segmentColors: [Color] = [
        Color(red: 0.85, green: 0.18, blue: 0.18), // Extreme Fear
        Color(red: 0.95, green: 0.45, blue: 0.15), // Fear
        Color(red: 0.92, green: 0.78, blue: 0.20), // Neutral
        Color(red: 0.38, green: 0.76, blue: 0.32), // Greed
        Color(red: 0.12, green: 0.62, blue: 0.22)  // Extreme Greed
    ]

    var body: some View {
        Button {
            if let url = URL(string: market.sourceURL) {
                openURL(url)
            }
        } label: {
            VStack(spacing: 8) {
                // Market Title Chip
                HStack(spacing: 4) {
                    Text(market == .stock ? "🇺🇸" : "🪙")
                        .font(.system(size: 12))
                    Text(LocalizedStringKey(market.displayName))
                        .font(.inter(12, weight: .bold, relativeTo: .caption))
                        .foregroundStyle(DS.ink)
                }

                if let data = data {
                    // Semicircle Gauge
                    ZStack(alignment: .bottom) {
                        // Background track
                        SemicircleArcShape()
                            .stroke(DS.cardAlt, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .frame(width: 140, height: 70)

                        // Colored gradient arc
                        SemicircleArcShape()
                            .stroke(
                                AngularGradient(
                                    gradient: Gradient(colors: Self.segmentColors),
                                    center: .bottom,
                                    startAngle: .degrees(180),
                                    endAngle: .degrees(360)
                                ),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round)
                            )
                            .frame(width: 140, height: 70)

                        // Needle
                        NeedleShape()
                            .fill(DS.ink)
                            .frame(width: 6, height: 44)
                            .rotationEffect(.degrees(needleAngle(for: data.score)), anchor: .bottom)
                            .offset(y: 2)

                        // Pivot pin
                        Circle()
                            .fill(DS.ink)
                            .frame(width: 10, height: 10)
                            .offset(y: 5)
                    }
                    .frame(height: 75)
                    .padding(.top, 4)

                    // Score & Label
                    VStack(spacing: 2) {
                        Text("\(data.score)")
                            .font(.inter(24, weight: .bold, relativeTo: .title2).monospacedDigit())
                            .foregroundStyle(DS.ink)

                        Text(LocalizedStringKey(FearGreedData.label(for: data.score)))
                            .font(.inter(11, weight: .bold, relativeTo: .caption))
                            .foregroundStyle(scoreColor(for: data.score))
                    }

                    // Delta & Historical comparison
                    VStack(spacing: 3) {
                        if let change = data.dailyChange {
                            HStack(spacing: 3) {
                                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                                    .font(.system(size: 8, weight: .bold))
                                (Text(change >= 0 ? "+\(change) " : "\(change) ") + Text("vs yesterday"))
                                    .font(.inter(9.5, weight: .semibold, relativeTo: .caption2))
                            }
                            .foregroundStyle(change >= 0 ? DS.up : DS.down)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill((change >= 0 ? DS.up : DS.down).opacity(0.12))
                            )
                        }

                        if let weekAgo = data.weekAgo {
                            HStack(spacing: 3) {
                                Text("Last week: \(weekAgo)")
                                if let monthAgo = data.monthAgo {
                                    Text("·")
                                    Text("Last month: \(monthAgo)")
                                }
                            }
                            .font(DS.micro)
                            .foregroundStyle(DS.inkTertiary)
                            .lineLimit(1)
                        }
                    }
                    .padding(.top, 2)
                } else {
                    // Loading Skeleton
                    VStack(spacing: 10) {
                        SemicircleArcShape()
                            .stroke(DS.cardAlt, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .frame(width: 140, height: 70)

                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(DS.cardAlt)
                                .frame(width: 44, height: 22)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(DS.cardAlt)
                                .frame(width: 70, height: 12)
                        }
                    }
                    .frame(height: 140)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func needleAngle(for score: Int) -> Double {
        // Map 0 -> -90 deg, 50 -> 0 deg, 100 -> +90 deg
        let clamped = max(0, min(100, score))
        return Double(clamped) * 1.8 - 90.0
    }

    private func scoreColor(for score: Int) -> Color {
        switch score {
        case 0...24: return Self.segmentColors[0]
        case 25...44: return Self.segmentColors[1]
        case 45...55: return Self.segmentColors[2]
        case 56...74: return Self.segmentColors[3]
        default: return Self.segmentColors[4]
        }
    }
}

// MARK: - Shapes

private struct SemicircleArcShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width / 2, rect.height) - 5
        let center = CGPoint(x: rect.midX, y: rect.maxY)

        path.addArc(
            center: center,
            radius: max(1, radius),
            startAngle: .degrees(180),
            endAngle: .degrees(0),
            clockwise: false
        )
        return path
    }
}

private struct NeedleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tipX = rect.midX
        let tipY = rect.minY
        let baseY = rect.maxY
        let halfBase = rect.width / 2

        path.move(to: CGPoint(x: tipX, y: tipY))
        path.addLine(to: CGPoint(x: rect.midX + halfBase, y: baseY))
        path.addLine(to: CGPoint(x: rect.midX - halfBase, y: baseY))
        path.closeSubpath()
        return path
    }
}
