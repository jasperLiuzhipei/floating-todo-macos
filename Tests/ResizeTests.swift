import Foundation
import CoreGraphics

@main
struct ResizeTests {
    static func main() {
        let design = NSSize(width: 320, height: 400)
        let initial = NSSize(width: 320, height: 432)
        var side = EdgeResizeSession(initialSize: initial)
        precondition(side.size(for: initial, design: design, inset: 32, maximumScale: 1.5) == initial)
        let first = side.size(for: NSSize(width: 330, height: 432), design: design, inset: 32, maximumScale: 1.5)
        precondition(first.width == 330)
        // Native side proposals keep the original height even after our
        // proportional adjustment. That must never switch to height control.
        let second = side.size(for: NSSize(width: 335, height: 432), design: design, inset: 32, maximumScale: 1.5)
        precondition(second.width == 335 && second.height > first.height)
        let minimum = side.size(for: NSSize(width: 100, height: 432), design: design, inset: 32, maximumScale: 1.5)
        precondition(minimum.width == 240)
        let recovered = side.size(for: NSSize(width: 350, height: 432), design: design, inset: 32, maximumScale: 1.5)
        precondition(recovered.width == 350)
        var bottom = EdgeResizeSession(initialSize: initial)
        let taller = bottom.size(for: NSSize(width: 320, height: 452), design: design, inset: 32, maximumScale: 1.5)
        precondition(taller.width == 336 && taller.height == 452)
        let tallerAgain = bottom.size(for: NSSize(width: 320, height: 460), design: design, inset: 32, maximumScale: 1.5)
        precondition(tallerAgain.height == 460)
        var grip = GripResizeSession()
        precondition(grip.scale(for: .zero, current: 1, design: design, maximumScale: 1.5) == 1)
        precondition(grip.scale(for: NSPoint(x: 1, y: 1), current: 1, design: design, maximumScale: 1.5) == 1)
        let small = grip.scale(for: NSPoint(x: -500, y: 500), current: 1, design: design, maximumScale: 1.5)
        precondition(small == 0.75)
        let bigger = grip.scale(for: NSPoint(x: -490, y: 490), current: small, design: design, maximumScale: 1.5)
        precondition(bigger > 0.75)
        let large = grip.scale(for: NSPoint(x: 500, y: -500), current: bigger, design: design, maximumScale: 1.5)
        precondition(large == 1.5)
        let smaller = grip.scale(for: NSPoint(x: 490, y: -490), current: large, design: design, maximumScale: 1.5)
        precondition(smaller < 1.5)
        print("Resize tests passed: click/jitter, stable side/bottom axis, clamps and immediate reversal.")
    }
}
