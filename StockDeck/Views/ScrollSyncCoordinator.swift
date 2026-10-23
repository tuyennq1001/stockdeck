import SwiftUI
import AppKit

/// Session-only watchlist offsets. This deliberately has no published state so
/// scroll events never invalidate SwiftUI views.
@MainActor
final class WatchlistScrollPositionStore {
    static let shared = WatchlistScrollPositionStore()

    private var positions: [UUID: NSPoint] = [:]

    func position(for watchlistID: UUID) -> NSPoint {
        positions[watchlistID] ?? .zero
    }

    func save(_ position: NSPoint, for watchlistID: UUID) {
        positions[watchlistID] = position
    }

    func retain(watchlistIDs: Set<UUID>) {
        positions = positions.filter { watchlistIDs.contains($0.key) }
    }
}

/// Coordinates horizontal and vertical scrolling across multiple NSScrollViews
/// directly at the AppKit layer with zero SwiftUI view re-renders (60/120 FPS).
@MainActor
final class ScrollSyncCoordinator: ObservableObject {
    private weak var horizontalHeaderScrollView: NSScrollView?
    private weak var bodyScrollView: NSScrollView?
    private weak var verticalFrozenScrollView: NSScrollView?

    private var isSyncingHorizontal = false
    private var isSyncingVertical = false

    private let activeWatchlistID: UUID?
    private let positionStore: WatchlistScrollPositionStore
    private var pendingWatchlistPosition: NSPoint?
    private var watchlistContentReady: Bool
    private var restorationGeneration: UInt64 = 0
    private var restorationScheduled = false

    private var hoverBoxes: [String: RowHoverBox] = [:]

    init(watchlistID: UUID? = nil, positionStore providedPositionStore: WatchlistScrollPositionStore? = nil) {
        let positionStore = providedPositionStore ?? WatchlistScrollPositionStore.shared
        self.activeWatchlistID = watchlistID
        self.positionStore = positionStore
        self.pendingWatchlistPosition = watchlistID.map { positionStore.position(for: $0) }
        self.watchlistContentReady = watchlistID == nil
    }

    func hoverBox(for symbol: String) -> RowHoverBox {
        if let box = hoverBoxes[symbol] { return box }
        let box = RowHoverBox()
        hoverBoxes[symbol] = box
        return box
    }

