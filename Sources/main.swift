import AppKit
import Carbon
import ApplicationServices
import Foundation

// MARK: - Settings

struct Settings: Codable {
    var password: String
    var message: String
    var dimOpacity: Double

    static let `default` = Settings(
        password: "anishisagentic",
        message: "WIP, enter password to unlock",
        dimOpacity: 0.28
    )

    func sanitized() -> Settings {
        var s = self
        if s.password.isEmpty { s.password = Settings.default.password }
        s.message = s.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.message.isEmpty { s.message = Settings.default.message }
        s.dimOpacity = min(0.85, max(0.05, s.dimOpacity))
        return s
    }
}

enum SettingsStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("com.anishfyi.vaulty", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var fileURL: URL { directory.appendingPathComponent("settings.json") }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(Settings.self, from: data)
        else { return .default }
        return s.sanitized()
    }

    static func save(_ settings: Settings) {
        let clean = settings.sanitized()
        if let data = try? JSONEncoder().encode(clean) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Hotkey constants (⌘⇧L)

private let kHotKeyCode: UInt32 = UInt32(kVK_ANSI_L)
private let kHotKeyModifiers: UInt32 = UInt32(cmdKey | shiftKey)

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var lockWindows: [LockWindow] = []
    private var controlPanel: ControlPanelController?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var focusTimer: Timer?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isLocked = false
    private(set) var settings = SettingsStore.load()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        registerHotKey()
        requestAccessibilityIfNeeded()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        print("vaulty: running - ⌘⇧L to lock · Control Panel from menu bar")
    }

    func applicationWillTerminate(_ notification: Notification) {
        unlock(silent: true)
        unregisterHotKey()
        tearDownEventTap()
    }

    func reloadSettings() {
        settings = SettingsStore.load()
    }

    func updateSettings(_ new: Settings) {
        settings = new.sanitized()
        SettingsStore.save(settings)
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        if let button = statusItem.button {
            button.title = isLocked ? "●" : "◐"
            button.toolTip = "Vaulty - ⌘⇧L to lock"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Lock Screen (⌘⇧L)", action: #selector(lock), keyEquivalent: "l"))
        menu.item(at: 0)?.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(NSMenuItem(title: "Control Panel…", action: #selector(openControlPanel), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Vaulty", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = isLocked ? nil : menu
    }

    @objc private func quitApp() {
        if isLocked { return }
        NSApp.terminate(nil)
    }

    @objc func openControlPanel() {
        if isLocked { return }
        if controlPanel == nil {
            controlPanel = ControlPanelController(app: self)
        }
        controlPanel?.show()
    }

    // MARK: Hotkey

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
            guard let userData else { return noErr }
            let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if hotKeyID.id == 1 {
                DispatchQueue.main.async { app.lock() }
            }
            return noErr
        }, 1, &eventType, userData, &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x564C5459), id: 1) // 'VLTY'
        RegisterEventHotKey(kHotKeyCode, kHotKeyModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregisterHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKeyRef = nil
        eventHandler = nil
    }

    // MARK: Lock / Unlock

    @objc func lock() {
        guard !isLocked else { return }
        reloadSettings()
        isLocked = true
        setupStatusItem()
        controlPanel?.hide()

        lockWindows = NSScreen.screens.map { LockWindow(screen: $0, controller: self) }
        for w in lockWindows {
            w.orderFrontRegardless()
            w.makeKey()
        }
        lockWindows.first?.focusPasswordField()
        NSApp.activate(ignoringOtherApps: true)

        startFocusGuard()
        installEventTap()
    }

    /// Displays can be connected, disconnected, or rearranged while locked;
    /// every attached screen must stay covered or it exposes the desktop.
    @objc private func screenConfigurationChanged() {
        guard isLocked else { return }

        var orphans = [CGDirectDisplayID: LockWindow]()
        for w in lockWindows { orphans[w.displayID] = w }

        lockWindows = NSScreen.screens.map { screen in
            if let existing = orphans.removeValue(forKey: LockWindow.displayID(for: screen)) {
                existing.setFrame(screen.frame, display: true)
                return existing
            }
            let w = LockWindow(screen: screen, controller: self)
            w.orderFrontRegardless()
            return w
        }
        for w in orphans.values { w.orderOut(nil) }

        if !lockWindows.contains(where: { $0.isKeyWindow }) {
            let key = lockWindows.first(where: { $0.screen == NSScreen.main }) ?? lockWindows.first
            key?.makeKey()
            key?.focusPasswordField()
        }
    }

    func tryUnlock(with password: String) -> Bool {
        guard password == settings.password else { return false }
        unlock(silent: false)
        return true
    }

    private func unlock(silent: Bool) {
        guard isLocked || !lockWindows.isEmpty else { return }
        isLocked = false
        focusTimer?.invalidate()
        focusTimer = nil
        tearDownEventTap()
        for w in lockWindows { w.orderOut(nil) }
        lockWindows.removeAll()
        setupStatusItem()
        if !silent {
            NSApp.hide(nil)
        }
    }

    private func startFocusGuard() {
        focusTimer?.invalidate()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isLocked else { return }
            NSApp.activate(ignoringOtherApps: true)
            if let key = self.lockWindows.first(where: { $0.screen == NSScreen.main }) ?? self.lockWindows.first {
                if !key.isKeyWindow {
                    key.orderFrontRegardless()
                    key.makeKey()
                    key.focusPasswordField()
                }
            }
        }
    }

    // MARK: Event tap

    private func requestAccessibilityIfNeeded() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func installEventTap() {
        tearDownEventTap()
        let mask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let app = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return app.handleTap(type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            print("vaulty: grant Accessibility for full shortcut blocking")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func tearDownEventTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard isLocked else { return Unmanaged.passUnretained(event) }

        if type == .keyDown || type == .keyUp {
            let flags = event.flags
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            let cmd = flags.contains(.maskCommand)
            let ctrl = flags.contains(.maskControl)
            let opt = flags.contains(.maskAlternate)

            if cmd && (keycode == 48 || keycode == 50 || keycode == 49
                || keycode == 12 || keycode == 13 || keycode == 4) {
                return nil
            }
            if ctrl && (keycode == 126 || keycode == 125) { return nil }
            if cmd && opt && keycode == 53 { return nil }
            if keycode == 53 { return nil }
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            // CGEvent locations are top-left-origin; window frames are
            // bottom-left-origin Cocoa coordinates. Flip about the primary
            // display height or the test is wrong on external displays.
            let loc = event.location
            let cocoaPoint = NSPoint(x: loc.x, y: CGDisplayBounds(CGMainDisplayID()).height - loc.y)
            for w in lockWindows {
                if NSPointInRect(cocoaPoint, w.frame) {
                    return Unmanaged.passUnretained(event)
                }
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Control Panel

final class ControlPanelController: NSObject, NSWindowDelegate {
    private weak var app: AppDelegate?
    private var window: NSWindow!

    private let currentPassField = NSSecureTextField(frame: .zero)
    private let newPassField = NSSecureTextField(frame: .zero)
    private let confirmPassField = NSSecureTextField(frame: .zero)
    private let messageField = NSTextField(frame: .zero)
    private let dimSlider = NSSlider(value: 0.28, minValue: 0.05, maxValue: 0.85, target: nil, action: nil)
    private let dimLabel = NSTextField(labelWithString: "28%")
    private let statusLabel = NSTextField(labelWithString: "")

    init(app: AppDelegate) {
        self.app = app
        super.init()
        buildWindow()
    }

    func show() {
        loadFromSettings()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window.orderOut(nil)
    }

    private func buildWindow() {
        let w: CGFloat = 480
        let h: CGFloat = 520
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Vaulty Control Panel"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)

        let root = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        window.contentView = root

        var y = h - 48
        let title = makeLabel("Vaulty", size: 26, weight: .bold, color: .white)
        title.frame = NSRect(x: 28, y: y - 4, width: w - 56, height: 32)
        root.addSubview(title)

        y -= 28
        let sub = makeLabel("Transparent WIP lock · password required to unlock", size: 12, weight: .regular, color: NSColor.white.withAlphaComponent(0.55))
        sub.frame = NSRect(x: 28, y: y, width: w - 56, height: 18)
        root.addSubview(sub)

        y -= 40
        addSection("Lock message", at: &y, in: root, width: w)
        messageField.frame = NSRect(x: 28, y: y - 28, width: w - 56, height: 28)
        styleTextField(messageField)
        messageField.placeholderString = "WIP, enter password to unlock"
        root.addSubview(messageField)
        y -= 48

        addSection("Dim opacity", at: &y, in: root, width: w)
        dimSlider.frame = NSRect(x: 28, y: y - 26, width: w - 120, height: 24)
        dimSlider.target = self
        dimSlider.action = #selector(dimChanged)
        root.addSubview(dimSlider)
        dimLabel.frame = NSRect(x: w - 80, y: y - 24, width: 52, height: 20)
        dimLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        dimLabel.textColor = NSColor.white.withAlphaComponent(0.7)
        dimLabel.alignment = .right
        dimLabel.isBezeled = false
        dimLabel.drawsBackground = false
        root.addSubview(dimLabel)
        y -= 48

        addSection("Change password", at: &y, in: root, width: w)
        currentPassField.frame = NSRect(x: 28, y: y - 28, width: w - 56, height: 28)
        styleTextField(currentPassField)
        currentPassField.placeholderString = "Current password"
        root.addSubview(currentPassField)
        y -= 36
        newPassField.frame = NSRect(x: 28, y: y - 28, width: w - 56, height: 28)
        styleTextField(newPassField)
        newPassField.placeholderString = "New password"
        root.addSubview(newPassField)
        y -= 36
        confirmPassField.frame = NSRect(x: 28, y: y - 28, width: w - 56, height: 28)
        styleTextField(confirmPassField)
        confirmPassField.placeholderString = "Confirm new password"
        root.addSubview(confirmPassField)
        y -= 52

        let saveBtn = NSButton(frame: NSRect(x: 28, y: y - 32, width: 140, height: 32))
        saveBtn.title = "Save"
        saveBtn.bezelStyle = .rounded
        saveBtn.target = self
        saveBtn.action = #selector(save)
        root.addSubview(saveBtn)

        let lockBtn = NSButton(frame: NSRect(x: 180, y: y - 32, width: 140, height: 32))
        lockBtn.title = "Lock now"
        lockBtn.bezelStyle = .rounded
        lockBtn.target = self
        lockBtn.action = #selector(lockNow)
        root.addSubview(lockBtn)

        y -= 48
        statusLabel.frame = NSRect(x: 28, y: y, width: w - 56, height: 18)
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = NSColor.systemGreen
        statusLabel.isBezeled = false
        statusLabel.drawsBackground = false
        root.addSubview(statusLabel)

        let foot = makeLabel("Shortcut ⌘⇧L · Settings stay on this Mac only", size: 11, weight: .regular, color: NSColor.white.withAlphaComponent(0.4))
        foot.frame = NSRect(x: 28, y: 18, width: w - 56, height: 16)
        root.addSubview(foot)
    }

    private func addSection(_ text: String, at y: inout CGFloat, in root: NSView, width w: CGFloat) {
        let label = makeLabel(text.uppercased(), size: 11, weight: .semibold, color: NSColor.white.withAlphaComponent(0.45))
        label.frame = NSRect(x: 28, y: y, width: w - 56, height: 16)
        root.addSubview(label)
        y -= 8
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = color
        l.isBezeled = false
        l.drawsBackground = false
        return l
    }

    private func styleTextField(_ field: NSTextField) {
        field.font = NSFont.systemFont(ofSize: 14)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
    }

    private func loadFromSettings() {
        guard let app else { return }
        let s = app.settings
        messageField.stringValue = s.message
        dimSlider.doubleValue = s.dimOpacity
        dimLabel.stringValue = "\(Int(s.dimOpacity * 100))%"
        currentPassField.stringValue = ""
        newPassField.stringValue = ""
        confirmPassField.stringValue = ""
        statusLabel.stringValue = ""
    }

    @objc private func dimChanged() {
        dimLabel.stringValue = "\(Int(dimSlider.doubleValue * 100))%"
    }

    @objc private func save() {
        guard let app else { return }
        var s = app.settings

        let msg = messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !msg.isEmpty { s.message = msg }
        s.dimOpacity = dimSlider.doubleValue

        let current = currentPassField.stringValue
        let newPass = newPassField.stringValue
        let confirm = confirmPassField.stringValue

        if !newPass.isEmpty || !confirm.isEmpty || !current.isEmpty {
            if current != app.settings.password {
                statusLabel.textColor = .systemRed
                statusLabel.stringValue = "Current password is wrong"
                return
            }
            if newPass.isEmpty {
                statusLabel.textColor = .systemRed
                statusLabel.stringValue = "Enter a new password"
                return
            }
            if newPass != confirm {
                statusLabel.textColor = .systemRed
                statusLabel.stringValue = "New passwords do not match"
                return
            }
            s.password = newPass
        }

        app.updateSettings(s)
        currentPassField.stringValue = ""
        newPassField.stringValue = ""
        confirmPassField.stringValue = ""
        statusLabel.textColor = .systemGreen
        statusLabel.stringValue = "Saved"
    }

    @objc private func lockNow() {
        save()
        app?.lock()
    }

    func windowWillClose(_ notification: Notification) {
        // keep controller alive
    }
}

// MARK: - Lock window

/// Rounded dark panel drawn without layer-backing the text field hierarchy
/// (layer-backed ancestors make NSSecureTextField render in the wrong place).
final class LockCardView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18)
        NSColor.black.withAlphaComponent(0.62).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class LockWindow: NSPanel {
    private weak var controller: AppDelegate?
    private let passwordField = NSSecureTextField(frame: .zero)
    private let hintLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private var cardView: LockCardView!

    /// Captured at init: `NSScreen` instances are not stable across
    /// display reconfiguration, the CGDirectDisplayID is.
    let displayID: CGDirectDisplayID

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    init(screen: NSScreen, controller: AppDelegate) {
        self.controller = controller
        self.displayID = LockWindow.displayID(for: screen)
        let frame = screen.frame
        let dim = CGFloat(controller.settings.dimOpacity)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        self.becomesKeyOnlyIfNeeded = false
        self.setFrame(frame, display: true)
        self.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = NSColor.black.withAlphaComponent(dim)
        self.hasShadow = false
        self.ignoresMouseEvents = false
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.animationBehavior = .none
        self.sharingType = .none
        self.appearance = NSAppearance(named: .darkAqua)

        buildUI(in: frame, message: controller.settings.message)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func buildUI(in frame: NSRect, message: String) {
        // Do NOT wantsLayer on ancestors of the text field - that breaks field geometry.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        contentView = container

        let cardW: CGFloat = 400
        let cardH: CGFloat = 220
        cardView = LockCardView(frame: NSRect(
            x: (frame.width - cardW) / 2,
            y: (frame.height - cardH) / 2,
            width: cardW,
            height: cardH
        ))
        // Flexible margins keep the card centered when the screen's
        // resolution or arrangement changes while locked.
        cardView.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        container.addSubview(cardView)

        let lockImg = NSImageView(frame: NSRect(x: (cardW - 28) / 2, y: 168, width: 28, height: 28))
        if let sym = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Lock") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
            lockImg.image = sym.withSymbolConfiguration(cfg)
        }
        lockImg.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        lockImg.imageScaling = .scaleProportionallyUpOrDown
        cardView.addSubview(lockImg)

        let brand = NSTextField(labelWithString: "Vaulty")
        brand.isEditable = false
        brand.isSelectable = false
        brand.isBordered = false
        brand.drawsBackground = false
        brand.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        brand.textColor = NSColor.white.withAlphaComponent(0.45)
        brand.alignment = .center
        brand.frame = NSRect(x: 24, y: 146, width: cardW - 48, height: 16)
        cardView.addSubview(brand)

        messageLabel.stringValue = message
        messageLabel.isEditable = false
        messageLabel.isSelectable = false
        messageLabel.isBordered = false
        messageLabel.drawsBackground = false
        messageLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        messageLabel.textColor = .white
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2
        messageLabel.frame = NSRect(x: 24, y: 108, width: cardW - 48, height: 34)
        cardView.addSubview(messageLabel)

        // Standard dark secure field - sits correctly without custom layer chrome
        let fieldW: CGFloat = cardW - 96
        passwordField.frame = NSRect(x: 48, y: 52, width: fieldW, height: 32)
        passwordField.font = NSFont.systemFont(ofSize: 15)
        passwordField.placeholderString = "Password"
        passwordField.focusRingType = .none
        passwordField.isBezeled = true
        passwordField.bezelStyle = .roundedBezel
        passwordField.drawsBackground = true
        passwordField.isEditable = true
        passwordField.isSelectable = true
        passwordField.appearance = NSAppearance(named: .darkAqua)
        passwordField.target = self
        passwordField.action = #selector(submitPassword)
        cardView.addSubview(passwordField)

        hintLabel.stringValue = ""
        hintLabel.isEditable = false
        hintLabel.isSelectable = false
        hintLabel.isBordered = false
        hintLabel.drawsBackground = false
        hintLabel.font = NSFont.systemFont(ofSize: 12)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        hintLabel.alignment = .center
        hintLabel.frame = NSRect(x: 24, y: 22, width: cardW - 48, height: 18)
        cardView.addSubview(hintLabel)

        let catcher = ClickCatcher(frame: container.bounds)
        catcher.autoresizingMask = [.width, .height]
        container.addSubview(catcher, positioned: .below, relativeTo: cardView)
    }

    func focusPasswordField() {
        makeFirstResponder(passwordField)
    }

    @objc private func submitPassword() {
        let entered = passwordField.stringValue
        if controller?.tryUnlock(with: entered) == true { return }
        hintLabel.stringValue = "Wrong password"
        passwordField.stringValue = ""
        let origin = cardView.frame.origin
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.05
            cardView.animator().setFrameOrigin(NSPoint(x: origin.x - 8, y: origin.y))
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.05
                self.cardView.animator().setFrameOrigin(NSPoint(x: origin.x + 8, y: origin.y))
            } completionHandler: {
                self.cardView.setFrameOrigin(origin)
            }
        }
        focusPasswordField()
    }
}

final class ClickCatcher: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if let panel = window as? LockWindow {
            panel.makeKey()
            panel.focusPasswordField()
        }
    }
}

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
