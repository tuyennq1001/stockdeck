import SwiftUI
import AppKit

/// Wraps a reorderable row/tab, measures its span along the drag axis, and attaches
/// drag & drop with half-split placement: dropping on the top/left half inserts the
/// dragged item BEFORE the target, on the bottom/right half AFTER it.
///
/// Performance contract:
/// - During drag hover (`dropEntered` / `dropUpdated`), items stay stationary (no live
///   array mutations or layout shifts) and only `dropIndicator` updates when the
///   `(target, placement)` pair changes.
/// - Reordering (`onMove`) executes once when the drop lands (`performDrop`).
struct ReorderRow<Target: Hashable, Content: View>: View {
    let id: Target
    @Binding var draggingId: Target?
    var excludedTargets: Set<Target> = []
    var dropIndicator: Binding<DropIndicator<Target>?>? = nil
    let isHorizontal: Bool
    var attachDragToContent: Bool = true
    let makeDragItem: () -> NSItemProvider
    let onMove: (Target, Target, InsertPlacement) -> Void
    var onCommit: () -> Void = {}
    @ViewBuilder let content: () -> Content

    @State private var axisSpan: CGFloat = 44
    @State private var localDropIndicator: DropIndicator<Target>? = nil

    private var effectiveDropIndicator: Binding<DropIndicator<Target>?> {
        dropIndicator ?? $localDropIndicator
    }

    private var isBeingDragged: Bool {
        draggingId == id || excludedTargets.contains(id)
    }

    var body: some View {
        let base = content()
            .opacity(attachDragToContent && isBeingDragged ? 0.45 : 1.0)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            let span = max(1, isHorizontal ? geo.size.width : geo.size.height)
                            if abs(axisSpan - span) > 0.5 { axisSpan = span }
                        }
                        .onChange(of: isHorizontal ? geo.size.width : geo.size.height) { _, newVal in
                            let span = max(1, newVal)
                            if abs(axisSpan - span) > 0.5 { axisSpan = span }
                        }
                }
            )
            .overlay(alignment: indicatorAlignment) {
                if let ind = effectiveDropIndicator.wrappedValue,
                   ind.target == id,
                   draggingId != nil,
                   !isBeingDragged {
                    if isHorizontal {
                        Capsule()
                            .fill(ind.color)
                            .frame(width: 3, height: 20)
                            .allowsHitTesting(false)
                    } else {
                        Capsule()
                            .fill(ind.color)
                            .frame(height: 2.5)
                            .frame(maxWidth: .infinity)
                            .allowsHitTesting(false)
                    }
                }
            }
            .onDrop(of: [.text], delegate: ReorderDropDelegate(
                targetId: id,
                draggingId: $draggingId,
                axisSpan: axisSpan,
                isHorizontal: isHorizontal,
                excludedTargets: excludedTargets,
                dropIndicator: effectiveDropIndicator,
                onMove: onMove,
                onCommit: onCommit
            ))

        if attachDragToContent {
            base.onDrag {
                let provider = makeDragItem()
                DispatchQueue.main.async {
                    draggingId = id
                }
                return provider
            }
        } else {
            base
        }
    }

    private var indicatorAlignment: Alignment {
        guard let ind = effectiveDropIndicator.wrappedValue, ind.target == id else {
            return isHorizontal ? .leading : .top
        }
        if isHorizontal { return ind.placement == .before ? .leading : .trailing }
        return ind.placement == .before ? .top : .bottom
    }
}

/// Describes where a dragged item will land: `.before`/`.after` the hovered
/// target row/tab plus the highlight color.
struct DropIndicator<Target: Hashable>: Equatable {
    let target: Target
    let placement: InsertPlacement
    let color: Color

    init(target: Target, placement: InsertPlacement, color: Color = DS.brand) {
        self.target = target
        self.placement = placement
        self.color = color
    }
}

