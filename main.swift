import Cocoa
import ApplicationServices
import Carbon
import Darwin

func lockInstance(at path: String) -> Int32 {
    let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { return -1 }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); return -1 }
    return descriptor
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return value
}
func text(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? ""
}
func parseCode(_ value: String) -> String? {
    let code = value.filter { !$0.isWhitespace }
    guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return code
}
struct Browser {
    let identifier: String
    let path: String
    let dialogNames: [String]
}
let browsers = [
    Browser(identifier: "net.imput.helium", path: "/Applications/Helium.app", dialogNames: ["Helium"]),
    Browser(identifier: "com.google.Chrome", path: "/Applications/Google Chrome.app", dialogNames: ["Chrome", "Google Chrome"])
]
func supportedBrowser(_ app: NSRunningApplication?) -> Browser? {
    guard let app else { return nil }
    return browsers.first {
        app.bundleIdentifier == $0.identifier && app.bundleURL?.resolvingSymlinksInPath().path == $0.path
    }
}
func browserIdentifier(for header: String) -> String? {
    browsers.first { browser in
        browser.dialogNames.contains { name in
            header == "Enable Password AutoFill for “\(name)”" || header == "Enable Password AutoFill for \"\(name)\"" ||
                header == "Enable Password AutoFill for \(name)"
        }
    }?.identifier
}
struct Discovery {
    let browserID: String
    let code: String
    let window: AXUIElement
    func matches(_ other: Discovery) -> Bool {
        browserID == other.browserID && code == other.code && CFEqual(window, other.window)
    }
}
func discover(in apps: [NSRunningApplication], for browserID: String? = nil) -> Discovery? {
    guard AXIsProcessTrusted() else { return nil }
    var matches: [Discovery] = []
    for app in apps {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.75)
        for window in attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
            where text(window, kAXTitleAttribute) == "Verification Code" {
            var codes = Set<String>()
            var matchedBrowsers = Set<String>()
            var visited = 0
            func read(_ node: AXUIElement, _ depth: Int) {
                guard depth < 16, visited < 300 else { return }
                visited += 1
                for key in [kAXValueAttribute, kAXTitleAttribute] {
                    let value = text(node, key)
                    if let identifier = browserIdentifier(for: value) { matchedBrowsers.insert(identifier) }
                    if let code = parseCode(value) { codes.insert(code) }
                }
                for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { read(child, depth + 1) }
            }
            read(window, 0)
            guard matchedBrowsers.count == 1, let matchedBrowser = matchedBrowsers.first,
                  browserID == nil || browserID == matchedBrowser else { continue }
            if codes.count == 1, let code = codes.first {
                matches.append(Discovery(browserID: matchedBrowser, code: code, window: window))
            }
        }
    }
    return matches.count == 1 ? matches[0] : nil
}

