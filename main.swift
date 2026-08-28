import AppKit

let workDuration: TimeInterval = 25 * 60
let breakDuration: TimeInterval = 5 * 60
let sideButtonMask = 1 << 3 | 1 << 4
let tintThickness: CGFloat = 140
let tintAlpha: CGFloat = 0.22
let idleAlpha: CGFloat = 0.15
let hoverAlpha: CGFloat = 0.9
let fadeDuration: TimeInterval = 0.2
let hitSlop: CGFloat = 24
let tapThreshold: CGFloat = 4
let originKey = "digitsOrigin"

enum Phase {
    case work, rest

    var duration: TimeInterval { self == .work ? workDuration : breakDuration }
    var tint: NSColor { self == .work ? .systemRed : .systemGreen }
    var next: Phase { self == .work ? .rest : .work }
}

let tintEdges: [(start: CGPoint, end: CGPoint, side: CGRectEdge)] = [
    (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1), .maxYEdge),
    (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0), .minYEdge),
    (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5), .minXEdge),
    (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5), .maxXEdge),
]

// AppKit requires an NSObject subclass as the app delegate; all state lives here.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var digits: NSTextField!
    var tintLayers: [CAGradientLayer] = []
    var startPauseItem: NSMenuItem!
    var statusItem: NSStatusItem!
    let chime = NSSound(named: "Glass")

    var phase = Phase.work
    var endDate: Date?
    var pausedRemaining: TimeInterval?
    var drag: (grab: CGPoint, start: CGPoint)?
    var grabWasHeld = false
    var lastSecond = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 1. Full-screen transparent window, click-through except while cmd is held over the digits
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
        for edge in tintEdges {
            let gradient = CAGradientLayer()
            gradient.startPoint = edge.start
            gradient.endPoint = edge.end
            gradient.opacity = 0
            window.contentView!.layer!.addSublayer(gradient)
            tintLayers.append(gradient)
        }
        layoutTint()

        // 3. The digits: faint, opaque under the cursor, movable by cmd-click or side-button drag
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
        if let saved = UserDefaults.standard.string(forKey: originKey) {
            origin = NSPointFromString(saved)
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
        menu.addItem(NSMenuItem(title: "Cmd-click the digits: tap to start/pause, hold to drag", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Pomo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem.menu = menu

        // 5. One ticker drives dragging, the hover fade, and the countdown. Button and
        // modifier state are polled because the window normally receives no events
        let ticker = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let mouse = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let overDigits = digits.frame.insetBy(dx: -hitSlop, dy: -hitSlop).contains(mouse)
            let cmdHeld = NSEvent.modifierFlags.contains(.command)
            // Cmd over the digits makes the window catch the click so it can't reach the app behind
            let clickThrough = drag == nil && !(cmdHeld && overDigits)
            if window.ignoresMouseEvents != clickThrough {
                window.ignoresMouseEvents = clickThrough
            }
            let mask = NSEvent.pressedMouseButtons
            let grabHeld = mask & sideButtonMask != 0 || (mask & 1 != 0 && cmdHeld)
            if grabHeld, !grabWasHeld, overDigits {
                drag = (CGPoint(x: mouse.x - digits.frame.origin.x,
                                y: mouse.y - digits.frame.origin.y), mouse)
            }
            grabWasHeld = grabHeld
            if let active = drag {
                let origin = clamped(CGPoint(x: mouse.x - active.grab.x, y: mouse.y - active.grab.y))
                if origin != digits.frame.origin {
                    digits.setFrameOrigin(origin)
                }
                if mask & (sideButtonMask | 1) == 0 {
                    drag = nil
                    // A press without movement is a tap and toggles the timer
                    if hypot(mouse.x - active.start.x, mouse.y - active.start.y) < tapThreshold {
                        toggleRun()
                    } else {
                        UserDefaults.standard.set(NSStringFromPoint(digits.frame.origin), forKey: originKey)
                    }
                }
            }
            let target = drag != nil || overDigits ? hoverAlpha : idleAlpha
            if abs(digits.alphaValue - target) > 0.01 {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = fadeDuration
                    self.digits.animator().alphaValue = target
                }
            }
            // Countdown; stays last in the tick because it returns whenever the timer is idle
            guard var end = endDate else { return }
            if end.timeIntervalSinceNow <= 0 {
                phase = phase.next
                end = Date().addingTimeInterval(phase.duration)
                endDate = end
                chime?.play()
                refresh()
            }
            let seconds = Int(max(0, end.timeIntervalSinceNow).rounded(.up))
            if seconds != lastSecond {
                lastSecond = seconds
                digits.stringValue = clock(end.timeIntervalSinceNow)
            }
        }
        ticker.tolerance = 1.0 / 120.0
        RunLoop.main.add(ticker, forMode: .common)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let screen = NSScreen.screens.first else { return }
            window.setFrame(screen.frame, display: true)
            layoutTint()
            digits.setFrameOrigin(clamped(digits.frame.origin))
        }

        window.orderFrontRegardless()
    }

    @objc func toggleRun() {
        if let end = endDate {
            pausedRemaining = max(0, end.timeIntervalSinceNow)
            endDate = nil
        } else {
            endDate = Date().addingTimeInterval(pausedRemaining ?? phase.duration)
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
        let colors = [phase.tint.withAlphaComponent(0).cgColor, phase.tint.withAlphaComponent(tintAlpha).cgColor]
        for layer in tintLayers {
            layer.colors = colors
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
        for (layer, edge) in zip(tintLayers, tintEdges) {
            layer.frame = bounds.divided(atDistance: tintThickness, from: edge.side).slice
        }
        CATransaction.commit()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
