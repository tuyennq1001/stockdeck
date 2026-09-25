import SwiftUI

private enum WatchlistCol {
    static let symbol: CGFloat = 126
    static let price: CGFloat = 88
    static let change: CGFloat = 76
    static let oneYear: CGFloat = 74
    static let threeYears: CGFloat = 74
}


struct WatchlistView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Environment(\.showSymbolDetail) private var showSymbolDetail
    @State private var viewModel = WatchlistViewModel()
    @Binding var showSearch: Bool
    @State private var showNewWatchlistAlert = false
    @State private var newWatchlistName = ""
    @State private var renamingWatchlist: Watchlist? = nil
    @State private var renameWatchlistName = ""
    @State private var draggingWatchlistId: UUID? = nil
    /// Live display order while dragging a watchlist tab: reordering only
    /// touches this local array (no storage writes during drag) and the final
    /// order is committed once on drop.
    @State private var previewWatchlistIds: [UUID] = []
    @State private var draggingSymbol: String? = nil
    /// Local-only preview of the flat symbol order while dragging (mirrors the
    /// wide view): no storage writes until the drop lands.
    @State private var previewSymbolOrder: [String] = []
    @State private var dropIndicator: DropIndicator<String>? = nil
    @State private var addToPortfolio: (symbol: String, portfolioId: UUID)? = nil
    @State private var alertSymbol: String? = nil
    struct TargetSheetItem: Identifiable { let symbol: String; var id: String { symbol } }
    @State private var targetSymbol: TargetSheetItem? = nil
    @State private var alertTarget: TargetSheetItem? = nil
    @State private var confirmDeleteWatchlist: Watchlist? = nil
    @State private var confirmRemoveSymbol: String? = nil

    private var currentSortKey: WatchlistSortKey {
        WatchlistSortKey.from(rawString: storageService.currentWatchlist.sortKey)
    }

    private var currentSortAsc: Bool {
        storageService.currentWatchlist.sortAsc ?? true
    }

    private func setSort(_ key: WatchlistSortKey, ascending: Bool) {
        storageService.setWatchlistSort(key: key.rawString, ascending: ascending, for: storageService.currentWatchlist.id)
    }

    private func toggleSort(_ key: WatchlistSortKey) {
        let newAsc: Bool
        if currentSortKey == key {
            newAsc = !currentSortAsc
        } else {
            newAsc = (key == .order || key == .symbol)
        }
        setSort(key, ascending: newAsc)
    }

    private var displaySymbols: [String] {
        if draggingSymbol != nil && !previewSymbolOrder.isEmpty {
            return previewSymbolOrder
        }
        return viewModel.displaySymbols
    }

    /// The flat list: drag/drop column sort, delete, move.
    private var flatList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 0) {
                ForEach(Array(displaySymbols.enumerated()), id: \.element) { _, symbol in
                    ReorderRow(
                        id: symbol,
                        draggingId: $draggingSymbol,
                        isHorizontal: false,
                        makeDragItem: {
                            if currentSortKey != .order || !currentSortAsc {
                                setSort(.order, ascending: true)
                            }
                            if previewSymbolOrder.isEmpty { previewSymbolOrder = storageService.watchlist }
                            return NSItemProvider(object: symbol as NSString)
                        },
                        onMove: { src, tgt, placement in
                            if currentSortKey != .order || !currentSortAsc {
                                setSort(.order, ascending: true)
                            }
                            moveSymbolInPreview(src, beforeOrAfter: tgt, placement: placement)
                        },
                        onCommit: { commitSymbolPreview() },
                        content: {
                            if draggingSymbol == symbol {
                                quoteOrPlaceholderRow(symbol).opacity(0)
                            } else {
                                quoteOrPlaceholderRow(symbol)
                            }
                        },
                        dropIndicator: $dropIndicator
                    )
                    if symbol != displaySymbols.last {
                        Divider().padding(.leading, 74)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .refreshable {
            if storageService.iCloudSyncEnabled {
                iCloudSyncService.shared.pullAndMerge(force: false)
            }
            await stockService.refreshAll(storageService: storageService)
        }
    }

    private var rowsBySymbol: [String: WatchlistWideView.WatchRow] {
        Dictionary(uniqueKeysWithValues: viewModel.rows.map { ($0.symbol, $0) })
    }

    /// Assembles the row used by the flat list: a real QuoteRow when quotes are
    /// loaded, else a column-aligned placeholder.
    @ViewBuilder
    private func quoteOrPlaceholderRow(_ symbol: String) -> some View {
        if let row = rowsBySymbol[symbol] {
            Button(action: {
                showSymbolDetail.perform(row.symbol)
            }) {
                QuoteRow(
                    row: row,
                    showCompanyName: storageService.showCompanyName,
                    showExtendedHours: storageService.showExtendedHours,
                    percentDecimals: storageService.percentDecimals,
                    valueDecimals: storageService.valueDecimals
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .contextMenu {
                watchlistContextMenu(symbol: symbol)
            }
        } else {
            Button(action: {
                showSymbolDetail.perform(symbol)
            }) {
                HStack(spacing: 0) {
                    HStack(spacing: 5) {
                        SymbolLogo(symbol: symbol, size: 20)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(StockService.beautifiedSymbol(symbol))
                                .font(.inter(12.5, relativeTo: .body).monospacedDigit())
                                .fontWeight(.bold)
                                .lineLimit(1)
                            if storageService.showCompanyName {
                                Text(" ")
                                    .font(.inter(10, relativeTo: .caption2))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(width: WatchlistCol.symbol, alignment: .leading)

                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4.5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .contextMenu {
                watchlistContextMenu(symbol: symbol)
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            sortHeader("Symbol", column: .symbol)
                .frame(width: WatchlistCol.symbol, alignment: .leading)
            sortHeader("Price", column: .price)
                .frame(width: WatchlistCol.price, alignment: .trailing)
            sortHeader("Today %", column: .metric(.today))
                .frame(width: WatchlistCol.change, alignment: .trailing)
            sortHeader("1Y", column: .metric(.oneYear))
                .frame(width: WatchlistCol.oneYear, alignment: .trailing)
            sortHeader("3Y", column: .metric(.threeYears))
                .frame(width: WatchlistCol.threeYears, alignment: .trailing)
        }
        .font(.inter(10.5, weight: .semibold, relativeTo: .caption2))
        .foregroundColor(.secondary)
        .tracking(0.8)
        .textCase(.uppercase)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    var body: some View {
        VStack(spacing: 0) {
            watchlistPickerBar

            Divider()

            if storageService.watchlist.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "star")
                        .font(.inter(32, relativeTo: .largeTitle))
                        .foregroundColor(.secondary)
                    Text("No symbols in \(storageService.currentWatchlist.name)")
                        .foregroundColor(.secondary)
                    Button("Add symbol") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSearch = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .pointingHandCursor()
                    Spacer()
                }
            } else {
                headerRow

                Divider()

                flatList

                Divider()

                HStack(spacing: 12) {
                    Button(action: {
                        newWatchlistName = ""
                        showNewWatchlistAlert = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Watchlist")
                        }
                        .font(.inter(10, relativeTo: .caption))
                    }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()

                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSearch = true
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Symbol")
                        }
                        .font(.inter(10, relativeTo: .caption))
                    }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .sheet(item: Binding<AddToPortfolioItem?>(
                get: {
                    if let atp = addToPortfolio {
                        return AddToPortfolioItem(symbol: atp.symbol, portfolioId: atp.portfolioId)
                    }
                    return nil
                },
                set: { addToPortfolio = $0.map { ($0.symbol, $0.portfolioId) } }
            )) { item in
                QuickAddHoldingView(symbol: item.symbol, portfolioId: item.portfolioId) {
                    addToPortfolio = nil
                }
                .environmentObject(stockService)
                .environmentObject(storageService)
                .frame(width: 300, height: storageService.advancedPositions ? 290 : 220)
            }
            .sheet(item: $alertTarget) { item in
                PriceAlertSheet(symbol: item.symbol) { alertTarget = nil }
                    .environmentObject(stockService)
                    .environmentObject(storageService)
            }
            .sheet(item: $targetSymbol) { item in
                StockTargetSheet(symbol: item.symbol) { targetSymbol = nil }
                    .environmentObject(stockService)
                    .environmentObject(storageService)
            }
            .alert("New Watchlist", isPresented: $showNewWatchlistAlert) {
                TextField("Watchlist name", text: $newWatchlistName)
                Button("Cancel", role: .cancel) { }
                Button("Create") {
                    storageService.createWatchlist(name: newWatchlistName)
                }
            } message: {
                Text("Enter a name for the new watchlist:")
            }
            .alert("Rename Watchlist", isPresented: Binding(
                get: { renamingWatchlist != nil },
                set: { if !$0 { renamingWatchlist = nil } }
            )) {
                TextField("Watchlist name", text: $renameWatchlistName)
                Button("Cancel", role: .cancel) { renamingWatchlist = nil }
                Button("Save") {
                    if let wl = renamingWatchlist {
                        storageService.renameWatchlist(id: wl.id, newName: renameWatchlistName)
                        renamingWatchlist = nil
                    }
                }
            } message: {
                Text("Enter a new name for this watchlist:")
            }
            .alert("Delete Watchlist", isPresented: Binding(get: { confirmDeleteWatchlist != nil }, set: { if !$0 { confirmDeleteWatchlist = nil } })) {
                Button("Cancel", role: .cancel) { confirmDeleteWatchlist = nil }
                Button("Delete", role: .destructive) {
                    if let w = confirmDeleteWatchlist {
                        storageService.deleteWatchlist(id: w.id)
                    }
                    confirmDeleteWatchlist = nil
                }
            } message: {
                Text("Are you sure you want to delete watchlist '\(confirmDeleteWatchlist?.name ?? "")'?")
            }
            .alert("Remove Symbol", isPresented: Binding(get: { confirmRemoveSymbol != nil }, set: { if !$0 { confirmRemoveSymbol = nil } })) {
                Button("Cancel", role: .cancel) { confirmRemoveSymbol = nil }
                Button("Remove", role: .destructive) {
                    if let sym = confirmRemoveSymbol {
                        storageService.removeFromWatchlist(sym)
                    }
                    confirmRemoveSymbol = nil
                }
            } message: {
                Text("Are you sure you want to remove \(confirmRemoveSymbol ?? "") from '\(storageService.currentWatchlist.name)'?")
            }
            .onChange(of: draggingSymbol) { _, newValue in
                if newValue == nil {
                    previewSymbolOrder = []
                    dropIndicator = nil
                }
            }
            .onChange(of: draggingWatchlistId) { _, newValue in
                if newValue == nil { previewWatchlistIds = [] }
            }
            .onDrop(of: [.text], delegate: WatchlistCommitDelegate(
                onCommit: { commitSymbolPreview() }
            ))
            .onAppear {
                Task {
                    viewModel.setup(stockService: stockService, storageService: storageService)
                    await stockService.ensureSparklines(for: storageService.watchlist)
                }
            }
            .onChange(of: storageService.selectedWatchlistId) { _, _ in
                Task {
                    await stockService.ensureSparklines(for: storageService.watchlist)
                }
            }
            .onChange(of: storageService.watchlist) { _, newWatchlist in
                Task {
                    await stockService.ensureSparklines(for: newWatchlist)
                }
            }
            .overlay {
                if showSearch {
                    ZStack {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showSearch = false
                                }
                            }

                        SearchView(mode: .watchlist, isPresented: $showSearch)
                            .frame(width: 370, height: 430)
                            .background(DS.ground)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(DS.hairline.opacity(0.8), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.22), radius: 20, y: 10)
                            .transition(.scale(scale: 0.95).combined(with: .opacity))
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showSearch)
    }

    /// The watchlist tabs in order: the local drag preview while dragging, else the
    /// persisted order.
    private var displayedWatchlists: [Watchlist] {
        if draggingWatchlistId != nil, !previewWatchlistIds.isEmpty {
            let byId = Dictionary(uniqueKeysWithValues: storageService.watchlists.map { ($0.id, $0) })
            return previewWatchlistIds.compactMap { byId[$0] }
        }
        return storageService.watchlists
    }

    private var watchlistPickerBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(displayedWatchlists) { wl in
                        let selected = wl.id == storageService.currentWatchlist.id
                        ReorderRow(
                            id: wl.id,
                            draggingId: $draggingWatchlistId,
                            isHorizontal: true,
                            makeDragItem: {
                                if previewWatchlistIds.isEmpty { previewWatchlistIds = storageService.watchlists.map(\.id) }
                                return NSItemProvider(object: wl.id.uuidString as NSString)
                            },
                            onMove: { srcId, tgtId, placement in
                                moveWatchlistInPreview(srcId, relativeTo: tgtId, placement: placement)
                            },
                            onCommit: { commitWatchlistPreview() }
                        ) {
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    storageService.selectWatchlist(id: wl.id)
                                    proxy.scrollTo(wl.id, anchor: .center)
                                }
                            }) {
                                Text(wl.name)
                                    .font(.inter(11.5, weight: selected ? .semibold : .medium, relativeTo: .caption))
                                    .foregroundColor(selected ? .white : DS.ink)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .fill(selected ? DS.brand : Color.primary.opacity(0.06))
                                    )
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .id(wl.id)
                            .contextMenu {
                                Button("Rename…") {
                                    renamingWatchlist = wl
                                    renameWatchlistName = wl.name
                                }
                                if let idx = storageService.watchlists.firstIndex(where: { $0.id == wl.id }) {
                                    if idx > 0 {
                                        Button("Move Left") {
                                            let prevId = storageService.watchlists[idx - 1].id
                                            storageService.moveWatchlist(from: wl.id, beforeOrAfter: prevId)
                                        }
                                    }
                                    if idx < storageService.watchlists.count - 1 {
                                        Button("Move Right") {
                                            let nextId = storageService.watchlists[idx + 1].id
                                            storageService.moveWatchlist(from: nextId, beforeOrAfter: wl.id)
                                        }
                                    }
                                }
                                Divider()
                                Button("Delete Watchlist", role: .destructive) {
                                    confirmDeleteWatchlist = wl
                                }
                            }
                        }
                    }

                    Button(action: {
                        newWatchlistName = ""
                        showNewWatchlistAlert = true
                    }) {
                        Image(systemName: "plus")
                            .font(.inter(10, weight: .bold, relativeTo: .caption))
                            .foregroundColor(DS.brand)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(DS.brand.opacity(0.12)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("New watchlist")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onAppear {
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(storageService.currentWatchlist.id, anchor: .center)
                    }
                }
            }
            .onChange(of: storageService.currentWatchlist.id) { _, newId in
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newId, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sortHeader(_ title: LocalizedStringKey, column: WatchlistSortKey) -> some View {
        Button(action: {
            toggleSort(column)
        }) {
            HStack(spacing: 2) {
                Text(title)
                if currentSortKey == column {
                    Image(systemName: currentSortAsc ? "chevron.up" : "chevron.down")
                        .font(.inter(8, relativeTo: .caption2))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    @ViewBuilder
    private func watchlistContextMenu(symbol: String) -> some View {
        Button {
            showSymbolDetail.perform(symbol)
        } label: {
            Label("View Details", systemImage: "chart.xyaxis.line")
        }
        Divider()

        Menu {
            ForEach(storageService.watchlists) { wl in
                Button {
                    storageService.addToWatchlist(symbol, targetWatchlistId: wl.id)
                } label: {
                    if wl.symbols.contains(symbol) {
                        Label(wl.name, systemImage: "checkmark")
                    } else {
                        Text(wl.name)
                    }
                }
            }
        } label: {
            Label("Add to Watchlist", systemImage: "star.bubble")
        }

        if !storageService.portfolios.isEmpty {
            Menu {
                ForEach(storageService.portfolios) { portfolio in
                    Button(portfolio.name) {
                        addToPortfolio = (symbol, portfolio.id)
                    }
                }
            } label: {
                Label("Add to Portfolio", systemImage: "plus.rectangle.on.folder")
            }
        }
        Divider()

        Button {
            alertTarget = TargetSheetItem(symbol: symbol)
        } label: {
            Label("Set Price Alert…", systemImage: "bell")
        }

        Button {
            targetSymbol = TargetSheetItem(symbol: symbol)
        } label: {
            Label(storageService.buyTarget(for: symbol) != nil ? "Edit Buy Target…" : "Set Buy Target…", systemImage: "target")
        }
        if storageService.buyTarget(for: symbol) != nil {
            Button(role: .destructive) {
                storageService.removeBuyTarget(for: symbol)
            } label: {
                Label("Remove Buy Target", systemImage: "trash")
            }
        }
        if let idx = storageService.watchlist.firstIndex(of: symbol) {
            Divider()
            Button {
                if currentSortKey != .order || !currentSortAsc {
                    setSort(.order, ascending: true)
                }
                moveSymbolInWatchlist(symbol, by: -1)
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .disabled(idx == 0)

            Button {
                if currentSortKey != .order || !currentSortAsc {
                    setSort(.order, ascending: true)
                }
                moveSymbolInWatchlist(symbol, by: 1)
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .disabled(idx == storageService.watchlist.count - 1)
        }
        Divider()
        Button(role: .destructive) {
            confirmRemoveSymbol = symbol
        } label: {
            Label("Remove from Watchlist", systemImage: "trash")
        }
    }

    private func moveSymbolInWatchlist(_ symbol: String, by delta: Int) {
        guard let i = storageService.watchlist.firstIndex(of: symbol) else { return }
        let j = i + delta
        guard j >= 0, j < storageService.watchlist.count else { return }
        storageService.watchlist.swapAt(i, j)
    }

    /// Live, local-only reorder of the symbol preview while dragging. No storage
    /// writes (mirrors the wide view) — the drop commits once.
    private func moveSymbolInPreview(_ sourceSymbol: String, beforeOrAfter targetSymbol: String, placement: InsertPlacement) {
        if previewSymbolOrder.isEmpty { previewSymbolOrder = storageService.watchlist }
        guard sourceSymbol != targetSymbol,
              let srcIndex = previewSymbolOrder.firstIndex(of: sourceSymbol),
              let tgtIndex = previewSymbolOrder.firstIndex(of: targetSymbol) else { return }
        let item = previewSymbolOrder.remove(at: srcIndex)
        let newTargetIndex = previewSymbolOrder.firstIndex(of: targetSymbol) ?? tgtIndex
        let insertIndex = placement == .before ? newTargetIndex : newTargetIndex + 1
        guard insertIndex >= 0, insertIndex <= previewSymbolOrder.count else { return }
        previewSymbolOrder.insert(item, at: insertIndex)
    }

    /// Persists the previewed watchlist order exactly once, when the drop lands.
    private func commitSymbolPreview() {
        guard !previewSymbolOrder.isEmpty else {
            draggingSymbol = nil
            dropIndicator = nil
            return
        }
        let final = previewSymbolOrder
        previewSymbolOrder = []
        dropIndicator = nil
        if final != storageService.watchlist {
            storageService.watchlist = final
        }
        draggingSymbol = nil
    }

    /// Live, local-only reorder of the watchlist tab preview while dragging.
    private func moveWatchlistInPreview(_ sourceId: UUID, relativeTo targetId: UUID, placement: InsertPlacement) {
        if previewWatchlistIds.isEmpty { previewWatchlistIds = storageService.watchlists.map(\.id) }
        guard sourceId != targetId,
              let srcIndex = previewWatchlistIds.firstIndex(of: sourceId),
              let tgtIndex = previewWatchlistIds.firstIndex(of: targetId) else { return }
        let item = previewWatchlistIds.remove(at: srcIndex)
        let newTargetIndex = previewWatchlistIds.firstIndex(of: targetId) ?? tgtIndex
        let insertIndex = placement == .before ? newTargetIndex : newTargetIndex + 1
        guard insertIndex >= 0, insertIndex <= previewWatchlistIds.count else { return }
        previewWatchlistIds.insert(item, at: insertIndex)
    }

    /// Persists the previewed watchlist order exactly once, when the tab drop
    /// lands (or the drag ends outside the picker bar).
    private func commitWatchlistPreview() {
        guard !previewWatchlistIds.isEmpty else {
            draggingWatchlistId = nil
            return
        }
        let final = previewWatchlistIds
        previewWatchlistIds = []
        draggingWatchlistId = nil
        storageService.commitWatchlistOrder(final)
    }

}

/// Top-level fallback so a drop anywhere in the popover list (between rows,
/// below the last row, on the header) still commits the symbol drag preview once.
private struct WatchlistCommitDelegate: DropDelegate {
    let onCommit: () -> Void

    func performDrop(info: DropInfo) -> Bool {
        onCommit()
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct AddToPortfolioItem: Identifiable {
    let symbol: String
    let portfolioId: UUID
    var id: String { "\(symbol)-\(portfolioId)" }
}

private struct AlertSheetItem: Identifiable {
    let symbol: String
    var id: String { symbol }
}

struct QuickAddHoldingView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService

    let symbol: String
    let portfolioId: UUID
    let onDismiss: () -> Void

    @State private var quantityText = ""
    @State private var avgPriceText = ""
    @State private var leverageText = ""
    @State private var isShort = false
    @State private var purchaseDate = Date()

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Add \(symbol)")
                    .font(.inter(13, weight: .bold, relativeTo: .headline))
                Spacer()
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.borderless)
            }

            if storageService.advancedPositions {
                VStack(alignment: .leading) {
                    Text("Position").font(.inter(10, relativeTo: .caption)).foregroundColor(.secondary)
                    Picker("Position", selection: $isShort) {
                        Text("Long").tag(false)
                        Text("Short").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Quantity").font(.inter(10, relativeTo: .caption)).foregroundColor(.secondary)
                    TextField("0", text: $quantityText)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading) {
                    Text("Avg cost").font(.inter(10, relativeTo: .caption)).foregroundColor(.secondary)
                    TextField("0.00", text: $avgPriceText)
                        .textFieldStyle(.roundedBorder)
                }
                if storageService.advancedPositions {
                    VStack(alignment: .leading) {
                        Text("Leverage").font(.inter(10, relativeTo: .caption)).foregroundColor(.secondary)
                        TextField("1\u{00D7}", text: $leverageText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                    }
                }
            }

            VStack(alignment: .leading) {
                Text("Purchase date").font(.inter(10, relativeTo: .caption)).foregroundColor(.secondary)
                DatePicker("", selection: $purchaseDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }

            Spacer()

            Button("Add") {
                guard let qty = Double(quantityText.replacingOccurrences(of: ",", with: ".")),
                      let price = Double(avgPriceText.replacingOccurrences(of: ",", with: ".")),
                      abs(qty) > 0, price > 0
                else { return }
                let advanced = storageService.advancedPositions
                let signedQty = (advanced && isShort) ? -abs(qty) : abs(qty)
                let leverage: Double? = {
                    guard advanced,
                          let l = Double(leverageText.replacingOccurrences(of: ",", with: ".")),
                          l > 0, l != 1
                    else { return nil }
                    return l
                }()
                storageService.addHolding(to: portfolioId, symbol: symbol, quantity: signedQty, avgPrice: price, purchaseDate: purchaseDate, leverage: leverage)
                Task { await stockService.refreshAll(storageService: storageService) }
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(quantityText.isEmpty || avgPriceText.isEmpty)
        }
        .padding()
        .onAppear {
            // Pre-fill current price
            if let quote = stockService.quotes[symbol] {
                avgPriceText = String(format: "%.2f", quote.price)
            }
        }
    }
}

struct QuoteRow: View {
    let row: WatchlistWideView.WatchRow
    let showCompanyName: Bool
    let showExtendedHours: Bool
    let percentDecimals: Int
    let valueDecimals: Int

    private var macOSSymbolCell: some View {
        let isDisplayAsset = StockService.isDisplayNameAsset(row.symbol)
        let isBuyZone = row.isInBuyZone

        return HStack(spacing: 5) {
            SymbolLogo(symbol: row.symbol, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    Text(isDisplayAsset ? (row.quote?.displayName ?? row.symbol) : row.symbol)
                        .font(.inter(12.5, relativeTo: .body).monospacedDigit())
                        .fontWeight(.bold)
                        .lineLimit(1)
                    if isBuyZone {
                        Text("🎯 MUA")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(DS.up)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(DS.up.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                if let target = row.buyTarget {
                    let currSym = row.currency.isEmpty ? "" : StorageService.currencySymbol(for: row.currency)
                    let dec = valueDecimals >= 0 ? valueDecimals : StorageService.priceDecimals(symbol: row.symbol, price: target.targetPrice)
                    let priceStr = StorageService.formatCompactNumber(target.targetPrice, decimals: dec, stripTrailingZeros: true)
                    if isBuyZone {
                        Text("🎯 \(currSym)\(priceStr)")
                            .font(.inter(10, relativeTo: .caption2).monospacedDigit())
                            .fontWeight(.medium)
                            .foregroundStyle(DS.up)
                            .lineLimit(1)
                    } else if let dist = row.toBuyTargetPercent {
                        Text(String(format: "🎯 %@%@ (%+.1f%%)", currSym, priceStr, dist))
                            .font(.inter(9.5, relativeTo: .caption2).monospacedDigit())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("🎯 \(currSym)\(priceStr)")
                            .font(.inter(10, relativeTo: .caption2).monospacedDigit())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else if showCompanyName {
                    Text(isDisplayAsset ? row.symbol : row.name)
                        .font(.inter(10, relativeTo: .caption2))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: WatchlistCol.symbol, alignment: .leading)
    }

    private var macOSPriceCell: some View {
        let displayPrice = row.price
        let dec = valueDecimals >= 0 ? valueDecimals : StorageService.priceDecimals(symbol: row.symbol, price: displayPrice)
        let formattedChange = StorageService.formatCompactNumber(row.change, decimals: dec, stripTrailingZeros: true)

        return VStack(alignment: .trailing, spacing: 1) {
            Text(StorageService.formatCompactNumber(displayPrice, decimals: dec))
                .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                .fontWeight(.medium)
            Text((row.change >= 0 ? "+" : "") + formattedChange)
                .font(.inter(10, relativeTo: .caption2).monospacedDigit())
                .fontWeight(.semibold)
                .foregroundColor(row.change >= 0 ? DS.up : DS.down)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private var macOSChangeCell: some View {
        VStack(alignment: .trailing, spacing: 1) {
            let isMarketActive = MarketCategory.isTradingDay(symbol: row.symbol, quote: row.quote, isCrypto: row.isCrypto)
            let isSessionOpen = MarketCategory.isSessionOpen(symbol: row.symbol, quote: row.quote, isCrypto: row.isCrypto)

            let pctColor: Color = isMarketActive ? (row.changePercent >= 0 ? DS.up : DS.down) : DS.inkTertiary
            Text(String(format: "%+.\(percentDecimals)f%%", row.changePercent))
                .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                .fontWeight(.medium)
                .foregroundColor(pctColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            if showExtendedHours, let q = row.quote, q.isExtendedHours, let extPct = q.extendedChangePercent {
                let isPre = q.marketState.hasPrefix("PRE")
                HStack(spacing: 1) {
                    Image(systemName: isPre ? "sun.max.fill" : "moon.fill")
                        .font(.system(size: 8, weight: .semibold))
                    Text(String(format: "%+.\(percentDecimals)f%%", extPct))
                        .font(.inter(10, relativeTo: .caption2).monospacedDigit())
                        .fontWeight(.semibold)
                }
                .foregroundColor(extPct >= 0 ? DS.up : DS.down)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            } else if !isSessionOpen {
                HStack(spacing: 1) {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 7, weight: .semibold))
                    Text("Closed")
                        .font(.inter(10, relativeTo: .caption2).monospacedDigit())
                        .fontWeight(.semibold)
                }
                .foregroundColor(DS.inkTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
    }

    private func macOSPeriodCell(value: Double?, width: CGFloat) -> some View {
        Group {
            if let value {
                Text(String(format: "%+.\(percentDecimals)f%%", value))
                    .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(value >= 0 ? DS.up : DS.down)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else {
                Text("—")
                    .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .trailing)
    }

    var body: some View {
        HStack(spacing: 0) {
            macOSSymbolCell
            macOSPriceCell.frame(width: WatchlistCol.price, alignment: .trailing)
            macOSChangeCell.frame(width: WatchlistCol.change, alignment: .trailing)
            macOSPeriodCell(value: row.oneYearChangePercent, width: WatchlistCol.oneYear)
            macOSPeriodCell(value: row.threeYearChangePercent, width: WatchlistCol.threeYears)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4.5)
    }
}
