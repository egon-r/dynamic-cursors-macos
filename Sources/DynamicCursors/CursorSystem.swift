import AppKit
import Darwin
import QuartzCore

/// Main-thread-only access to the WindowServer cursor. This owns at most one
/// hide count; the cursor's logical hotspot and the event position are unchanged.
final class CursorSystem {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFBoolean) -> Int32
    private typealias CursorIsVisible = @convention(c) () -> UInt32

    enum Failure: LocalizedError {
        case mainThreadRequired
        case loadingSymbols(String)
        case missingSymbol(String, String)
        case windowServer(String, Int32, String)

        var errorDescription: String? {
            switch self {
            case .mainThreadRequired:
                return "CursorSystem must be created and used on the main thread."
            case .loadingSymbols(let detail):
                return "Could not open the process's graphics symbols: \(detail)"
            case .missingSymbol(let name, let detail):
                return "This macOS release does not provide the required cursor API \(name): \(detail)"
            case .windowServer(let operation, let code, let detail):
                return "\(operation) failed (WindowServer error \(code)).\(detail)"
            }
        }
    }

    private struct CachedCursor {
        let image: CGImage
        let pixels: Data
        let size: CGSize
        let hotspot: CGPoint
    }

    private let symbolHandle: UnsafeMutableRawPointer
    private let setConnectionProperty: SetConnectionProperty
    private let queryVisibility: CursorIsVisible?
    private let connection: Int32
    private let backgroundKey = "SetsCursorInBackground" as CFString
    private var backgroundPropertyNeedsReset = false
    private var hiddenDisplay: CGDirectDisplayID?
    private var cachedCursor: CachedCursor?
    private var lastTIFF: Data?
    private var lastBackingScale: CGFloat = 0
    private var lastSampleTime: CFTimeInterval = -.infinity
    private var revision: UInt64 = 0

    var isReplacing: Bool { hiddenDisplay != nil }

    /// Diagnostic only: our own hide count makes this false too, so it cannot
    /// reveal whether the foreground app also intends to hide its cursor.
    var systemCursorVisible: Bool? { queryVisibility.map { $0() != 0 } }

    init() throws {
        guard Thread.isMainThread else { throw Failure.mainThreadRequired }
        guard let handle = dlopen(nil, RTLD_LAZY) else {
            throw Failure.loadingSymbols(Self.linkerError())
        }
        do {
            let main: MainConnection = try Self.resolve("CGSMainConnectionID", in: handle)
            let setProperty: SetConnectionProperty = try Self.resolve("CGSSetConnectionProperty", in: handle)
            self.symbolHandle = handle
            self.setConnectionProperty = setProperty
            self.connection = main()
            if let symbol = dlsym(handle, "CGCursorIsVisible") {
                self.queryVisibility = unsafeBitCast(symbol, to: CursorIsVisible.self)
            } else {
                self.queryVisibility = nil
            }
        } catch {
            dlclose(handle)
            throw error
        }
    }

    deinit {
        endReplacement()
        dlclose(symbolHandle)
    }

    func beginReplacement() throws {
        guard Thread.isMainThread else { throw Failure.mainThreadRequired }
        if isReplacing {
            guard systemCursorVisible == true else { return }
            // Another visibility change can reveal the native cursor despite
            // our ownership flag. Balance our old hide before reacquiring it;
            // blindly hiding again would accumulate counts across recoveries.
            endReplacement()
            guard !isReplacing else {
                throw Failure.windowServer("Rebalancing cursor visibility", CGError.failure.rawValue,
                                          " The existing hide count could not be released.")
            }
        }

        // Set this before calling: even a failed private API request is followed
        // by a best-effort rollback rather than leaving background access set.
        backgroundPropertyNeedsReset = true
        let propertyResult = setBackgroundAccess(true)
        guard propertyResult == 0 else {
            let rollback = resetBackgroundAccess()
            throw Failure.windowServer("Enabling background cursor replacement", propertyResult, rollback)
        }

        let display = CGMainDisplayID()
        let hideResult = CGDisplayHideCursor(display)
        guard hideResult == .success else {
            let rollback = resetBackgroundAccess()
            throw Failure.windowServer("Hiding the system cursor", hideResult.rawValue, rollback)
        }
        hiddenDisplay = display
    }

    func endReplacement() {
        if let display = hiddenDisplay {
            // If an earlier show failed, background access may already have been
            // reset. Re-enable it for the retry without acquiring another hide.
            if !backgroundPropertyNeedsReset {
                backgroundPropertyNeedsReset = true
                let result = setBackgroundAccess(true)
                if result != 0 {
                    cursorLog("Could not re-enable background cursor access for restoration (\(result)).")
                }
            }
            let result = CGDisplayShowCursor(display)
            if result == .success {
                hiddenDisplay = nil
            } else {
                // Retain ownership so a subsequent end/deinit can retry. Never
                // call show again once our single hide has been balanced.
                cursorLog("Could not restore the system cursor (\(result.rawValue)); the hide count is still owned.")
            }
        }
        let rollback = resetBackgroundAccess()
        if !rollback.isEmpty { cursorLog(rollback) }
    }

    func snapshot() -> CursorSnapshot? {
        guard Thread.isMainThread else { return nil }
        let position = NSEvent.mouseLocation
        let now = CACurrentMediaTime()
        if now - lastSampleTime >= 1.0 / 30.0 {
            lastSampleTime = now
            autoreleasepool { sampleImage(at: position) }
        }
        guard let cached = cachedCursor else { return nil }
        return CursorSnapshot(image: cached.image, size: cached.size,
                              hotspot: cached.hotspot, position: position, revision: revision)
    }

    private func sampleImage(at position: CGPoint) {
        // currentSystem, unlike current, observes the foreground application's
        // cursor. It remains available on the targeted release while we hide it.
        guard let cursor = NSCursor.currentSystem else {
            invalidateImage()
            return
        }
        let image = cursor.image
        let size = image.size
        let hotspot = cursor.hotSpot
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              hotspot.x.isFinite, hotspot.y.isFinite else {
            invalidateImage()
            return
        }
        let scale = cursorScreen(containing: position)?.backingScaleFactor ?? 1
        let tiff = image.tiffRepresentation
        if let cached = cachedCursor, let tiff,
           tiff == lastTIFF, scale == lastBackingScale, cached.size == size {
            if cached.hotspot != hotspot {
                revision &+= 1
                cachedCursor = CachedCursor(image: cached.image, pixels: cached.pixels,
                                            size: size, hotspot: hotspot)
            }
            return
        }
        guard let rendered = rasterize(image, size: size, scale: scale) else {
            invalidateImage()
            return
        }
        lastTIFF = tiff
        lastBackingScale = scale
        if let cached = cachedCursor,
           cached.size == size, cached.hotspot == hotspot,
           cached.image.width == rendered.image.width,
           cached.image.height == rendered.image.height,
           cached.pixels == rendered.pixels {
            return
        }
        revision &+= 1
        cachedCursor = CachedCursor(image: rendered.image, pixels: rendered.pixels,
                                    size: size, hotspot: hotspot)
    }

    private func rasterize(_ image: NSImage, size: CGSize, scale: CGFloat) -> (image: CGImage, pixels: Data)? {
        let width = ceil(size.width * scale)
        let height = ceil(size.height * scale)
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width < CGFloat(Int.max / 4), height < CGFloat(Int.max) else { return nil }
        let pixelsWide = Int(width)
        let pixelsHigh = Int(height)
        let bytesPerRow = pixelsWide * 4
        let (byteCount, overflow) = bytesPerRow.multipliedReportingOverflow(by: pixelsHigh)
        guard !overflow,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                          CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        context.scaleBy(x: width / size.width, y: height / size.height)
        context.interpolationQuality = .high
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        var rect = CGRect(origin: .zero, size: size)
        // The scaled reference context selects Retina representations when
        // available. CGImage-to-CGImage drawing preserves the source orientation;
        // no AppKit flipped-view transform or vertical texture flip is applied.
        guard let source = image.cgImage(forProposedRect: &rect, context: graphics, hints: nil) else { return nil }
        context.draw(source, in: CGRect(origin: .zero, size: size))
        guard let result = context.makeImage(), let data = context.data else { return nil }
        return (result, Data(bytes: data, count: byteCount))
    }

    private func invalidateImage() {
        cachedCursor = nil
        lastTIFF = nil
        lastBackingScale = 0
    }

    private func setBackgroundAccess(_ enabled: Bool) -> Int32 {
        setConnectionProperty(connection, connection, backgroundKey,
                              enabled ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Empty on success; failure retains state so end/deinit can retry.
    @discardableResult
    private func resetBackgroundAccess() -> String {
        guard backgroundPropertyNeedsReset else { return "" }
        let result = setBackgroundAccess(false)
        guard result == 0 else {
            return " Could not reset SetsCursorInBackground (WindowServer error \(result))."
        }
        backgroundPropertyNeedsReset = false
        return ""
    }

    private static func resolve<T>(_ name: String, in handle: UnsafeMutableRawPointer) throws -> T {
        guard let symbol = dlsym(handle, name) else {
            throw Failure.missingSymbol(name, linkerError())
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static func linkerError() -> String {
        dlerror().map { String(cString: $0) } ?? "No dynamic linker diagnostic was provided."
    }
}
