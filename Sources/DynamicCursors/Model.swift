import AppKit

// Logical coordinates use AppKit's global, bottom-left origin. Sprite hotspot
// and texture coordinates use a top-left origin; the renderer converts once.
enum CursorMode: String, CaseIterable {
    case tilt, rotate, stretch, none
}

struct CursorSettings {
    var mode: CursorMode = .tilt
    var sizeMultiplier: Double = 1.8
    var inertia: Double = 2
    var blurStrength: Double = 2
    var blurSamples: Int = 8
    var shakeEnabled = false
}

struct CursorSnapshot {
    let image: CGImage
    let size: CGSize
    let hotspot: CGPoint
    let position: CGPoint
    let revision: UInt64
}

struct CursorFrame: Equatable {
    var position: CGPoint
    var size: CGSize
    var hotspot: CGPoint
    var rotation: Double = 0
    var stretchAngle: Double = 0
    var stretch: Double = 1
    var scale: Double = 1
    // Current minus historical position, in global AppKit coordinates.
    var displacement: CGPoint = .zero
    var samples: Int = 8
}

func cursorScreen(containing point: CGPoint) -> NSScreen? {
    let screens = NSScreen.screens
    if let screen = screens.first(where: { $0.frame.contains(point) }) { return screen }
    // A pointer at the top/right desktop edge can equal maxY/maxX; CGRect's
    // half-open containment excludes those valid cursor positions.
    return screens.first {
        point.x >= $0.frame.minX && point.x <= $0.frame.maxX &&
        point.y >= $0.frame.minY && point.y <= $0.frame.maxY
    }
}

func cursorLog(_ message: String) {
    print(message)
    fflush(stdout)
}
