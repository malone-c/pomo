import AppKit

let workDuration: TimeInterval = 25 * 60
let breakDuration: TimeInterval = 5 * 60
let sideButtons = [3, 4]
let sideButtonMask = sideButtons.reduce(0) { $0 | (1 << $1) }
let tintThickness: CGFloat = 140
let idleAlpha: CGFloat = 0.15
let hoverAlpha: CGFloat = 0.9
let originKey = "digitsOrigin"

enum Phase { case work, rest }

// AppKit requires an NSObject subclass as the app delegate; all state lives here.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var digits: NSTextField!
    var tintLayers: [CAGradientLayer] = []
    var startPauseItem: NSMenuItem!
    var statusItem: NSStatusItem!

    var phase = Phase.work
    var endDate: Date?
    var pausedRemaining: TimeInterval?
    var dragGrab: CGPoint?
    var dragStart = CGPoint.zero
    var sideWasHeld = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 1. Full-screen transparent window that never receives mouse clicks
        let screen = NSScreen.screens.first!
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView!.wantsLayer = true

        // 2. Edge tint: one gradient per screen edge, fading toward the center
        let towardEdge: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)),
            (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
            (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5)),
            (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)),
        ]
        for (start, end) in towardEdge {
            let gradient = CAGradientLayer()
            gradient.startPoint = start
            gradient.endPoint = end
            gradient.opacity = 0
            window.contentView!.layer!.addSublayer(gradient)
            tintLayers.append(gradient)
        }
        layoutTint()

        // 3. The digits: faint, opaque under the cursor, draggable with a side button
        digits = NSTextField(labelWithString: clock(workDuration))
        digits.font = .monospacedDigitSystemFont(ofSize: 100, weight: .thin)
        digits.textColor = .white
        digits.alignment = .center
        digits.wantsLayer = true
        digits.alphaValue = idleAlpha
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 5
        digits.shadow = shadow
        digits.sizeToFit()
        var origin = CGPoint(x: (screen.frame.width - digits.frame.width) / 2,
                             y: (screen.frame.height - digits.frame.height) / 2)
        if let saved = UserDefaults.standard.array(forKey: originKey) as? [Double], saved.count == 2 {
            origin = CGPoint(x: saved[0], y: saved[1])
        }
        digits.setFrameOrigin(clamped(origin))
        window.contentView!.addSubview(digits)

        // 4. Menu bar item, the only clickable control surface
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🍅"
        let menu = NSMenu()
        startPauseItem = NSMenuItem(title: "Start", action: #selector(toggleRun), keyEquivalent: "")
        startPauseItem.target = self
        menu.addItem(startPauseItem)
        let resetItem = NSMenuItem(title: "Reset", action: #selector(reset), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Side mouse button: tap digits to start/pause, hold to drag", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Pomo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem.menu = menu

        // 5. One ticker drives the side-button drag, the hover fade, and the countdown.
        // Button state is polled rather than event-monitored: global event monitors are
        // TCC-gated, and NSEvent.pressedMouseButtons needs no permissions
        let ticker = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let mouse = self.window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let sideHeld = NSEvent.pressedMouseButtons & sideButtonMask != 0
            if sideHeld, !self.sideWasHeld, self.digits.frame.insetBy(dx: -24, dy: -24).contains(mouse) {
                self.dragGrab = CGPoint(x: mouse.x - self.digits.frame.origin.x,
                                        y: mouse.y - self.digits.frame.origin.y)
                self.dragStart = mouse
                NSLog("pomo: side button grabbed digits")
            }
            self.sideWasHeld = sideHeld
            if let grab = self.dragGrab {
                self.digits.setFrameOrigin(self.clamped(CGPoint(x: mouse.x - grab.x, y: mouse.y - grab.y)))
                if !sideHeld {
                    self.dragGrab = nil
                    let moved = hypot(mouse.x - self.dragStart.x, mouse.y - self.dragStart.y)
                    NSLog("pomo: side button released, moved %.0fpt", moved)
                    // A press without movement is a tap and toggles the timer
                    if moved < 4 {
                        self.toggleRun()
                    } else {
                        UserDefaults.standard.set([self.digits.frame.origin.x, self.digits.frame.origin.y], forKey: originKey)
                    }
                }
            }
            let hovering = self.dragGrab != nil || self.digits.frame.insetBy(dx: -24, dy: -24).contains(mouse)
            let target = hovering ? hoverAlpha : idleAlpha
            if abs(self.digits.alphaValue - target) > 0.01 {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    self.digits.animator().alphaValue = target
                }
            }
            guard let end = self.endDate else { return }
            if end.timeIntervalSinceNow <= 0 {
                self.phase = self.phase == .work ? .rest : .work
                self.endDate = Date().addingTimeInterval(self.phase == .work ? workDuration : breakDuration)
                NSSound(named: "Glass")?.play()
                self.refresh()
            }
            self.digits.stringValue = self.clock(self.endDate!.timeIntervalSinceNow)
        }
        RunLoop.main.add(ticker, forMode: .common)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let screen = NSScreen.screens.first else { return }
            self.window.setFrame(screen.frame, display: true)
            self.layoutTint()
            self.digits.setFrameOrigin(self.clamped(self.digits.frame.origin))
        }

        window.orderFrontRegardless()
    }

    @objc func toggleRun() {
        if let end = endDate {
            pausedRemaining = max(0, end.timeIntervalSinceNow)
            endDate = nil
        } else {
            endDate = Date().addingTimeInterval(pausedRemaining ?? (phase == .work ? workDuration : breakDuration))
            pausedRemaining = nil
        }
        refresh()
    }

    @objc func reset() {
        endDate = nil
        pausedRemaining = nil
        phase = .work
        digits.stringValue = clock(workDuration)
        refresh()
    }

    func refresh() {
        let color = phase == .work ? NSColor.systemRed : NSColor.systemGreen
        for layer in tintLayers {
            layer.colors = [color.withAlphaComponent(0).cgColor, color.withAlphaComponent(0.22).cgColor]
            layer.opacity = endDate == nil ? 0 : 1
        }
        startPauseItem.title = endDate != nil ? "Pause" : (pausedRemaining != nil ? "Resume" : "Start")
    }

    func clock(_ remaining: TimeInterval) -> String {
        let seconds = max(0, Int(remaining.rounded(.up)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func clamped(_ origin: CGPoint) -> CGPoint {
        let bounds = window.contentView!.bounds
        return CGPoint(x: min(max(0, origin.x), bounds.width - digits.frame.width),
                       y: min(max(0, origin.y), bounds.height - digits.frame.height))
    }

    func layoutTint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = window.contentView!.bounds
        tintLayers[0].frame = CGRect(x: 0, y: bounds.height - tintThickness, width: bounds.width, height: tintThickness)
        tintLayers[1].frame = CGRect(x: 0, y: 0, width: bounds.width, height: tintThickness)
        tintLayers[2].frame = CGRect(x: 0, y: 0, width: tintThickness, height: bounds.height)
        tintLayers[3].frame = CGRect(x: bounds.width - tintThickness, y: 0, width: tintThickness, height: bounds.height)
        CATransaction.commit()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
