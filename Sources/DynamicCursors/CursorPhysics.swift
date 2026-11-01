import AppKit

// Dynamics adapted from egon-r/hypr-dynamic-cursors, commit
// e4a093d15e0f18dfdabaf27ab85a70c9913880ae (Copyright 2024 Virt, MIT).
// See the distributed third-party license notice for the complete permission text.
final class CursorPhysics {
    private struct MotionSample {
        var time: Double = 0
        var position: CGPoint = .zero
    }

    // At most one slot per millisecond: enough for the one-second shake window,
    // the 100 ms mode window, and the maximum 250 ms blur exposure, plus a
    // predecessor for interpolation. Storage is allocated only at construction.
    private var history = [MotionSample](repeating: MotionSample(), count: 2048)
    private var historyStart = 0
    private var historyCount = 0
    private var lastPushTime = -Double.infinity
    private var lastTime: Double?
    private var lastPosition: CGPoint = .zero
    private var revision: UInt64?
    private var mode: CursorMode?
    private var modeStartedAt: Double = 0

    private var springPosition: Double = 0
    private var springVelocity: Double = 0
    private var stickEnd: CGPoint = .zero
    private var stickInitialized = false
    private var stickRotation: Double = 0

    private var shakeStarted = false
    private var shakeExpiresAt: Double = 0
    private var shakeScale: Double = 1
    private var shakeGoal: Double = 1
    private var shakeFrom: Double = 1
    private var shakeAnimationStartedAt: Double = 0

    func reset() {
        historyStart = 0
        historyCount = 0
        lastPushTime = -Double.infinity
        lastTime = nil
        lastPosition = .zero
        revision = nil
        mode = nil
        modeStartedAt = 0
        resetMode()
        resetShake()
    }

    func frame(snapshot: CursorSnapshot, at time: Double, refreshRate: Double,
               settings: CursorSettings) -> CursorFrame {
        // The hotspot is never moved or filtered: every visual transform is
        // relative to the actual click position supplied by the snapshot.
        var result = CursorFrame(position: snapshot.position, size: snapshot.size,
                                 hotspot: snapshot.hotspot)
        result.scale = settings.sizeMultiplier
        result.samples = min(64, max(1, settings.blurSamples))
        guard time.isFinite, snapshot.position.x.isFinite, snapshot.position.y.isFinite else {
            reset()
            return result
        }

        var dt = lastTime.map { time - $0 } ?? 0
        let dx = Double(snapshot.position.x - lastPosition.x)
        let dy = Double(snapshot.position.y - lastPosition.y)
        // Snapshots cannot distinguish a hardware move from a pointer warp.
        // Discard implausibly large jumps, or even a single suspended frame,
        // rather than smearing between displays or integrating a stale spring.
        let warpDistance = max(512, 16_000 * min(max(dt, 0), 0.05))
        if revision != snapshot.revision || dt < 0 || dt > 0.25 ||
            (lastTime != nil && hypot(dx, dy) > warpDistance) {
            reset()
            dt = 0
        }
        revision = snapshot.revision
        lastTime = time
        lastPosition = snapshot.position
        record(position: snapshot.position, at: time)

        if mode != settings.mode {
            mode = settings.mode
            modeStartedAt = time
            resetMode()
        }

        // Fixed-time history, rather than N refreshes, keeps behavior consistent
        // on variable-refresh and mixed-refresh displays. Startup is equivalent
        // to pre-filling the 100 ms window with the first position.
        let previous = position(at: max(time - 0.1, modeStartedAt))
        let velocityX = Double(snapshot.position.x - previous.x) / 0.1
        let velocityY = Double(snapshot.position.y - previous.y) / 0.1
        switch settings.mode {
        case .tilt:
            let amount = min(abs(velocityX) / 5_000, 1)
            let activation = (2 * amount - amount * amount) * (velocityX < 0 ? -1 : 1)
            let target = activation * (.pi / 3)
            let mass = settings.inertia.isFinite ? min(10, max(0, settings.inertia)) : 2
            if mass == 0 {
                springPosition = target
                springVelocity = 0
            } else {
                advanceSpring(toward: target, mass: mass, dt: dt)
            }
            // Positive x motion gives positive, clockwise screen rotation.
            result.rotation = springPosition
        case .rotate:
            result.rotation = rotate(at: snapshot.position)
        case .stretch:
            let speed = hypot(velocityX, velocityY)
            let normalized = min(speed / 3_000, 1)
            result.stretch = 1 + normalized * normalized
            // The renderer's long axis is horizontal at angle 0, in top-left
            // screen coordinates. Negate AppKit's bottom-up y exactly once.
            result.stretchAngle = speed > 0 ? atan2(-velocityY, velocityX) : 0
        case .none:
            break
        }

        if settings.shakeEnabled {
            let magnification = updateShake(at: time, dt: dt)
            result.scale *= magnification
            // Match the upstream default shake:effects=false behavior.
            if magnification > 1 {
                result.rotation = 0
                result.stretch = 1
                result.stretchAngle = 0
            }
        } else {
            resetShake()
        }

        // Blur is deliberately independent of the deformation mode. Zero
        // strength or one sample yields the sharp sprite, not a stale exposure.
        let hz = refreshRate.isFinite && refreshRate > 0 ? refreshRate : 60
        let strength = settings.blurStrength.isFinite ? max(0, settings.blurStrength) : 0
        let exposure = min(0.25, strength / hz)
        if exposure > 0 && result.samples > 1 {
            let start = position(at: time - exposure)
            result.displacement = CGPoint(x: snapshot.position.x - start.x,
                                          y: snapshot.position.y - start.y)
        }
        return result
    }

