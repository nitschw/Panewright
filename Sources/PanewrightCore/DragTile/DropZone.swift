import CoreGraphics

/// Drop-zone geometry for drag-to-tile, in the top-left-origin coordinate
/// space of CGWindowList. Center = swap; edge bands = split the target's
/// cell on that axis.
public enum DropZone: String, Equatable, Sendable, CaseIterable {
    case center, left, right, top, bottom

    /// The zone the pointer is in, or nil if outside the frame. An edge wins
    /// when the pointer is within `edgeBand` (fraction of the frame's span)
    /// of it; the nearest edge wins at corners.
    public static func zone(
        at point: CGPoint, in frame: CGRect, edgeBand: CGFloat = 0.25
    ) -> DropZone? {
        guard frame.width > 0, frame.height > 0, frame.contains(point) else {
            return nil
        }
        let u = (point.x - frame.minX) / frame.width
        let v = (point.y - frame.minY) / frame.height
        let edges: [(DropZone, CGFloat)] = [
            (.left, u), (.right, 1 - u), (.top, v), (.bottom, 1 - v),
        ]
        let nearest = edges.min { $0.1 < $1.1 }!
        return nearest.1 <= edgeBand ? nearest.0 : .center
    }

    /// The frame the dragged window would occupy — what the overlay previews.
    public func previewFrame(in frame: CGRect) -> CGRect {
        switch self {
        case .center:
            frame
        case .left:
            CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right:
            CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top:
            CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom:
            CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
    }
}
