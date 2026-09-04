import SwiftUI

/// Reusable pagination controls for data tables (Closed Trades, Transactions, etc.).
struct TablePaginationBar: View {
    @Binding var currentPage: Int
    @Binding var pageSize: Int
    let totalItems: Int
    var pageSizeOptions: [Int] = [10, 20, 50]

    private var totalPages: Int {
        max(1, Int(ceil(Double(totalItems) / Double(pageSize))))
    }

    private var startItem: Int {
        totalItems == 0 ? 0 : (currentPage - 1) * pageSize + 1
    }

    private var endItem: Int {
        min(currentPage * pageSize, totalItems)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Left: Item range status
            Text("Showing \(startItem)–\(endItem) of \(totalItems)")
                .font(DS.caption)
                .foregroundStyle(DS.inkSecondary)

            Spacer()

            // Page Size Selector
            HStack(spacing: 6) {
                Text("Rows per page:")
                    .font(DS.caption)
                    .foregroundStyle(DS.inkTertiary)

                Menu {
                    ForEach(pageSizeOptions, id: \.self) { size in
                        Button("\(size)") {
                            pageSize = size
                            currentPage = 1
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(pageSize)")
                            .font(DS.bodyStrong)
                            .foregroundStyle(DS.ink)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(DS.inkTertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(DS.cardAlt)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
            }

            // Page Navigation Controls
            HStack(spacing: 4) {
                Button {
                    if currentPage > 1 {
                        currentPage -= 1
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(currentPage > 1 ? DS.ink : DS.inkTertiary.opacity(0.3))
                        .frame(width: 24, height: 24)
                        .background(DS.cardAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(currentPage <= 1)
                .pointingHandCursor()

                Text("\(currentPage) / \(totalPages)")
                    .font(DS.figure)
                    .foregroundStyle(DS.ink)
                    .padding(.horizontal, 8)

                Button {
                    if currentPage < totalPages {
                        currentPage += 1
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(currentPage < totalPages ? DS.ink : DS.inkTertiary.opacity(0.3))
                        .frame(width: 24, height: 24)
                        .background(DS.cardAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(currentPage >= totalPages)
                .pointingHandCursor()
            }
        }
        .padding(.top, 10)
    }
}
