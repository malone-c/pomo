import AppKit

var workDuration: TimeInterval = 25 * 60
var breakDuration: TimeInterval = 5 * 60
let sideButtonMask = 1 << 3 | 1 << 4
let hoverAlpha: CGFloat = 0.9
let fadeDuration: TimeInterval = 0.2
let hitSlop: CGFloat = 24
let tapThreshold: CGFloat = 4
let originKey = "digitsOrigin"

enum Phase {
    case work, rest

    var duration: TimeInterval { self == .work ? workDuration : breakDuration }
    var next: Phase { self == .work ? .rest : .work }
}

let tintPalette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemTeal, .systemBlue, .systemPurple]

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
    var autoStartItem: NSMenuItem!
    var statusItem: NSStatusItem!
    var sizeSlider: NSSlider!
    let chime = NSSound(named: "Glass")

    var phase = Phase.work
    var endDate: Date?
    var pausedRemaining: TimeInterval?
    var drag: (grab: CGPoint, start: CGPoint)?
    var grabWasHeld = false
    var lastSecond = -1
    var previewUntil: Date?

    var tintColor = NSColor.systemRed
    var tintAlpha: CGFloat = 0.22
    var tintWidth: CGFloat = 140
    var digitsSize: CGFloat = 100
    var digitsFontName: String?
    var digitsIdleAlpha: CGFloat = 0.15
    var autoContinue = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 1. Saved appearance settings
        let defaults = UserDefaults.standard
        if let v = defaults.object(forKey: "tintAlpha") as? Double { tintAlpha = CGFloat(v) }
        if let v = defaults.object(forKey: "tintWidth") as? Double { tintWidth = CGFloat(v) }
        if let v = defaults.object(forKey: "digitsSize") as? Double { digitsSize = CGFloat(v) }
        if let v = defaults.object(forKey: "digitsAlpha") as? Double { digitsIdleAlpha = CGFloat(v) }
        digitsFontName = defaults.string(forKey: "digitsFont")
        if let v = defaults.object(forKey: "autoContinue") as? Bool { autoContinue = v }
        if let v = defaults.object(forKey: "workDuration") as? Double { workDuration = v }
        if let v = defaults.object(forKey: "breakDuration") as? Double { breakDuration = v }
        if let data = defaults.data(forKey: "tintColor"),
           let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            tintColor = color
        }

        // 2. Full-screen transparent window, click-through except while cmd is held over the digits
        let screen = NSScreen.screens.first!
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView!.wantsLayer = true

        // 3. Edge tint: one gradient per screen edge, fading toward the center
        for edge in tintEdges {
            let gradient = CAGradientLayer()
            gradient.startPoint = edge.start
            gradient.endPoint = edge.end
            gradient.opacity = 0
            window.contentView!.layer!.addSublayer(gradient)
            tintLayers.append(gradient)
        }
        layoutTint()

        // 4. The digits: faint, opaque under the cursor, movable by cmd-click or side-button drag
        digits = NSTextField(labelWithString: clock(workDuration))
        digits.textColor = .white
        digits.alignment = .center
        digits.wantsLayer = true
        digits.alphaValue = digitsIdleAlpha
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
        shadow.shadowBlurRadius = 5
        digits.shadow = shadow
        applyDigitsFont()
        var origin = CGPoint(x: (screen.frame.width - digits.frame.width) / 2,
                             y: (screen.frame.height - digits.frame.height) / 2)
        if let saved = UserDefaults.standard.string(forKey: originKey) {
            origin = NSPointFromString(saved)
        }
        digits.setFrameOrigin(clamped(origin))
        window.contentView!.addSubview(digits)

        // 5. Menu bar item, the only clickable control surface
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🍅"
        let menu = NSMenu()
        startPauseItem = NSMenuItem(title: "Start", action: #selector(toggleRun), keyEquivalent: "")
        startPauseItem.target = self
        menu.addItem(startPauseItem)
        let resetItem = NSMenuItem(title: "Reset", action: #selector(reset), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)
        autoStartItem = NSMenuItem(title: "Auto-start next interval", action: #selector(toggleAutoContinue), keyEquivalent: "")
        autoStartItem.target = self
        autoStartItem.state = autoContinue ? .on : .off
        menu.addItem(autoStartItem)
        menu.addItem(.separator())

        menu.addItem(minutesItem("Work", value: Int(workDuration) / 60, max: 180, action: #selector(workLengthChanged)))
        menu.addItem(minutesItem("Break", value: Int(breakDuration) / 60, max: 60, action: #selector(breakLengthChanged)))
        menu.addItem(.separator())

        menu.addItem(sliderItem("Border opacity", min: 0.05, max: 1, value: Double(tintAlpha), action: #selector(tintAlphaChanged)).0)
        menu.addItem(sliderItem("Border width", min: 20, max: 400, value: Double(tintWidth), action: #selector(tintWidthChanged)).0)

        let colourRow = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 42))
        colourRow.autoresizingMask = [.width]
        let colourTitle = NSTextField(labelWithString: "Border colour")
        colourTitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        colourTitle.textColor = .secondaryLabelColor
        colourTitle.frame = NSRect(x: 25, y: 26, width: 180, height: 14)
        colourRow.addSubview(colourTitle)
        for (index, color) in tintPalette.enumerated() {
            let swatch = NSButton(title: "", target: self, action: #selector(swatchPicked))
            swatch.isBordered = false
            swatch.wantsLayer = true
            swatch.layer?.backgroundColor = color.cgColor
            swatch.layer?.cornerRadius = 9
            swatch.layer?.borderWidth = 1
            swatch.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
            swatch.frame = NSRect(x: 25 + index * 25, y: 4, width: 18, height: 18)
            swatch.tag = index
            colourRow.addSubview(swatch)
        }
        let customSwatch = NSButton(title: "…", target: self, action: #selector(pickTintColor))
        customSwatch.isBordered = false
        customSwatch.frame = NSRect(x: 25 + tintPalette.count * 25, y: 3, width: 24, height: 20)
        colourRow.addSubview(customSwatch)
        let colourItem = NSMenuItem()
        colourItem.view = colourRow
        menu.addItem(colourItem)
        menu.addItem(.separator())

        let (sizeItem, sizeControl) = sliderItem("Timer size", min: 40, max: 300, value: Double(digitsSize), action: #selector(digitsSizeChanged))
        sizeSlider = sizeControl
        menu.addItem(sizeItem)
        menu.addItem(sliderItem("Timer opacity", min: 0.02, max: 0.9, value: Double(digitsIdleAlpha), action: #selector(digitsAlphaChanged)).0)
        let fontItem = NSMenuItem(title: "Timer font…", action: #selector(pickFont), keyEquivalent: "")
        fontItem.target = self
        menu.addItem(fontItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Cmd-drag digits to move", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Pomo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem.menu = menu

        // 6. One ticker drives dragging, the hover fade, and the countdown. Button and
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
            let target = drag != nil || overDigits ? hoverAlpha : digitsIdleAlpha
            if abs(digits.alphaValue - target) > 0.01 {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = fadeDuration
                    self.digits.animator().alphaValue = target
                }
            }
            if let preview = previewUntil, preview.timeIntervalSinceNow <= 0 {
                previewUntil = nil
                refresh()
            }
            // Countdown; stays last in the tick because it returns whenever the timer is idle
            guard var end = endDate else { return }
            if end.timeIntervalSinceNow <= 0 {
                phase = phase.next
                chime?.play()
                if autoContinue {
                    end = Date().addingTimeInterval(phase.duration)
                    endDate = end
                    refresh()
                } else {
                    endDate = nil
                    digits.stringValue = clock(phase.duration)
                    refresh()
                    return
                }
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

    @objc func tintAlphaChanged(_ sender: NSSlider) {
        tintAlpha = CGFloat(sender.doubleValue)
        saveSettings()
        previewTint()
    }

    @objc func tintWidthChanged(_ sender: NSSlider) {
        tintWidth = CGFloat(sender.doubleValue)
        layoutTint()
        saveSettings()
        previewTint()
    }

    @objc func workLengthChanged(_ sender: NSTextField) {
        workDuration = TimeInterval(min(180, max(1, sender.integerValue))) * 60
        sender.integerValue = Int(workDuration) / 60
        durationsChanged()
    }

    @objc func breakLengthChanged(_ sender: NSTextField) {
        breakDuration = TimeInterval(min(60, max(1, sender.integerValue))) * 60
        sender.integerValue = Int(breakDuration) / 60
        durationsChanged()
    }

    func durationsChanged() {
        saveSettings()
        if endDate == nil, pausedRemaining == nil {
            digits.stringValue = clock(phase.duration)
        }
    }

    @objc func toggleAutoContinue() {
        autoContinue.toggle()
        autoStartItem.state = autoContinue ? .on : .off
        saveSettings()
    }

    @objc func swatchPicked(_ sender: NSButton) {
        tintColor = tintPalette[sender.tag]
        saveSettings()
        previewTint()
    }

    @objc func pickTintColor() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(tintColorChanged))
        panel.color = tintColor
        panel.showsAlpha = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func tintColorChanged(_ sender: NSColorPanel) {
        tintColor = sender.color
        saveSettings()
        previewTint()
    }

    @objc func digitsSizeChanged(_ sender: NSSlider) {
        digitsSize = CGFloat(sender.doubleValue)
        applyDigitsFont()
        saveSettings()
    }

    @objc func digitsAlphaChanged(_ sender: NSSlider) {
        digitsIdleAlpha = CGFloat(sender.doubleValue)
        saveSettings()
    }

    @objc func pickFont() {
        let manager = NSFontManager.shared
        manager.target = self
        if let font = digits.font {
            manager.setSelectedFont(font, isMultiple: false)
        }
        NSFontPanel.shared.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        manager.orderFrontFontPanel(nil)
    }

    @objc func changeFont(_ sender: Any?) {
        guard let manager = sender as? NSFontManager, let current = digits.font else { return }
        let converted = manager.convert(current)
        digitsFontName = converted.fontName
        digitsSize = converted.pointSize
        sizeSlider.doubleValue = Double(digitsSize)
        applyDigitsFont()
        saveSettings()
    }

    func sliderItem(_ label: String, min: Double, max: Double, value: Double, action: Selector) -> (NSMenuItem, NSSlider) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 42))
        container.autoresizingMask = [.width]
        let title = NSTextField(labelWithString: label)
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 25, y: 24, width: 180, height: 14)
        container.addSubview(title)
        let slider = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: action)
        slider.isContinuous = true
        slider.frame = NSRect(x: 23, y: 2, width: 211, height: 20)
        slider.autoresizingMask = [.width]
        container.addSubview(slider)
        let item = NSMenuItem()
        item.view = container
        return (item, slider)
    }

    func minutesItem(_ label: String, value: Int, max maxMinutes: Int, action: Selector) -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 30))
        container.autoresizingMask = [.width]
        let title = NSTextField(labelWithString: label)
        title.font = .menuFont(ofSize: 0)
        title.frame = NSRect(x: 25, y: 6, width: 120, height: 18)
        container.addSubview(title)
        let suffix = NSTextField(labelWithString: "min")
        suffix.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        suffix.textColor = .secondaryLabelColor
        suffix.frame = NSRect(x: 208, y: 8, width: 26, height: 16)
        suffix.autoresizingMask = [.minXMargin]
        container.addSubview(suffix)
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 1
        formatter.maximum = NSNumber(value: maxMinutes)
        let field = NSTextField(string: "\(value)")
        field.formatter = formatter
        field.alignment = .right
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.frame = NSRect(x: 156, y: 5, width: 48, height: 19)
        field.autoresizingMask = [.minXMargin]
        field.target = self
        field.action = action
        field.cell?.sendsActionOnEndEditing = true
        container.addSubview(field)
        let item = NSMenuItem()
        item.view = container
        return item
    }

    func applyDigitsFont() {
        let center = CGPoint(x: digits.frame.midX, y: digits.frame.midY)
        let font = digitsFontName.flatMap { NSFont(name: $0, size: digitsSize) }
            ?? .monospacedDigitSystemFont(ofSize: digitsSize, weight: .thin)
        digits.font = font
        // Sized for the widest possible time so later text never clips
        let sample = ("88:88" as NSString).size(withAttributes: [.font: font])
        digits.setFrameSize(NSSize(width: ceil(sample.width) + 10, height: ceil(sample.height) + 4))
        digits.setFrameOrigin(clamped(CGPoint(x: center.x - digits.frame.width / 2,
                                              y: center.y - digits.frame.height / 2)))
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(Double(tintAlpha), forKey: "tintAlpha")
        defaults.set(Double(tintWidth), forKey: "tintWidth")
        defaults.set(try? NSKeyedArchiver.archivedData(withRootObject: tintColor, requiringSecureCoding: true), forKey: "tintColor")
        defaults.set(Double(digitsSize), forKey: "digitsSize")
        defaults.set(digitsFontName, forKey: "digitsFont")
        defaults.set(Double(digitsIdleAlpha), forKey: "digitsAlpha")
        defaults.set(autoContinue, forKey: "autoContinue")
        defaults.set(workDuration, forKey: "workDuration")
        defaults.set(breakDuration, forKey: "breakDuration")
    }

    func previewTint() {
        if endDate == nil {
            previewUntil = Date().addingTimeInterval(2)
        }
        refresh()
    }

    func refresh() {
        let tint = phase == .work ? tintColor : NSColor.systemGreen
        let colors = [tint.withAlphaComponent(0).cgColor, tint.withAlphaComponent(tintAlpha).cgColor]
        let visible = endDate != nil || previewUntil != nil
        for layer in tintLayers {
            layer.colors = colors
            layer.opacity = visible ? 1 : 0
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
            layer.frame = bounds.divided(atDistance: tintWidth, from: edge.side).slice
        }
        CATransaction.commit()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
