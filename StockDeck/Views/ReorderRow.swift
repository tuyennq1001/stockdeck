import SwiftUI

/// Wraps a reorderable row/tab, measures its size, and attaches drag & drop with
/// half-split placement: dropping on the top/left half inserts the dragged item
/// BEFORE the target, on the bottom/right half AFTER it. The after-half of the
/// last row is what lets an item reach the very end of a list.
struct ReorderRow<Target: Hashable, Content: View>: View {
    let id: Target
    @Binding var draggingId: Target?
    let isHorizontal: Bool
    var attachDragToContent: Bool = true
    let makeDragItem: () -> NSItemProvider
    let onMove: (Target, Target, InsertPlacement) -> Void
    let onCommit: () -> Void
    @ViewBuilder let content: () -> Content

    /// Optional drop indicator: when set, this row paints a highlight line at the
    /// top (`placement == .before`) or bottom (`placement == .after`) while an
    /// external `DropIndicator<Target>` points at it. Used by Watchlist sections
    /// to show exactly where a dragged symbol will land.
    var dropIndicator: Binding<DropIndicator<Target>?>?

    @State private var height: CGFloat = 44

    var body: some View {
        let base = content()
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            let newH = max(1, geo.size.height)
                            if height != newH { height = newH }
                        }
                        .onChange(of: geo.size.height) { _, h in
                            let newH = max(1, h)
                            if height != newH { height = newH }
                        }
                }
            )
            .overlay(alignment: draggingSide) {
                if let ind = dropIndicator?.wrappedValue, ind.target == id {
                    if isHorizontal {
                        Rectangle()
                            .fill(ind.color)
                            .frame(width: 3)
                            .frame(maxHeight: .infinity)
                    } else {
                        Rectangle()
                            .fill(ind.color)
                            .frame(height: 3)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .onDrop(of: [.text], delegate: ReorderDropDelegate(
                targetId: id,
                draggingId: $draggingId,
                height: height,
                isHorizontal: isHorizontal,
                dropIndicator: dropIndicator,
                onMove: onMove,
                onCommit: onCommit
            ))

        if attachDragToContent {
            base.onDrag {
                draggingId = id
                return makeDragItem()
            }
        } else {
            base
        }
    }

    private var draggingSide: Alignment {
        guard let ind = dropIndicator?.wrappedValue, ind.target == id else {
            return isHorizontal ? .leading : .top
        }
        if isHorizontal { return ind.placement == .before ? .leading : .trailing }
        return ind.placement == .before ? .top : .bottom
    }
}

/// Describes where a symbol would land while dragging: `.before`/`.after` the
/// hovered row plus the highlight color (brand for same-section drops, neutral
/// for an empty/bucket target).
struct DropIndicator<Target: Hashable>: Equatable {
    let target: Target
    let placement: InsertPlacement
    let color: Color

    init(target: Target, placement: InsertPlacement, color: Color = Color.accentColor) {
        self.target = target
        self.placement = placement
        self.color = color
    }
}

/// Half-split drop delegate used by `ReorderRow`. `info.location` is measured in
/// the row's own coordinate space, so comparing it against the measured height
/// decides whether the dragged item lands before or after the target.
struct ReorderDropDelegate<Target: Hashable>: DropDelegate {
    let targetId: Target
    @Binding var draggingId: Target?
    let height: CGFloat
    let isHorizontal: Bool
    var dropIndicator: Binding<DropIndicator<Target>?>?
    let onMove: (Target, Target, InsertPlacement) -> Void
    let onCommit: () -> Void

    func performDrop(info: DropInfo) -> Bool {
        onCommit()
        draggingId = nil
        dropIndicator?.wrappedValue = nil
        return true
    }

    func dropExited(info: DropInfo) {
        if dropIndicator?.wrappedValue?.target == targetId {
            dropIndicator?.wrappedValue = nil
        }
    }

    func dropEntered(info: DropInfo) {
        updatePlacement(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updatePlacement(info: info)
        return DropProposal(operation: .move)
    }

    private func updatePlacement(info: DropInfo) {
        guard let draggingId = draggingId, draggingId != targetId else { return }
        let coordinate = isHorizontal ? info.location.x : info.location.y
        let placement: InsertPlacement = coordinate < height / 2 ? .before : .after
        if dropIndicator?.wrappedValue?.target != targetId || dropIndicator?.wrappedValue?.placement != placement {
            dropIndicator?.wrappedValue = DropIndicator(target: targetId, placement: placement)
            withAnimation(.easeOut(duration: 0.15)) {
                onMove(draggingId, targetId, placement)
            }
        }
    }
}
