import Foundation
import CoreGraphics

/// Keep a native edge's driving axis stable for the entire gesture. Comparing
/// with the already constrained frame makes the orthogonal axis take over.
struct EdgeResizeSession {
    enum Axis { case width, height }
    let initialSize: NSSize
    private(set) var axis: Axis?

    mutating func size(for proposed: NSSize, design: NSSize, inset: CGFloat,
                       maximumScale: CGFloat) -> NSSize {
        let dx = abs(proposed.width - initialSize.width)
        let dy = abs(proposed.height - initialSize.height)
        if axis == nil {
            guard max(dx, dy) >= 1 else { return initialSize }
            axis = dx >= dy ? .width : .height
        }
        let requested = axis == .width ? proposed.width / design.width
            : (proposed.height - inset) / design.height
        let scale = min(maximumScale, max(0.75, requested))
        return NSSize(width: design.width * scale, height: design.height * scale + inset)
    }
}

/// Ignore click jitter and consume movement even at a size limit, so reversing
/// direction immediately works instead of requiring the pointer to backtrack.
struct GripResizeSession {
    private var previous = NSPoint.zero
    private var started = false

    mutating func scale(for delta: NSPoint, current: CGFloat, design: NSSize,
                        maximumScale: CGFloat) -> CGFloat {
        if !started {
            guard hypot(delta.x, delta.y) >= 3 else { return current }
            started = true
        }
        let step = NSPoint(x: delta.x - previous.x, y: delta.y - previous.y)
        previous = delta
        let amount = (step.x * design.width - step.y * design.height)
            / (design.width * design.width + design.height * design.height)
        return min(maximumScale, max(0.75, current + amount))
    }
}
