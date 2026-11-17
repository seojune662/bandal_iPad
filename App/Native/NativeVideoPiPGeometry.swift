import CoreGraphics

/// Where the PiP window sits and how big it is. No UIKit here, so the rules are tested on their own.
enum NativeVideoPiPGeometry {
    /// Room kept between the window and the area's edges.
    static let margin: CGFloat = 12
    static let minimumWidth: CGFloat = 200
    static let defaultWidth: CGFloat = 360
    /// The window grows to at most this share of the area's width and height.
    static let maximumShare: CGFloat = 0.8
    /// Closer than this to an edge, the window sits against it.
    static let snapDistance: CGFloat = 32
    /// A drag starting this close to a corner resizes instead of moving.
    static let cornerReach: CGFloat = 36

    /// What is remembered: the width and where the centre was, as fractions of the area.
    struct Placement: Codable, Equatable {
        var width: CGFloat
        var x: CGFloat
        var y: CGFloat
    }
    enum Corner: CaseIterable { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    /// Odd shapes (a page's 1 px video, a portrait phone clip) stay between 1:2 and 3:1.
    static func clampAspect(_ aspect: CGFloat) -> CGFloat {
        aspect.isFinite && aspect > 0 ? min(3, max(0.5, aspect)) : 16 / 9
    }
    /// The size for a wanted width: the picture's shape, no smaller than the minimum and no larger than fits.
    static func size(width: CGFloat, aspect: CGFloat, in area: CGRect) -> CGSize {
        let aspect = clampAspect(aspect)
        let room = CGSize(width: max(0, area.width - 2 * margin), height: max(0, area.height - 2 * margin))
        let largest = max(1, min(room.width * maximumShare, room.height * maximumShare * aspect))
        let smallest = min(minimumWidth, largest)
        let width = min(largest, max(smallest, width.isFinite ? width : defaultWidth))
        return CGSize(width: width, height: width / aspect)
    }
    /// Kept inside the area, `margin` from its edges.
    static func clamp(_ frame: CGRect, in area: CGRect) -> CGRect {
        let inner = area.insetBy(dx: margin, dy: margin)
        var frame = frame
        frame.origin.x = min(max(frame.minX, inner.minX), max(inner.minX, inner.maxX - frame.width))
        frame.origin.y = min(max(frame.minY, inner.minY), max(inner.minY, inner.maxY - frame.height))
        return frame
    }
    /// Near an edge it sits against it, as a magnet would hold it.
    static func snap(_ frame: CGRect, in area: CGRect) -> CGRect {
        let inner = area.insetBy(dx: margin, dy: margin)
        var frame = clamp(frame, in: area)
        if frame.minX - inner.minX < snapDistance { frame.origin.x = inner.minX }
        else if inner.maxX - frame.maxX < snapDistance { frame.origin.x = inner.maxX - frame.width }
        if frame.minY - inner.minY < snapDistance { frame.origin.y = inner.minY }
        else if inner.maxY - frame.maxY < snapDistance { frame.origin.y = inner.maxY - frame.height }
        return clamp(frame, in: area)
    }
    /// Where a flick comes to rest: it carries on a little the way it was thrown, then snaps.
    static func projected(_ frame: CGRect, velocity: CGPoint, in area: CGRect) -> CGRect {
        let carry: CGFloat = 0.12
        let dx = velocity.x.isFinite ? velocity.x * carry : 0, dy = velocity.y.isFinite ? velocity.y * carry : 0
        return snap(frame.offsetBy(dx: dx, dy: dy), in: area)
    }
    /// The corner a point (in the window's own coordinates) is on, if it is close enough to one.
    static func corner(at point: CGPoint, in size: CGSize) -> Corner? {
        let reach = min(cornerReach, size.width / 3, size.height / 3)
        let left = point.x <= reach, right = point.x >= size.width - reach
        let top = point.y <= reach, bottom = point.y >= size.height - reach
        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeading
        case (_, true, true, _): return .topTrailing
        case (true, _, _, true): return .bottomLeading
        case (_, true, _, true): return .bottomTrailing
        default: return nil
        }
    }
    /// Dragging a corner: the opposite corner stays where it is and the picture keeps its shape.
    static func resized(_ frame: CGRect, corner: Corner, by translation: CGPoint, aspect: CGFloat, in area: CGRect) -> CGRect {
        let aspect = clampAspect(aspect)
        let trailing = corner == .topTrailing || corner == .bottomTrailing
        let bottom = corner == .bottomLeading || corner == .bottomTrailing
        let dx = trailing ? translation.x : -translation.x
        let dy = (bottom ? translation.y : -translation.y) * aspect
        let wanted = size(width: frame.width + (abs(dx) >= abs(dy) ? dx : dy), aspect: aspect, in: area)
        let x = trailing ? frame.minX : frame.maxX - wanted.width
        let y = bottom ? frame.minY : frame.maxY - wanted.height
        return clamp(CGRect(x: x, y: y, width: wanted.width, height: wanted.height), in: area)
    }
    /// Two fingers: the size scales about the window's centre.
    static func scaled(_ frame: CGRect, by scale: CGFloat, aspect: CGFloat, in area: CGRect) -> CGRect {
        let wanted = size(width: frame.width * (scale.isFinite && scale > 0 ? scale : 1), aspect: aspect, in: area)
        return clamp(CGRect(x: frame.midX - wanted.width / 2, y: frame.midY - wanted.height / 2, width: wanted.width, height: wanted.height), in: area)
    }
    /// The same window with the picture's new shape: as wide as before where it fits, around the same centre.
    static func reshaped(_ frame: CGRect, aspect: CGFloat, in area: CGRect) -> CGRect {
        let wanted = size(width: frame.width, aspect: aspect, in: area)
        return snap(CGRect(x: frame.midX - wanted.width / 2, y: frame.midY - wanted.height / 2, width: wanted.width, height: wanted.height), in: area)
    }
    /// The frame for a saved placement fitted to the area now, or the bottom-trailing corner the first time.
    static func frame(for placement: Placement?, aspect: CGFloat, in area: CGRect) -> CGRect {
        let wanted = size(width: placement?.width ?? defaultWidth, aspect: aspect, in: area)
        guard let placement, placement.x.isFinite, placement.y.isFinite else {
            return clamp(CGRect(x: area.maxX - margin - wanted.width, y: area.maxY - margin - wanted.height, width: wanted.width, height: wanted.height), in: area)
        }
        let centre = CGPoint(x: area.minX + placement.x * area.width, y: area.minY + placement.y * area.height)
        return snap(CGRect(x: centre.x - wanted.width / 2, y: centre.y - wanted.height / 2, width: wanted.width, height: wanted.height), in: area)
    }
    static func placement(of frame: CGRect, in area: CGRect) -> Placement {
        Placement(width: frame.width,
                  x: area.width > 0 ? (frame.midX - area.minX) / area.width : 1,
                  y: area.height > 0 ? (frame.midY - area.minY) / area.height : 1)
    }
    /// The part of `bounds` a docked keyboard leaves free. A floating or split iPad keyboard leaves the area as it is.
    static func area(_ bounds: CGRect, keyboard: CGRect?) -> CGRect {
        guard let keyboard, !keyboard.isNull, keyboard.height > 0, keyboard.intersects(bounds), keyboard.minY > bounds.minY,
              keyboard.maxY >= bounds.maxY - 1 else { return bounds }
        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(0, keyboard.minY - bounds.minY))
    }
}