    private func resetMode() {
        springPosition = 0
        springVelocity = 0
        stickEnd = .zero
        stickInitialized = false
        stickRotation = 0
    }

    private func sample(_ offset: Int) -> MotionSample {
        history[(historyStart + offset) % history.count]
    }

    private func record(position: CGPoint, at time: Double) {
        let value = MotionSample(time: time, position: position)
        if historyCount > 0 && time - lastPushTime < 0.001 {
            history[(historyStart + historyCount - 1) % history.count] = value
        } else {
            history[(historyStart + historyCount) % history.count] = value
            if historyCount == history.count {
                historyStart = (historyStart + 1) % history.count
            } else {
                historyCount += 1
            }
            lastPushTime = time
        }
        // Record stationary samples too: advancing the exposure's left edge
        // then shrinks displacement to zero after a stop instead of freezing it.
        while historyCount > 2 && sample(1).time <= time - 1 {
            historyStart = (historyStart + 1) % history.count
            historyCount -= 1
        }
    }

    private func position(at time: Double) -> CGPoint {
        guard historyCount > 0 else { return lastPosition }
        let first = sample(0)
        if time <= first.time { return first.position }
        let last = sample(historyCount - 1)
        if time >= last.time { return last.position }
        var lower = 0
        var upper = historyCount - 1
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if sample(middle).time <= time {
                lower = middle
            } else {
                upper = middle
            }
        }
        let before = sample(lower)
        let after = sample(upper)
        let fraction = (time - before.time) / (after.time - before.time)
        return CGPoint(x: before.position.x + (after.position.x - before.position.x) * fraction,
                       y: before.position.y + (after.position.y - before.position.y) * fraction)
    }

    private func advanceSpring(toward target: Double, mass: Double, dt: Double) {
        guard dt > 0 else { return }
        // Closed-form underdamped oscillator from the MIT fork's Spring.cpp.
        // Exact for a fixed target over dt; no frame-rate-dependent Euler steps.
        let omega = sqrt(300 / max(mass, 0.001))
        let damping = 0.65
        let dampedOmega = omega * sqrt(1 - damping * damping)
        let decay = exp(-damping * omega * dt)
        let cosine = cos(dampedOmega * dt)
        let sine = sin(dampedOmega * dt)
        let displacement = springPosition - target
        let nextDisplacement = decay * (displacement * cosine +
            (springVelocity + damping * omega * displacement) / dampedOmega * sine)
        let nextVelocity = decay * (springVelocity * cosine -
            (damping * omega * springVelocity + omega * omega * displacement) / dampedOmega * sine)
        springPosition = target + nextDisplacement
        springVelocity = nextVelocity
        if abs(springPosition - target) < 0.0001 && abs(springVelocity) < 0.0001 {
            springPosition = target
            springVelocity = 0
        }
    }

    private func rotate(at position: CGPoint) -> Double {
        if !stickInitialized {
            stickEnd = CGPoint(x: position.x, y: position.y - 20)
            stickInitialized = true
        }
        let x = Double(stickEnd.x - position.x)
        let y = Double(stickEnd.y - position.y)
        let length = hypot(x, y)
        if length > 0.000_001 {
            stickEnd = CGPoint(x: position.x + x / length * 20,
                               y: position.y + y / length * 20)
            // Tail is below the hotspot at rest. Convert bottom-up y to screen
            // y, then measure clockwise rotation of that downward tail.
            stickRotation = atan2(-x, -y)
        } else {
            // A move landing exactly on the tail has no direction; preserve the
            // previous orientation instead of dividing by zero or flipping it.
            stickEnd = CGPoint(x: position.x - sin(stickRotation) * 20,
                               y: position.y - cos(stickRotation) * 20)
        }
        return stickRotation
    }

    private func resetShake() {
        shakeStarted = false
        shakeExpiresAt = 0
        shakeScale = 1
        shakeGoal = 1
        shakeFrom = 1
        shakeAnimationStartedAt = 0
    }

    private func updateShake(at time: Double, dt: Double) -> Double {
        let progress = min(1, max(0, (time - shakeAnimationStartedAt) / 0.4))
        shakeScale = shakeFrom + (shakeGoal - shakeFrom) * shakeEasing(progress)
        let cutoff = time - 1
        var previous = position(at: cutoff)
        var left = previous.x
        var right = previous.x
        var bottom = previous.y
        var top = previous.y
        var distance: Double = 0
        for index in 0..<historyCount {
            let entry = sample(index)
            if entry.time <= cutoff { continue }
            let point = entry.position
            distance += hypot(Double(point.x - previous.x), Double(point.y - previous.y))
            left = min(left, point.x)
            right = max(right, point.x)
            bottom = min(bottom, point.y)
            top = max(top, point.y)
            previous = point
        }
        let diagonal = hypot(Double(right - left), Double(top - bottom))
        var nextGoal = shakeGoal
        // Upstream's one-second path/bounds detector: at least 100 points of
        // travel across the bounds, with six times as much back-and-forth path.
        if diagonal > 100 && distance / diagonal > 6 {
            if !shakeStarted { nextGoal = 4 }
            nextGoal += 4 * dt
            shakeStarted = true
            shakeExpiresAt = time + 2
        } else if shakeStarted && time >= shakeExpiresAt {
            nextGoal = 1
            shakeStarted = false
        }
        if nextGoal != shakeGoal {
            shakeFrom = shakeScale
            shakeGoal = nextGoal
            shakeAnimationStartedAt = time
        }
        return shakeScale
    }

    private func shakeEasing(_ progress: Double) -> Double {
        // Upstream's 400 ms cubic Bezier: (0.22, 1), (0.36, 1).
        if progress <= 0 { return 0 }
        if progress >= 1 { return 1 }
        var lower: Double = 0
        var upper: Double = 1
        for _ in 0..<16 {
            let t = (lower + upper) * 0.5
            let inverse = 1 - t
            let x = 3 * inverse * inverse * t * 0.22 + 3 * inverse * t * t * 0.36 + t * t * t
            if x < progress { lower = t } else { upper = t }
        }
        let inverse = 1 - (lower + upper) * 0.5
        return 1 - inverse * inverse * inverse
    }
}
