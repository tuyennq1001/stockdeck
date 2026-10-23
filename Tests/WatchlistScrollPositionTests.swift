import XCTest
import AppKit
@testable import StockDeck

@MainActor
final class WatchlistScrollPositionTests: XCTestCase {
    func testScrollPositionsAreStoredPerWatchlistAndPrunedWhenDeleted() {
        let store = WatchlistScrollPositionStore()
        let first = UUID()
        let second = UUID()
        let firstPosition = NSPoint(x: 72, y: 640)
        let secondPosition = NSPoint(x: 0, y: 120)

        store.save(firstPosition, for: first)
        store.save(secondPosition, for: second)

        XCTAssertEqual(store.position(for: first), firstPosition)
        XCTAssertEqual(store.position(for: second), secondPosition)

        store.retain(watchlistIDs: [second])

        XCTAssertEqual(store.position(for: first), .zero)
        XCTAssertEqual(store.position(for: second), secondPosition)
    }

    func testRestoredPositionIsClampedToCurrentContentBounds() {
        let restored = NSPoint(x: 900, y: 1200)

        XCTAssertEqual(
            ScrollSyncCoordinator.clampedPosition(restored, maximumX: 320, maximumY: 480),
            NSPoint(x: 320, y: 480)
        )
        XCTAssertEqual(
            ScrollSyncCoordinator.clampedPosition(NSPoint(x: -4, y: -9), maximumX: 320, maximumY: 480),
            .zero
        )
        XCTAssertEqual(
            ScrollSyncCoordinator.clampedPosition(restored, maximumX: -1, maximumY: -1),
            .zero
        )
    }

    func testWatchlistAttachmentsDoNotApplyInitialOffsetsBeforeCoordinatedRestore() async throws {
        let watchlistID = UUID()
        let savedPosition = NSPoint(x: 250, y: 420)
        let store = WatchlistScrollPositionStore()
        store.save(savedPosition, for: watchlistID)
        let coordinator = ScrollSyncCoordinator(watchlistID: watchlistID, positionStore: store)
        let header = scrollView(viewport: NSSize(width: 100, height: 28), document: NSSize(width: 500, height: 28))
        let body = scrollView(viewport: NSSize(width: 100, height: 200), document: NSSize(width: 500, height: 1000))
        let frozen = scrollView(viewport: NSSize(width: 148, height: 200), document: NSSize(width: 148, height: 1000))

        body.contentView.scroll(to: NSPoint(x: 40, y: 70))
        body.reflectScrolledClipView(body.contentView)
        coordinator.registerVerticalFrozen(frozen)
        coordinator.register2DBody(body)
        coordinator.registerHorizontalHeader(header)

        XCTAssertEqual(body.contentView.bounds.origin, NSPoint(x: 40, y: 70))
        XCTAssertEqual(frozen.contentView.bounds.origin.y, 0, accuracy: 0.5)
        XCTAssertEqual(header.contentView.bounds.origin.x, 0, accuracy: 0.5)

        coordinator.watchlistContentDidLoad(scopeID: watchlistID)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(body.contentView.bounds.origin, savedPosition)
        XCTAssertEqual(frozen.contentView.bounds.origin.y, savedPosition.y, accuracy: 0.5)
        XCTAssertEqual(header.contentView.bounds.origin.x, savedPosition.x, accuracy: 0.5)
        coordinator.reset()
    }

