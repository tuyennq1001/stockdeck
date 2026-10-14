import SwiftUI
import AppKit

/// Coordinates horizontal and vertical scrolling across multiple NSScrollViews
/// directly at the AppKit layer with zero SwiftUI view re-renders (60/120 FPS).
@MainActor
final class ScrollSyncCoordinator: ObservableObject {
    private weak var horizontalHeaderScrollView: NSScrollView?
    private weak var bodyScrollView: NSScrollView?
    private weak var verticalFrozenScrollView: NSScrollView?

    private var isSyncingHorizontal = false
    private var isSyncingVertical = false

    private var hoverBoxes: [String: RowHoverBox] = [:]

    func hoverBox(for symbol: String) -> RowHoverBox {
        if let box = hoverBoxes[symbol] { return box }
        let box = RowHoverBox()
        hoverBoxes[symbol] = box
        return box
    }

    func registerHorizontalHeader(_ scrollView: NSScrollView) {
        guard horizontalHeaderScrollView !== scrollView else { return }
        if let old = horizontalHeaderScrollView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old.contentView)
        }
        horizontalHeaderScrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(headerBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        syncHorizontalInitial()
        DispatchQueue.main.async { [weak self] in
            self?.syncHorizontalInitial()
        }
    }

    func register2DBody(_ scrollView: NSScrollView) {
        guard bodyScrollView !== scrollView else { return }
        if let old = bodyScrollView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old.contentView)
        }
        bodyScrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bodyBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        syncHorizontalInitial()
        syncVerticalInitial()
        DispatchQueue.main.async { [weak self] in
            self?.syncHorizontalInitial()
            self?.syncVerticalInitial()
        }
    }

    func registerVerticalFrozen(_ scrollView: NSScrollView) {
        guard verticalFrozenScrollView !== scrollView else { return }
        if let old = verticalFrozenScrollView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old.contentView)
        }
        verticalFrozenScrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(frozenBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        syncVerticalInitial()
        DispatchQueue.main.async { [weak self] in
            self?.syncVerticalInitial()
        }
    }

    private func syncVerticalInitial() {
        guard !isSyncingVertical,
              let body = bodyScrollView,
              let frozen = verticalFrozenScrollView else { return }
        let bodyY = body.contentView.bounds.origin.y
        let frozenY = frozen.contentView.bounds.origin.y
        if abs(bodyY - frozenY) > 0.5 {
            let targetY = max(bodyY, frozenY)
            isSyncingVertical = true
            if abs(bodyY - targetY) > 0.5 {
                body.contentView.scroll(to: NSPoint(x: body.contentView.bounds.origin.x, y: targetY))
                body.reflectScrolledClipView(body.contentView)
            }
            if abs(frozenY - targetY) > 0.5 {
                frozen.contentView.scroll(to: NSPoint(x: frozen.contentView.bounds.origin.x, y: targetY))
                frozen.reflectScrolledClipView(frozen.contentView)
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
            let targetX = max(bodyX, headerX)
            isSyncingHorizontal = true
            if abs(headerX - targetX) > 0.5 {
                header.contentView.scroll(to: NSPoint(x: targetX, y: header.contentView.bounds.origin.y))
                header.reflectScrolledClipView(header.contentView)
            }
            if abs(bodyX - targetX) > 0.5 {
                body.contentView.scroll(to: NSPoint(x: targetX, y: body.contentView.bounds.origin.y))
                body.reflectScrolledClipView(body.contentView)
            }
            isSyncingHorizontal = false
        }
    }

    @objc private func bodyBoundsDidChange(_ notification: Notification) {
        guard let bodyClip = notification.object as? NSClipView else { return }
        let origin = bodyClip.bounds.origin

        // 1. Sync horizontal to header
        if !isSyncingHorizontal, let header = horizontalHeaderScrollView {
            isSyncingHorizontal = true
            let curHeaderX = header.contentView.bounds.origin.x
            if abs(origin.x - curHeaderX) > 0.5 {
                header.contentView.scroll(to: NSPoint(x: origin.x, y: header.contentView.bounds.origin.y))
                header.reflectScrolledClipView(header.contentView)
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
            }
            isSyncingVertical = false
        }
    }

    @objc private func headerBoundsDidChange(_ notification: Notification) {
        guard !isSyncingHorizontal,
              let headerClip = notification.object as? NSClipView,
              let body = bodyScrollView else { return }

        isSyncingHorizontal = true
        let originX = headerClip.bounds.origin.x
        let curBodyX = body.contentView.bounds.origin.x
        if abs(originX - curBodyX) > 0.5 {
            body.contentView.scroll(to: NSPoint(x: originX, y: body.contentView.bounds.origin.y))
            body.reflectScrolledClipView(body.contentView)
        }
        isSyncingHorizontal = false
    }

    @objc private func frozenBoundsDidChange(_ notification: Notification) {
        guard !isSyncingVertical,
              let frozenClip = notification.object as? NSClipView,
              let body = bodyScrollView else { return }

        isSyncingVertical = true
        let originY = frozenClip.bounds.origin.y
        let curBodyY = body.contentView.bounds.origin.y
        if abs(originY - curBodyY) > 0.5 {
            body.contentView.scroll(to: NSPoint(x: body.contentView.bounds.origin.x, y: originY))
            body.reflectScrolledClipView(body.contentView)
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

    func makeNSView(context: Context) -> AttachmentNSView {
        let view = AttachmentNSView()
        view.onAttach = onAttach
        return view
    }

    func updateNSView(_ nsView: AttachmentNSView, context: Context) {
        nsView.onAttach = onAttach
    }

    final class AttachmentNSView: NSView {
        var onAttach: ((NSScrollView) -> Void)?
        private weak var attachedScrollView: NSScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attach()
        }

        override func layout() {
            super.layout()
            attach()
        }

        private func attach() {
            if let sv = enclosingScrollView {
                guard attachedScrollView !== sv else { return }
                attachedScrollView = sv
                onAttach?(sv)
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let sv = self.enclosingScrollView, self.attachedScrollView !== sv {
                        self.attachedScrollView = sv
                        self.onAttach?(sv)
                    }
                }
            }
        }
    }
}

/// Per-row hover state holder to keep hover isolated to each row
/// without triggering parent view or sibling row re-renders.
@MainActor
final class RowHoverBox: ObservableObject {
    @Published var isHovered: Bool = false
}
