import AppKit
import MetalKit
import Darwin

final class OverlayView: MTKView, MTKViewDelegate {
    let cursorRenderer: CursorRenderer
    var cursorFrame: CursorFrame?
    var screenRect: CGRect
    var submittedFrame = false

    init(screen: NSScreen, renderer: CursorRenderer) {
        cursorRenderer = renderer
        screenRect = screen.frame
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size), device: renderer.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        isPaused = true
        enableSetNeedsDisplay = false
        layer?.isOpaque = false
        autoResizeDrawable = true
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isOpaque: Bool { false }
    func draw(in view: MTKView) {
        submittedFrame = cursorRenderer.draw(view: view, frame: cursorFrame, screen: screenRect)
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        submittedFrame = false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var system: CursorSystem!
    private var renderer: CursorRenderer!
    private let physics = CursorPhysics()
    private var settings = CursorSettings()
    private var overlays: [(NSPanel, OverlayView)] = []
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var enabledItem: NSMenuItem!
    private var timer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var observers: [NSObjectProtocol] = []
    private var enabled = true
    private var menuOpen = false
    private var sessionActive = true
    private var lastImageMissing = false
    private var latestSnapshot: CursorSnapshot?
    private var lastDrawnFrame: CursorFrame?
    private var lastDrawnRevision: UInt64?
    private let smoke = CommandLine.arguments.contains("--smoke")
    private let initialForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier
    private var failure: String?
    var exitStatus: Int32 { failure == nil ? 0 : 1 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            system = try CursorSystem()
            renderer = try CursorRenderer()
            buildMenu()
            rebuildOverlays()
            observeLifecycle()
            for number in [SIGINT, SIGTERM] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { NSApp.terminate(nil) }
                source.resume()
                signalSources.append(source)
            }
            let hz = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
            let timer = Timer(timeInterval: 1.0 / Double(max(60, hz)), repeats: true) { [weak self] _ in
                autoreleasepool { self?.tick() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            tick()
            cursorLog("READY Dynamic Cursors: size=\(settings.sizeMultiplier)x mode=tilt inertia=2 blur=2 samples=8 device=\(renderer.device.name) replacing=\(system.isReplacing)")
            if smoke { runSmoke() }
        } catch {
            fail(error)
            NSApp.terminate(nil)
        }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "DC"
        statusItem.button?.toolTip = "Dynamic Cursors — click to pause or configure"
        menu.delegate = self
        enabledItem = add("Enabled", action: #selector(toggleEnabled))
        menu.addItem(.separator())
        for mode in CursorMode.allCases {
            let item = add("Mode: \(mode.rawValue.capitalized)", action: #selector(selectMode(_:)))
            item.representedObject = mode.rawValue
        }
        menu.addItem(.separator())
        for mass in [0.0, 1, 2, 4] {
            let item = add(mass == 0 ? "Tilt inertia: Off" : "Tilt inertia: \(Int(mass))", action: #selector(selectInertia(_:)))
            item.representedObject = mass
        }
        menu.addItem(.separator())
        for strength in [0.0, 1, 2, 4] {
            let item = add(strength == 0 ? "Motion blur: Off" : "Motion blur: \(Int(strength))× exposure", action: #selector(selectBlur(_:)))
            item.representedObject = strength
        }
        menu.addItem(.separator())
        add("Shake to enlarge", action: #selector(toggleShake))
        menu.addItem(.separator())
        add("Quit Dynamic Cursors", action: #selector(quit), key: "q")
        statusItem.menu = menu
        updateMenu()
    }

    @discardableResult
    private func add(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func updateMenu() {
        enabledItem.state = enabled ? .on : .off
        for item in menu.items {
            if item.action == #selector(selectMode(_:)), let raw = item.representedObject as? String {
                item.state = raw == settings.mode.rawValue ? .on : .off
            } else if item.action == #selector(selectInertia(_:)), let mass = item.representedObject as? Double {
                item.state = mass == settings.inertia ? .on : .off
            } else if item.action == #selector(selectBlur(_:)), let strength = item.representedObject as? Double {
                item.state = strength == settings.blurStrength ? .on : .off
            } else if item.action == #selector(toggleShake) {
                item.state = settings.shakeEnabled ? .on : .off
            }
        }
        statusItem.button?.title = failure == nil ? (enabled ? "DC" : "DC ⏸") : "DC !"
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        physics.reset()
        if !enabled { pause() }
        updateMenu()
        cursorLog("enabled=\(enabled) replacing=\(system.isReplacing)")
    }
    @objc private func selectMode(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let mode = CursorMode(rawValue: raw) else { return }
        settings.mode = mode
        physics.reset()
        updateMenu()
        cursorLog("mode=\(mode.rawValue)")
    }
    @objc private func selectInertia(_ item: NSMenuItem) {
        guard let value = item.representedObject as? Double else { return }
        settings.inertia = value
        physics.reset()
        updateMenu()
    }
    @objc private func selectBlur(_ item: NSMenuItem) {
        guard let value = item.representedObject as? Double else { return }
        settings.blurStrength = value
        physics.reset()
        updateMenu()
    }
    @objc private func toggleShake() {
        settings.shakeEnabled.toggle()
        physics.reset()
        updateMenu()
    }
    @objc private func quit() { NSApp.terminate(nil) }

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        pause()
    }
    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        physics.reset()
    }

    private func rebuildOverlays() {
        pause()
        overlays.removeAll()
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = OverlayView(screen: screen, renderer: renderer)
            panel.contentView = view
            overlays.append((panel, view))
        }
        physics.reset()
    }

    private func observeLifecycle() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuildOverlays()
        })
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sessionActive = false
                self?.pause()
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sessionActive = true
                self?.physics.reset()
            })
        }
    }

    private func pause() {
        system?.endReplacement()
        lastDrawnFrame = nil
        lastDrawnRevision = nil
        for (panel, _) in overlays { panel.orderOut(nil) }
    }

    private func tick() {
        guard enabled, !menuOpen, sessionActive, failure == nil else { return }
        guard let snapshot = system.snapshot() else {
            pause()
            physics.reset()
            if !lastImageMissing { cursorLog("System cursor image unavailable; native pointer restored") }
            lastImageMissing = true
            return
        }
        lastImageMissing = false
        do {
            try renderer.updateSprite(snapshot)
            latestSnapshot = snapshot
            let screen = cursorScreen(containing: snapshot.position)
            let hz = Double(screen?.maximumFramesPerSecond ?? 60)
            let frame = physics.frame(snapshot: snapshot, at: ProcessInfo.processInfo.systemUptime, refreshRate: hz, settings: settings)
            if system.isReplacing, frame == lastDrawnFrame, snapshot.revision == lastDrawnRevision {
                try system.beginReplacement()
                return
            }
            var pointerScreenRendered = false
            for (panel, view) in overlays {
                view.cursorFrame = frame
                if !panel.isVisible { panel.orderFrontRegardless() }
                view.submittedFrame = false
                view.draw()
                if view.screenRect == screen?.frame, view.submittedFrame { pointerScreenRendered = true }
            }
            guard pointerScreenRendered else {
                // Keep the transparent windows mapped so Metal can acquire its
                // first drawable; hiding them here would starve initialization.
                system.endReplacement()
                lastDrawnFrame = nil
                lastDrawnRevision = nil
                return
            }
            lastDrawnFrame = frame
            lastDrawnRevision = snapshot.revision
            try system.beginReplacement()
        } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        failure = error.localizedDescription
        pause()
        cursorLog("ERROR \(error.localizedDescription); native cursor restored")
        if statusItem != nil {
            statusItem.button?.toolTip = error.localizedDescription
            updateMenu()
        }
    }

    private func exerciseMenu(action: Selector, value: String? = nil) {
        guard let item = menu.items.first(where: { $0.action == action && (value == nil || ($0.representedObject as? String) == value) }) else {
            fail(NSError(domain: "Smoke", code: 5, userInfo: [NSLocalizedDescriptionKey: "Requested menu action is missing"]))
            return
        }
        menu.performActionForItem(at: menu.index(of: item))
    }

    private func runSmoke() {
        let steps: [(Double, () -> Void)] = [
            (0.3, { self.exerciseMenu(action: #selector(self.selectMode(_:)), value: "rotate") }),
            (0.6, { self.exerciseMenu(action: #selector(self.selectMode(_:)), value: "stretch") }),
            (0.9, { self.exerciseMenu(action: #selector(self.selectMode(_:)), value: "none") }),
            (1.2, { self.exerciseMenu(action: #selector(self.selectMode(_:)), value: "tilt") }),
            (1.5, { self.exerciseMenu(action: #selector(self.toggleEnabled)) }),
            (1.8, { self.exerciseMenu(action: #selector(self.toggleEnabled)) }),
            (2.2, { self.captureSmoke() })
        ]
        for (delay, action) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) }
    }

    private func captureSmoke() {
        do {
            guard let original = latestSnapshot else { throw NSError(domain: "Smoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "No live cursor snapshot"]) }
            let directory = URL(fileURLWithPath: "/tmp/dynamic-cursors-smoke", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let screen = CGRect(x: 0, y: 0, width: 400, height: 200)
            for mode in CursorMode.allCases {
                physics.reset()
                var profile = settings
                profile.mode = mode
                profile.blurStrength = 4
                var frame: CursorFrame!
                for i in 0...20 {
                    let snapshot = CursorSnapshot(image: original.image, size: original.size, hotspot: original.hotspot,
                                                  position: CGPoint(x: 50 + Double(i) * 10, y: 100), revision: original.revision)
                    frame = physics.frame(snapshot: snapshot, at: 10 + Double(i) / 60, refreshRate: 60, settings: profile)
                }
                guard frame.position.x == 250, frame.displacement.x > 0 else {
                    throw NSError(domain: "Smoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "Motion history or pointer-position invariant failed"])
                }
                try renderer.export(frame: frame, screen: screen, to: directory.appendingPathComponent("\(mode.rawValue).png"))
                let stopped = CursorSnapshot(image: original.image, size: original.size, hotspot: original.hotspot, position: frame.position, revision: original.revision)
                let shrinking = physics.frame(snapshot: stopped, at: 10 + 21.0 / 60, refreshRate: 60, settings: profile)
                var expired = shrinking
                for i in 22...30 {
                    expired = physics.frame(snapshot: stopped, at: 10 + Double(i) / 60, refreshRate: 60, settings: profile)
                }
                guard shrinking.displacement.x > 0, shrinking.displacement.x < frame.displacement.x,
                      hypot(expired.displacement.x, expired.displacement.y) < 0.01 else {
                    throw NSError(domain: "Smoke", code: 3, userInfo: [NSLocalizedDescriptionKey: "Blur failed to shrink and expire after stopping"])
                }
                cursorLog("SMOKE mode=\(mode.rawValue) pointerExact=true blurDisplacement=\(frame.displacement.x) shrinkingDisplacement=\(shrinking.displacement.x) idleDisplacement=\(expired.displacement.x) capture=\(directory.path)/\(mode.rawValue).png")
            }
            physics.reset()
            let replacementWorked = system.isReplacing
            pause()
            let foregroundUnchanged = initialForeground == NSWorkspace.shared.frontmostApplication?.processIdentifier
            cursorLog("SMOKE replacementActive=\(replacementWorked) restored=\(!system.isReplacing) foregroundUnchanged=\(foregroundUnchanged) nativeVisible=\(String(describing: system.systemCursorVisible))")
            if !replacementWorked || !foregroundUnchanged { fail(NSError(domain: "Smoke", code: 4, userInfo: [NSLocalizedDescriptionKey: "Live replacement or focus invariant failed"])) }
        } catch { fail(error) }
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        pause()
        cursorLog("STOPPED native cursor restored; status=\(failure == nil ? "OK" : "FAILED")")
        if failure != nil { exit(1) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
exit(delegate.exitStatus)