    func testReplacingOnlyBodyKeepsOtherObserversAndIgnoresLateDetach() async throws {
        let watchlistID = UUID()
        let store = WatchlistScrollPositionStore()
        let savedPosition = NSPoint(x: 900, y: 1200)
        store.save(savedPosition, for: watchlistID)
        let coordinator = ScrollSyncCoordinator(watchlistID: watchlistID, positionStore: store)
        let header = scrollView(viewport: NSSize(width: 100, height: 28), document: NSSize(width: 500, height: 28))
        let oldBody = scrollView(viewport: NSSize(width: 100, height: 200), document: .zero)
        let frozen = scrollView(viewport: NSSize(width: 148, height: 200), document: .zero)

        coordinator.registerVerticalFrozen(frozen)
        coordinator.register2DBody(oldBody)
        coordinator.registerHorizontalHeader(header)
        coordinator.watchlistContentDidLoad(scopeID: watchlistID)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(store.position(for: watchlistID), savedPosition)
        XCTAssertEqual(oldBody.contentView.bounds.origin, .zero)
        XCTAssertEqual(frozen.contentView.bounds.origin.y, 0, accuracy: 0.5)

        oldBody.documentView?.setFrameSize(NSSize(width: 500, height: 1000))
        frozen.documentView?.setFrameSize(NSSize(width: 148, height: 1000))
        coordinator.register2DBody(oldBody)
        coordinator.registerVerticalFrozen(frozen)
        coordinator.registerHorizontalHeader(header)
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(header.contentView.bounds.origin.x, 400, accuracy: 0.5)
        XCTAssertEqual(oldBody.contentView.bounds.origin.x, 400, accuracy: 0.5)
        XCTAssertEqual(oldBody.contentView.bounds.origin.y, 800, accuracy: 0.5)
        XCTAssertEqual(frozen.contentView.bounds.origin.y, 800, accuracy: 0.5)

        let newBody = scrollView(viewport: NSSize(width: 100, height: 200), document: NSSize(width: 500, height: 1000))
        coordinator.unregister2DBody(oldBody)
        coordinator.register2DBody(newBody)
        coordinator.unregister2DBody(oldBody) // A delayed detach must not clear the replacement.
        try await Task.sleep(for: .milliseconds(30))

        newBody.contentView.scroll(to: NSPoint(x: 100, y: 250))
        newBody.reflectScrolledClipView(newBody.contentView)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(header.contentView.bounds.origin.x, 100, accuracy: 0.5)
        XCTAssertEqual(frozen.contentView.bounds.origin.y, 250, accuracy: 0.5)
        XCTAssertEqual(store.position(for: watchlistID), NSPoint(x: 100, y: 250))

        oldBody.contentView.scroll(to: NSPoint(x: 40, y: 500))
        oldBody.reflectScrolledClipView(oldBody.contentView)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(frozen.contentView.bounds.origin.y, 250, accuracy: 0.5)

        coordinator.reset()
    }

    func testSeparateWatchlistCoordinatorsDoNotCrossSync() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let store = WatchlistScrollPositionStore()
        let firstCoordinator = ScrollSyncCoordinator(watchlistID: firstID, positionStore: store)
        let secondCoordinator = ScrollSyncCoordinator(watchlistID: secondID, positionStore: store)
        let firstHeader = scrollView(viewport: NSSize(width: 100, height: 28), document: NSSize(width: 500, height: 28))
        let firstBody = scrollView(viewport: NSSize(width: 100, height: 200), document: NSSize(width: 500, height: 1000))
        let firstFrozen = scrollView(viewport: NSSize(width: 148, height: 200), document: NSSize(width: 148, height: 1000))
        let secondHeader = scrollView(viewport: NSSize(width: 100, height: 28), document: NSSize(width: 500, height: 28))
        let secondBody = scrollView(viewport: NSSize(width: 100, height: 200), document: NSSize(width: 500, height: 1000))
        let secondFrozen = scrollView(viewport: NSSize(width: 148, height: 200), document: NSSize(width: 148, height: 1000))

        register(firstCoordinator, header: firstHeader, body: firstBody, frozen: firstFrozen, scope: firstID)
        register(secondCoordinator, header: secondHeader, body: secondBody, frozen: secondFrozen, scope: secondID)
        try await Task.sleep(for: .milliseconds(30))

        firstBody.contentView.scroll(to: NSPoint(x: 100, y: 300))
        firstBody.reflectScrolledClipView(firstBody.contentView)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(firstHeader.contentView.bounds.origin.x, 100, accuracy: 0.5)
        XCTAssertEqual(firstFrozen.contentView.bounds.origin.y, 300, accuracy: 0.5)
        XCTAssertEqual(secondHeader.contentView.bounds.origin.x, 0, accuracy: 0.5)
        XCTAssertEqual(secondFrozen.contentView.bounds.origin.y, 0, accuracy: 0.5)

        firstCoordinator.reset()
        secondCoordinator.reset()
    }

    private func register(
        _ coordinator: ScrollSyncCoordinator,
        header: NSScrollView,
        body: NSScrollView,
        frozen: NSScrollView,
        scope: UUID
    ) {
        coordinator.registerVerticalFrozen(frozen)
        coordinator.register2DBody(body)
        coordinator.registerHorizontalHeader(header)
        coordinator.watchlistContentDidLoad(scopeID: scope)
    }

    private func scrollView(viewport: NSSize, document: NSSize) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: viewport))
        scrollView.documentView = NSView(frame: NSRect(origin: .zero, size: document))
        scrollView.contentView.postsBoundsChangedNotifications = true
        return scrollView
    }

}