    func registerHorizontalHeader(_ scrollView: NSScrollView) {
        guard horizontalHeaderScrollView !== scrollView else {
            if !isAwaitingWatchlistRestore { syncHorizontalInitial() }
            restoreWatchlistPositionIfReady()
            return
        }
        if let old = horizontalHeaderScrollView {
            preserveWatchlistPositionBeforeReplacingScrollView()
            removeObserver(for: old)
        }
        horizontalHeaderScrollView = scrollView
        addObserver(for: scrollView, selector: #selector(headerBoundsDidChange(_:)))
        if !isAwaitingWatchlistRestore { syncHorizontalInitial() }
        restoreWatchlistPositionIfReady()
    }

    func register2DBody(_ scrollView: NSScrollView) {
        guard bodyScrollView !== scrollView else {
            if !isAwaitingWatchlistRestore {
                syncHorizontalInitial()
                syncVerticalInitial()
            }
            restoreWatchlistPositionIfReady()
            return
        }
        if let old = bodyScrollView {
            preserveWatchlistPositionBeforeReplacingScrollView()
            removeObserver(for: old)
        }
        bodyScrollView = scrollView
        addObserver(for: scrollView, selector: #selector(bodyBoundsDidChange(_:)))
        if !isAwaitingWatchlistRestore {
            syncHorizontalInitial()
            syncVerticalInitial()
        }
        restoreWatchlistPositionIfReady()
    }

    func registerVerticalFrozen(_ scrollView: NSScrollView) {
        guard verticalFrozenScrollView !== scrollView else {
            if !isAwaitingWatchlistRestore { syncVerticalInitial() }
            restoreWatchlistPositionIfReady()
            return
        }
        if let old = verticalFrozenScrollView {
            preserveWatchlistPositionBeforeReplacingScrollView()
            removeObserver(for: old)
        }
        verticalFrozenScrollView = scrollView
        addObserver(for: scrollView, selector: #selector(frozenBoundsDidChange(_:)))
        if !isAwaitingWatchlistRestore { syncVerticalInitial() }
        restoreWatchlistPositionIfReady()
    }

    /// A watchlist's saved offset is authoritative until all three scroll views
    /// have valid layout and the coordinated restore has completed. Syncing an
    /// early attachment from its initial zero offset causes a visible jump before
    /// the next-run-loop restore applies the saved position.
    private var isAwaitingWatchlistRestore: Bool {
        activeWatchlistID != nil && pendingWatchlistPosition != nil
    }

    func watchlistContentDidLoad(scopeID: UUID) {
        guard activeWatchlistID == scopeID else { return }
        watchlistContentReady = true
        restoreWatchlistPositionIfReady()
    }

    func unregisterHorizontalHeader(_ scrollView: NSScrollView) {
        guard horizontalHeaderScrollView === scrollView else { return }
        preserveWatchlistPositionBeforeReplacingScrollView()
        removeObserver(for: scrollView)
        horizontalHeaderScrollView = nil
        restorationGeneration &+= 1
    }

    func unregister2DBody(_ scrollView: NSScrollView) {
        guard bodyScrollView === scrollView else { return }
        preserveWatchlistPositionBeforeReplacingScrollView()
        removeObserver(for: scrollView)
        bodyScrollView = nil
        restorationGeneration &+= 1
    }

    func unregisterVerticalFrozen(_ scrollView: NSScrollView) {
        guard verticalFrozenScrollView === scrollView else { return }
        preserveWatchlistPositionBeforeReplacingScrollView()
        removeObserver(for: scrollView)
        verticalFrozenScrollView = nil
        restorationGeneration &+= 1
    }

    func reset() {
        detachScrollViews()
        hoverBoxes.removeAll()
        pendingWatchlistPosition = nil
        watchlistContentReady = false
    }

    private func addObserver(for scrollView: NSScrollView, selector: Selector) {
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: selector,
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    private func removeObserver(for scrollView: NSScrollView) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    private func preserveWatchlistPositionBeforeReplacingScrollView() {
        guard let activeWatchlistID else { return }
        pendingWatchlistPosition = positionStore.position(for: activeWatchlistID)
    }

    private func detachScrollViews() {
        if let h = horizontalHeaderScrollView { removeObserver(for: h) }
        if let b = bodyScrollView { removeObserver(for: b) }
        if let v = verticalFrozenScrollView { removeObserver(for: v) }
        horizontalHeaderScrollView = nil
        bodyScrollView = nil
        verticalFrozenScrollView = nil
        isSyncingHorizontal = false
        isSyncingVertical = false
        restorationGeneration &+= 1
    }

    private func restoreWatchlistPositionIfReady() {
        guard let target = pendingWatchlistPosition,
              watchlistContentReady,
              let scope = activeWatchlistID,
              let header = horizontalHeaderScrollView,
              let body = bodyScrollView,
              let frozen = verticalFrozenScrollView,
              !restorationScheduled else { return }

        restorationScheduled = true
        let generation = restorationGeneration
        DispatchQueue.main.async { [weak self, weak header, weak body, weak frozen] in
            guard let self else { return }
            self.restorationScheduled = false
            guard self.restorationGeneration == generation,
                  self.activeWatchlistID == scope,
                  let header,
                  let body,
                  let frozen,
                  self.horizontalHeaderScrollView === header,
                  self.bodyScrollView === body,
                  self.verticalFrozenScrollView === frozen else {
                self.restoreWatchlistPositionIfReady()
                return
            }

            body.layoutSubtreeIfNeeded()
            frozen.layoutSubtreeIfNeeded()
            header.layoutSubtreeIfNeeded()
            guard let bodyDocument = body.documentView,
                  let frozenDocument = frozen.documentView,
                  let headerDocument = header.documentView,
                  body.contentView.bounds.height > 0,
                  frozen.contentView.bounds.height > 0,
                  header.contentView.bounds.width > 0,
                  bodyDocument.bounds.height > 0,
                  frozenDocument.bounds.height > 0,
                  headerDocument.bounds.width > 0,
                  body.documentView === bodyDocument,
                  frozen.documentView === frozenDocument,
                  header.documentView === headerDocument else {
                return
            }
            let maxY = min(self.maximumOriginY(in: body), self.maximumOriginY(in: frozen))
            let maxX = min(self.maximumOriginX(in: header), self.maximumOriginX(in: body))
            let position = Self.clampedPosition(target, maximumX: maxX, maximumY: maxY)
            let x = position.x
            let y = position.y

            self.isSyncingHorizontal = true
            self.isSyncingVertical = true
            header.contentView.scroll(to: NSPoint(x: x, y: header.contentView.bounds.origin.y))
            header.reflectScrolledClipView(header.contentView)
            body.contentView.scroll(to: NSPoint(x: x, y: y))
            body.reflectScrolledClipView(body.contentView)
            frozen.contentView.scroll(to: NSPoint(x: frozen.contentView.bounds.origin.x, y: y))
            frozen.reflectScrolledClipView(frozen.contentView)
            self.isSyncingHorizontal = false
            self.isSyncingVertical = false

            let actualBodyOrigin = body.contentView.bounds.origin
            let actualHeaderX = header.contentView.bounds.origin.x
            let actualFrozenY = frozen.contentView.bounds.origin.y
            guard abs(actualBodyOrigin.x - actualHeaderX) <= 0.5,
                  abs(actualBodyOrigin.y - actualFrozenY) <= 0.5 else {
                return
            }
            self.pendingWatchlistPosition = nil
            self.positionStore.save(actualBodyOrigin, for: scope)
        }
    }

    private func maximumOriginY(in scrollView: NSScrollView) -> CGFloat {
        max(0, (scrollView.documentView?.bounds.height ?? 0) - scrollView.contentView.bounds.height)
    }

    private func maximumOriginX(in scrollView: NSScrollView) -> CGFloat {
        max(0, (scrollView.documentView?.bounds.width ?? 0) - scrollView.contentView.bounds.width)
    }

    static func clampedPosition(_ position: NSPoint, maximumX: CGFloat, maximumY: CGFloat) -> NSPoint {
        NSPoint(x: min(max(0, position.x), max(0, maximumX)),
                y: min(max(0, position.y), max(0, maximumY)))
    }

    private func syncVerticalInitial() {
        guard !isSyncingVertical,
              let body = bodyScrollView,
              let frozen = verticalFrozenScrollView else { return }
        let bodyY = body.contentView.bounds.origin.y
        let frozenY = frozen.contentView.bounds.origin.y
        if abs(bodyY - frozenY) > 0.5 {
            let targetY = bodyY
            isSyncingVertical = true
            frozen.contentView.scroll(to: NSPoint(x: frozen.contentView.bounds.origin.x, y: targetY))
            frozen.reflectScrolledClipView(frozen.contentView)
            let actualFrozenY = frozen.contentView.bounds.origin.y
            if abs(actualFrozenY - targetY) > 0.5 {
                body.contentView.scroll(to: NSPoint(x: body.contentView.bounds.origin.x, y: actualFrozenY))
                body.reflectScrolledClipView(body.contentView)
            }
            isSyncingVertical = false
        }
    }

    private func syncHorizontalInitial() {
        guard !isSyncingHorizontal,
              let header = horizontalHeaderScrollView,
              let body = bodyScrollView else { return }
        let bodyX = body.contentView.bounds.origin.x
        let headerX = header.contentView.bounds.origin.x
        if abs(bodyX - headerX) > 0.5 {
            let targetX = bodyX
            isSyncingHorizontal = true
            header.contentView.scroll(to: NSPoint(x: targetX, y: header.contentView.bounds.origin.y))
            header.reflectScrolledClipView(header.contentView)
            let actualHeaderX = header.contentView.bounds.origin.x
            if abs(actualHeaderX - targetX) > 0.5 {
                body.contentView.scroll(to: NSPoint(x: actualHeaderX, y: body.contentView.bounds.origin.y))
                body.reflectScrolledClipView(body.contentView)
            }
            isSyncingHorizontal = false
        }
    }

    @objc private func bodyBoundsDidChange(_ notification: Notification) {
        guard let bodyClip = notification.object as? NSClipView,
              bodyScrollView?.contentView === bodyClip else { return }
        var origin = bodyClip.bounds.origin
        if watchlistContentReady, let activeWatchlistID {
            positionStore.save(origin, for: activeWatchlistID)
        }

        // 1. Sync horizontal to header
        if !isSyncingHorizontal, let header = horizontalHeaderScrollView {
            isSyncingHorizontal = true
            let curHeaderX = header.contentView.bounds.origin.x
            if abs(origin.x - curHeaderX) > 0.5 {
                header.contentView.scroll(to: NSPoint(x: origin.x, y: header.contentView.bounds.origin.y))
                header.reflectScrolledClipView(header.contentView)
                let actualHeaderX = header.contentView.bounds.origin.x
                if abs(actualHeaderX - origin.x) > 0.5 {
                    bodyClip.scroll(to: NSPoint(x: actualHeaderX, y: origin.y))
                    bodyScrollView?.reflectScrolledClipView(bodyClip)
                    origin.x = bodyClip.bounds.origin.x
                }
            }
            isSyncingHorizontal = false
        }

        // 2. Sync vertical to frozen body
        if !isSyncingVertical, let frozen = verticalFrozenScrollView {
            isSyncingVertical = true
            let curFrozenY = frozen.contentView.bounds.origin.y
            if abs(origin.y - curFrozenY) > 0.5 {
                frozen.contentView.scroll(to: NSPoint(x: frozen.contentView.bounds.origin.x, y: origin.y))
                frozen.reflectScrolledClipView(frozen.contentView)
                let actualFrozenY = frozen.contentView.bounds.origin.y
                if abs(actualFrozenY - origin.y) > 0.5 {
                    bodyClip.scroll(to: NSPoint(x: origin.x, y: actualFrozenY))
                    bodyScrollView?.reflectScrolledClipView(bodyClip)
                    origin = bodyClip.bounds.origin
                }
            }
            isSyncingVertical = false
        }
        if watchlistContentReady, let activeWatchlistID {
            positionStore.save(bodyClip.bounds.origin, for: activeWatchlistID)
        }
    }

    @objc private func headerBoundsDidChange(_ notification: Notification) {
        if watchlistContentReady,
           let activeWatchlistID,
           let headerClip = notification.object as? NSClipView,
           horizontalHeaderScrollView?.contentView === headerClip {
            var position = positionStore.position(for: activeWatchlistID)
            position.x = headerClip.bounds.origin.x
            positionStore.save(position, for: activeWatchlistID)
        }
        guard !isSyncingHorizontal,
              let headerClip = notification.object as? NSClipView,
              horizontalHeaderScrollView?.contentView === headerClip,
              let body = bodyScrollView else { return }

        isSyncingHorizontal = true
        let originX = headerClip.bounds.origin.x
        let curBodyX = body.contentView.bounds.origin.x
        if abs(originX - curBodyX) > 0.5 {
            body.contentView.scroll(to: NSPoint(x: originX, y: body.contentView.bounds.origin.y))
            body.reflectScrolledClipView(body.contentView)
            let actualBodyX = body.contentView.bounds.origin.x
            if abs(actualBodyX - originX) > 0.5 {
                headerClip.scroll(to: NSPoint(x: actualBodyX, y: headerClip.bounds.origin.y))
                horizontalHeaderScrollView?.reflectScrolledClipView(headerClip)
            }
        }
        isSyncingHorizontal = false
    }

    @objc private func frozenBoundsDidChange(_ notification: Notification) {
        if watchlistContentReady,
           let activeWatchlistID,
           let frozenClip = notification.object as? NSClipView,
           verticalFrozenScrollView?.contentView === frozenClip {
            var position = positionStore.position(for: activeWatchlistID)
            position.y = frozenClip.bounds.origin.y
            positionStore.save(position, for: activeWatchlistID)
        }
        guard !isSyncingVertical,
              let frozenClip = notification.object as? NSClipView,
              verticalFrozenScrollView?.contentView === frozenClip,
              let body = bodyScrollView else { return }

        isSyncingVertical = true
        let originY = frozenClip.bounds.origin.y
        let curBodyY = body.contentView.bounds.origin.y
        if abs(originY - curBodyY) > 0.5 {
            body.contentView.scroll(to: NSPoint(x: body.contentView.bounds.origin.x, y: originY))
            body.reflectScrolledClipView(body.contentView)
            let actualBodyY = body.contentView.bounds.origin.y
            if abs(actualBodyY - originY) > 0.5 {
                frozenClip.scroll(to: NSPoint(x: frozenClip.bounds.origin.x, y: actualBodyY))
                verticalFrozenScrollView?.reflectScrolledClipView(frozenClip)
            }
        }
        isSyncingVertical = false
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

/// Lightweight NSViewRepresentable that attaches to its enclosing NSScrollView
/// and reports it to the given callback.
struct ScrollViewSyncAttachment: NSViewRepresentable {
    let onAttach: (NSScrollView) -> Void
    let onDetach: ((NSScrollView) -> Void)?

    init(onAttach: @escaping (NSScrollView) -> Void, onDetach: ((NSScrollView) -> Void)? = nil) {
        self.onAttach = onAttach
        self.onDetach = onDetach
    }

    func makeNSView(context: Context) -> AttachmentNSView {
        let view = AttachmentNSView()
        view.onAttach = onAttach
        view.onDetach = onDetach
        return view
    }

    func updateNSView(_ nsView: AttachmentNSView, context: Context) {
        nsView.onAttach = onAttach
        nsView.onDetach = onDetach
        nsView.attach(force: true)
    }

    static func dismantleNSView(_ nsView: AttachmentNSView, coordinator: ()) {
        nsView.detach()
    }

    final class AttachmentNSView: NSView {
        var onAttach: ((NSScrollView) -> Void)?
        var onDetach: ((NSScrollView) -> Void)?
        private weak var attachedScrollView: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() }
            attach()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attach()
        }

        override func layout() {
            super.layout()
            attach(force: true)
        }

        func attach(force: Bool = false) {
            if let sv = enclosingScrollView {
                if attachedScrollView === sv {
                    if force { onAttach?(sv) }
                    return
                }
                detach()
                attachedScrollView = sv
                onAttach?(sv)
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let sv = self.enclosingScrollView, self.attachedScrollView !== sv {
                        self.detach()
                        self.attachedScrollView = sv
                        self.onAttach?(sv)
                    }
                }
            }
        }

        func detach() {
            guard let attachedScrollView else { return }
            onDetach?(attachedScrollView)
            self.attachedScrollView = nil
        }

    }
}

/// Per-row hover state holder to keep hover isolated to each row
/// without triggering parent view or sibling row re-renders.
@MainActor
final class RowHoverBox: ObservableObject {
    @Published var isHovered: Bool = false
}