let extensionID = "pejdijmoenmkgeppbflobdenhhabjlaj"
func validPromptURL(_ value: String) -> Bool {
    guard let url = URLComponents(string: value) else { return false }
    return url.scheme == "chrome-extension" && url.host == extensionID &&
        url.user == nil && url.password == nil && url.port == nil &&
        url.percentEncodedPath == "/page_popup.html"
}
func validPrefix(_ values: [String], code: String, index: Int) -> Bool {
    let digits = code.map(String.init)
    guard values.count == 6, digits.count == 6, (0..<6).contains(index) else { return false }
    return values.indices.allSatisfy { $0 < index ? values[$0] == digits[$0] : values[$0].isEmpty }
}
struct Destination {
    let browserID: String
    let pid: pid_t
    let area: AXUIElement
    let fields: [AXUIElement]
    let values: [String]
    let index: Int
    func matches(_ other: Destination) -> Bool {
        browserID == other.browserID && pid == other.pid && CFEqual(area, other.area) && fields.count == other.fields.count &&
            zip(fields, other.fields).allSatisfy { CFEqual($0, $1) }
    }
}
func element(_ root: AXUIElement, _ key: String) -> AXUIElement? {
    guard let value = attribute(root, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}
func runningBrowser(_ browserID: String) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first {
        $0.bundleIdentifier == browserID && supportedBrowser($0) != nil && !$0.isTerminated
    }
}
// Chromium only exposes web content (the extension popup) to accessibility clients that ask for
// it via AXEnhancedUserInterface; without it, a freshly launched browser reports no focused
// element and no AXWebArea. Enabled only while a code is pending, then switched back off.
var enhancedPIDs = Set<pid_t>()
func enableWebAccessibility(for browserID: String) {
    guard let app = runningBrowser(browserID), !enhancedPIDs.contains(app.processIdentifier) else { return }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    if (attribute(root, "AXEnhancedUserInterface") as? Bool) == true { return }
    // Chromium applies this but may still report kAXErrorNotImplemented, so track it regardless.
    AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    enhancedPIDs.insert(app.processIdentifier)
}
func releaseWebAccessibility() {
    for pid in enhancedPIDs {
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXEnhancedUserInterface" as CFString,
                                     kCFBooleanFalse)
    }
    enhancedPIDs.removeAll()
}
// On macOS 15 the helper's "Verification Code" window becomes the active app, so the browser is
// no longer frontmost and no PIN field has focus. Bring the browser back and focus the next
// empty PIN field in the extension prompt so destination() can find it.
func focusPrompt(for browserID: String) {
    guard let app = runningBrowser(browserID) else { return }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(root, 0.75)
    enableWebAccessibility(for: browserID)
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
        AXUIElementSetAttributeValue(root, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate()
    }
    var visited = 0
    func area(_ node: AXUIElement, _ depth: Int) -> AXUIElement? {
        guard depth < 24, visited < 2000 else { return nil }
        visited += 1
        if text(node, kAXRoleAttribute) == "AXWebArea" {
            let rawURL = attribute(node, kAXURLAttribute)
            let url = (rawURL as? URL)?.absoluteString ?? (rawURL as? String ?? "")
            return validPromptURL(url) && text(node, kAXTitleAttribute) == "iCloud Passwords" ? node : nil
        }
        for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let found = area(child, depth + 1) { return found }
        }
        return nil
    }
    guard let prompt = (attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []).lazy
        .compactMap({ area($0, 0) }).first else { return }
    if let window = element(prompt, kAXWindowAttribute) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
    var fields: [AXUIElement] = []
    func walk(_ node: AXUIElement, _ depth: Int) {
        guard depth < 20, fields.count < 7 else { return }
        if text(node, kAXRoleAttribute) == kAXTextFieldRole { fields.append(node) }
        for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth + 1) }
    }
    walk(prompt, 0)
    guard fields.count == 6, let next = fields.first(where: { text($0, kAXValueAttribute).isEmpty }) else { return }
    AXUIElementSetAttributeValue(next, kAXFocusedAttribute as CFString, kCFBooleanTrue)
}
func destination() -> Destination? {
    guard let app = NSWorkspace.shared.frontmostApplication,
          let browser = supportedBrowser(app),
          let focused = element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
          text(focused, kAXRoleAttribute) == kAXTextFieldRole else { return nil }
    var pid: pid_t = 0
    guard AXUIElementGetPid(focused, &pid) == .success, pid == app.processIdentifier else { return nil }
    var ancestor: AXUIElement? = focused
    for _ in 0..<24 {
        guard let node = ancestor else { return nil }
        if text(node, kAXRoleAttribute) == "AXWebArea" {
            let rawURL = attribute(node, kAXURLAttribute)
            let url = (rawURL as? URL)?.absoluteString ?? (rawURL as? String ?? "")
            guard validPromptURL(url), text(node, kAXTitleAttribute) == "iCloud Passwords" else { return nil }
            var fields: [AXUIElement] = []
            var visited = 0
            var complete = true
            func walk(_ child: AXUIElement, _ depth: Int) {
                guard depth < 20, visited < 256 else { complete = false; return }
                visited += 1
                let role = text(child, kAXRoleAttribute)
                if role == "AXWebArea" && !CFEqual(child, node) { complete = false; return }
                if role == kAXTextFieldRole { fields.append(child) }
                for item in attribute(child, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(item, depth + 1) }
            }
            walk(node, 0)
            guard complete, fields.count == 6,
                  let index = fields.firstIndex(where: { CFEqual($0, focused) }) else { return nil }
            for (i, field) in fields.enumerated() {
                guard (attribute(field, kAXEnabledAttribute) as? Bool) == true else { return nil }
                let identifier = text(field, "AXDOMIdentifier")
                if !identifier.isEmpty && identifier != "PIN\(i)" { return nil }
            }
            return Destination(browserID: browser.identifier, pid: pid, area: node, fields: fields,
                               values: fields.map { text($0, kAXValueAttribute) }, index: index)
        }
        ancestor = element(node, kAXParentAttribute)
    }
    return nil
}