/// Half-split drop delegate used by `ReorderRow`. `info.location` is measured in
/// the row/tab's own coordinate space, so comparing it against `axisSpan / 2`
/// decides whether the dragged item lands before or after the target.
struct ReorderDropDelegate<Target: Hashable>: DropDelegate {
    let targetId: Target
    @Binding var draggingId: Target?
    let axisSpan: CGFloat
    let isHorizontal: Bool
    var excludedTargets: Set<Target> = []
    var dropIndicator: Binding<DropIndicator<Target>?>
    let onMove: (Target, Target, InsertPlacement) -> Void
    let onCommit: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggingId != nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let sourceId = draggingId else { return false }
        let placement: InsertPlacement
        if let ind = dropIndicator.wrappedValue, ind.target == targetId {
            placement = ind.placement
        } else {
            placement = currentPlacement(for: info)
        }
        dropIndicator.wrappedValue = nil
        draggingId = nil
        if sourceId != targetId && !excludedTargets.contains(targetId) {
            withAnimation(.easeInOut(duration: 0.18)) {
                onMove(sourceId, targetId, placement)
            }
        }
        onCommit()
        return true
    }

    func dropExited(info: DropInfo) {
        if dropIndicator.wrappedValue?.target == targetId {
            dropIndicator.wrappedValue = nil
        }
    }

    func dropEntered(info: DropInfo) {
        updatePlacement(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard draggingId != nil else {
            return DropProposal(operation: .cancel)
        }
        updatePlacement(info: info)
        return DropProposal(operation: .move)
    }

    private func currentPlacement(for info: DropInfo) -> InsertPlacement {
        let coordinate = isHorizontal ? info.location.x : info.location.y
        return coordinate < max(1, axisSpan) / 2 ? .before : .after
    }

    private func updatePlacement(info: DropInfo) {
        guard let sourceId = draggingId else { return }
        if sourceId == targetId || excludedTargets.contains(targetId) {
            if dropIndicator.wrappedValue?.target == targetId {
                dropIndicator.wrappedValue = nil
            }
            return
        }
        let placement = currentPlacement(for: info)
        let next = DropIndicator(target: targetId, placement: placement, color: DS.brand)
        if dropIndicator.wrappedValue != next {
            dropIndicator.wrappedValue = next
        }
    }
}

/// Container-level fallback drop delegate so dropping slightly outside a row
/// (or on the container padding) still commits the active `dropIndicator` or
/// cleanly resets drag state.
struct ReorderContainerDropDelegate<Target: Hashable>: DropDelegate {
    @Binding var draggingId: Target?
    @Binding var dropIndicator: DropIndicator<Target>?
    var excludedTargets: Set<Target> = []
    var onMove: ((Target, Target, InsertPlacement) -> Void)? = nil
    var onCommit: () -> Void = {}

    func validateDrop(info: DropInfo) -> Bool {
        draggingId != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard draggingId != nil else {
            return DropProposal(operation: .cancel)
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        dropIndicator = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let sourceId = draggingId else { return false }
        let pending = dropIndicator
        dropIndicator = nil
        draggingId = nil
        if let pending, let onMove, sourceId != pending.target, !excludedTargets.contains(pending.target) {
            withAnimation(.easeInOut(duration: 0.18)) {
                onMove(sourceId, pending.target, pending.placement)
            }
        }
        onCommit()
        return true
    }
}

extension View {
    /// Ensures `draggingId` and `dropIndicator` are reset if a drag session ends
    /// outside any valid drop target (e.g. pressing Esc or releasing outside the window).
    /// Performs zero work when `draggingId == nil`.
    func cleanupDragSession<Target: Hashable>(
        draggingId: Binding<Target?>,
        dropIndicator: Binding<DropIndicator<Target>?>
    ) -> some View {
        self.task(id: draggingId.wrappedValue != nil) {
            guard draggingId.wrappedValue != nil else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            var releasedCount = 0
            while !Task.isCancelled && draggingId.wrappedValue != nil {
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    releasedCount += 1
                    if releasedCount >= 2 {
                        draggingId.wrappedValue = nil
                        dropIndicator.wrappedValue = nil
                        break
                    }
                } else {
                    releasedCount = 0
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }
}