final class OverlayClickSurface: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class HUD: NSPanel {
    let label = NSTextField(labelWithString: "")
    let clickSurface = OverlayClickSurface()
    var onFill: (() -> Void)?
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 184, height: 32),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        contentView!.wantsLayer = true
        contentView!.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        contentView!.layer?.cornerRadius = 10
        contentView!.layer?.cornerCurve = .continuous
        contentView!.layer?.masksToBounds = true
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        becomesKeyOnlyIfNeeded = true
        let icon = NSImageView(frame: NSRect(x: 6, y: 4, width: 24, height: 24))
        if let resource = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            icon.image = NSImage(contentsOf: resource)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        contentView!.addSubview(icon)
        label.frame = NSRect(x: 36, y: 8, width: 136, height: 16)
        label.autoresizingMask = [.width, .height]
        label.font = .systemFont(ofSize: 12)
        label.textColor = NSColor(white: 0.92, alpha: 1)
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.drawsBackground = false
        contentView!.addSubview(label)
        clickSurface.frame = contentView!.bounds
        clickSurface.autoresizingMask = [.width, .height]
        clickSurface.onClick = { [weak self] in self?.onFill?() }
        clickSurface.onHover = { [weak self] in self?.highlight($0) }
        contentView!.addSubview(clickSurface)
    }
    func highlight(_ hovered: Bool) {
        contentView?.layer?.backgroundColor = NSColor(white: hovered ? 0.24 : 0.16, alpha: 1).cgColor
    }
    override func orderOut(_ sender: Any?) {
        highlight(false)
        super.orderOut(sender)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    func position(below window: AXUIElement) -> Bool {
        guard let position = attribute(window, kAXPositionAttribute),
              let size = attribute(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID(),
              let primaryScreen = NSScreen.screens.first else { return false }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return false }
        let origin = NSPoint(x: point.x + (dimensions.width - frame.width) / 2,
                             y: primaryScreen.frame.maxY - point.y - dimensions.height - frame.height - 6)
        if frame.origin != origin { setFrameOrigin(origin) }
        return true
    }
    func show(below window: AXUIElement) {
        label.stringValue = "Click or ⌘↩ to fill"
        guard position(below: window) else { orderOut(nil); return }
        orderFrontRegardless()
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var settingsWindow: NSWindow?
    var accessibilityLabel: NSTextField?
    var settingsTimer: Timer?
    var trusted = false
    var enabled: Bool { !UserDefaults.standard.bool(forKey: "paused") }
    var hud: HUD?
    var helpers: [NSRunningApplication] = []
    var observers: [pid_t: AXObserver] = [:]
    var fallback = false
    var timer: Timer?
    var pending: Discovery?
    var handled: Discovery?
    var approveKey: EventHotKeyRef?
    var manualKey: EventHotKeyRef?
    var handler: EventHandlerRef?
    var busy = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            if id.id == 1 { app.approve() }
            if id.id == 3 { app.scan() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        _ = bind(3, UInt32(kVK_ANSI_V), UInt32(controlKey | optionKey | cmdKey), &manualKey)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(wake), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(wake), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(settingsRequested),
            name: Notification.Name("local.zimeng.verification-code-shortcut.settings"), object: String(getuid()))
        connect()
        if !CommandLine.arguments.contains("--background") { showSettings() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc func wake(_ notification: Notification) { connect() }
    @objc func settingsRequested(_ notification: Notification) { showSettings() }
    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 212),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Chromakey"
            window.isReleasedWhenClosed = false
            let toggle = NSButton(checkboxWithTitle: "Enabled", target: self, action: #selector(toggleEnabled))
            toggle.state = enabled ? .on : .off
            toggle.frame = NSRect(x: 20, y: 162, width: 260, height: 24)
            window.contentView?.addSubview(toggle)
            let label = NSTextField(labelWithString: "")
            label.frame = NSRect(x: 20, y: 130, width: 260, height: 20)
            label.font = .systemFont(ofSize: 13)
            window.contentView?.addSubview(label)
            accessibilityLabel = label
            let permissions = NSButton(title: "Accessibility Settings…", target: self, action: #selector(settings))
            permissions.bezelStyle = .rounded
            permissions.frame = NSRect(x: 16, y: 87, width: 268, height: 32)
            window.contentView?.addSubview(permissions)
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            let release = NSTextField(labelWithString: "Version \(version) · Build \(build)")
            release.frame = NSRect(x: 20, y: 55, width: 260, height: 16)
            release.font = .systemFont(ofSize: 11)
            release.textColor = .secondaryLabelColor
            window.contentView?.addSubview(release)
            let copyright = NSTextField(labelWithString: "© \(Calendar.current.component(.year, from: Date())) Zimeng Xiong")
            copyright.frame = NSRect(x: 20, y: 15, width: 128, height: 16)
            copyright.font = .systemFont(ofSize: 10.5)
            copyright.textColor = .secondaryLabelColor
            window.contentView?.addSubview(copyright)
            let github = NSTextField(labelWithAttributedString: NSAttributedString(string: "GitHub", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5),
                .link: URL(string: "https://github.com/ZimengXiong/chromakey")!
            ]))
            github.frame = NSRect(x: 150, y: 15, width: 48, height: 16)
            github.isSelectable = true
            github.allowsEditingTextAttributes = true
            window.contentView?.addSubview(github)
            let quit = NSButton(title: "Quit", target: self, action: #selector(quit))
            quit.bezelStyle = .rounded
            quit.frame = NSRect(x: 210, y: 8, width: 74, height: 28)
            window.contentView?.addSubview(quit)
            window.center()
            settingsWindow = window
        }
        updateSettings()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if settingsTimer == nil {
            settingsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.settingsWindow?.isVisible == true { self.updateSettings() }
                else { self.settingsTimer?.invalidate(); self.settingsTimer = nil }
            }
        }
    }
    func updateSettings() {
        accessibilityLabel?.stringValue = AXIsProcessTrusted() ? "Accessibility: Allowed" : "Accessibility: Not allowed"
    }
    @objc func toggleEnabled(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state != .on, forKey: "paused")
        clear()
        handled = nil
        connect()
    }
    @objc func appChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.apple.PasswordManagerBrowserExtensionHelper" else { return }
        connect()
    }
    func connect() {
        for observer in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll()
        helpers = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "com.apple.PasswordManagerBrowserExtensionHelper" && !$0.isTerminated
        }
        trusted = AXIsProcessTrusted()
        fallback = !trusted
        if !fallback {
            for app in helpers {
                var observer: AXObserver?
                let result = AXObserverCreate(app.processIdentifier, { _, element, _, context in
                    guard let context else { return }
                    let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
                    app.watch(element)
                    app.poll()
                }, &observer)
                guard result == .success, let observer else { fallback = true; continue }
                let root = AXUIElementCreateApplication(app.processIdentifier)
                let context = Unmanaged.passUnretained(self).toOpaque()
                var registered = false
                for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
                             kAXMainWindowChangedNotification, kAXFocusedUIElementChangedNotification,
                             kAXCreatedNotification, kAXLayoutChangedNotification, kAXValueChangedNotification] {
                    if AXObserverAddNotification(observer, root, name as CFString, context) == .success {
                        registered = true
                    }
                }
                guard registered else { fallback = true; continue }
                observers[app.processIdentifier] = observer
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        poll()
    }
    func watch(_ window: AXUIElement) {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        guard let observer = observers[pid] else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification,
                     kAXLayoutChangedNotification, kAXValueChangedNotification, kAXCreatedNotification,
                     kAXElementBusyChangedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(observer, window, name as CFString, context)
        }
        var visited = 0
        func subscribe(_ node: AXUIElement, _ depth: Int) {
            guard depth < 16, visited < 300 else { return }
            visited += 1
            for name in [kAXValueChangedNotification, kAXCreatedNotification, kAXLayoutChangedNotification] {
                AXObserverAddNotification(observer, node, name as CFString, context)
            }
            for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { subscribe(child, depth + 1) }
        }
        subscribe(window, 0)
    }
    func updateTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            guard let self else { return }
            let live = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == "com.apple.PasswordManagerBrowserExtensionHelper" && !$0.isTerminated
            }
            if Set(live.map(\.processIdentifier)) != Set(self.helpers.map(\.processIdentifier)) ||
                AXIsProcessTrusted() != self.trusted || (self.fallback && AXIsProcessTrusted()) {
                self.connect()
            } else { self.poll() }
        }
        timer.tolerance = 0.08
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func bind(_ id: UInt32, _ key: UInt32, _ modifiers: UInt32, _ ref: inout EventHotKeyRef?) -> Bool {
        RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x56435343, id: id),
                            GetApplicationEventTarget(), 0, &ref) == noErr
    }
    func clear() {
        pending = nil
        if let approveKey { UnregisterEventHotKey(approveKey) }; approveKey = nil
        hud?.orderOut(nil)
    }
    func poll() {
        autoreleasepool { refresh() }
    }
    func refresh() {
        guard !busy else { return }
        defer { updateTimer() }
        guard enabled else { clear(); handled = nil; releaseWebAccessibility(); return }
        guard let found = discover(in: helpers, for: supportedBrowser(NSWorkspace.shared.frontmostApplication)?.identifier) else {
            clear(); handled = nil; releaseWebAccessibility(); return
        }
        if handled?.matches(found) == true { return }
        if pending?.matches(found) == true {
            hud?.show(below: found.window)
            return
        }
        clear()
        pending = found
        enableWebAccessibility(for: found.browserID)
        _ = bind(1, UInt32(kVK_Return), UInt32(cmdKey), &approveKey)
        watch(found.window)
        if hud == nil {
            hud = HUD()
            hud?.onFill = { [weak self] in self?.approve() }
        }
        hud?.show(below: found.window)
    }
    @objc func scan() { handled = nil; clear(); connect() }
    func approve() {
        guard !busy, let found = pending else { return }
        if let target = destination() {
            guard target.browserID == found.browserID,
                  validPrefix(target.values, code: found.code, index: target.index) else { return }
            busy = true
            clear()
            waitForRelease(found, target, 0)
            return
        }
        // The prompt is not focused (e.g. the helper window took focus on macOS 15):
        // refocus it and retry for up to ~1s.
        busy = true
        focusPrompt(for: found.browserID)
        retryApprove(found, 0)
    }
    func retryApprove(_ found: Discovery, _ attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard self.pending?.matches(found) == true else { self.finish(); return }
            guard let target = destination() else {
                if attempts < 20 {
                    if attempts % 5 == 4 { focusPrompt(for: found.browserID) }
                    self.retryApprove(found, attempts + 1)
                } else { self.finish() }
                return
            }
            guard target.browserID == found.browserID,
                  validPrefix(target.values, code: found.code, index: target.index) else { self.finish(); return }
            self.clear()
            self.waitForRelease(found, target, 0)
        }
    }
    func waitForRelease(_ found: Discovery, _ target: Destination, _ attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty {
                if attempts < 40 { self.waitForRelease(found, target, attempts + 1) }
                else { self.finish() }
                return
            }
            self.type(found, target: target, index: target.index)
        }
    }
    func finish() { busy = false; poll() }
    func type(_ found: Discovery, target: Destination, index: Int, retry: Int = 0) {
        guard enabled, let current = discover(in: helpers, for: found.browserID), current.matches(found),
              let focused = destination(), focused.matches(target) else { finish(); return }
        if focused.index != index || !validPrefix(focused.values, code: found.code, index: index) {
            let waiting = index > 0 && (focused.index == index - 1 || focused.index == index) &&
                (validPrefix(focused.values, code: found.code, index: index - 1) ||
                 validPrefix(focused.values, code: found.code, index: index))
            if waiting && retry < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
                    self?.type(found, target: target, index: index, retry: retry + 1)
                }
            } else { finish() }
            return
        }
        var digit = Array(found.code.utf16)[index]
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { finish(); return }
        for event in [down, up] {
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &digit)
            event.postToPid(target.pid)
        }
        if index < 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.type(found, target: target, index: index + 1)
            }
        } else {
            handled = found
            finish()
        }
    }
    @objc func settings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func quit() { NSApp.terminate(nil) }
}

let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Verification Code Shortcut")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    guard lockInstance(at: directory.appendingPathComponent("instance.lock").path) >= 0 else {
        if !CommandLine.arguments.contains("--background") {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("local.zimeng.verification-code-shortcut.settings"),
                object: String(getuid()), userInfo: nil, deliverImmediately: true)
        }
        exit(0)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
