import Cocoa

// MARK: - Hotkey binding

enum HotkeyKey: String, CaseIterable, Identifiable, Equatable {
    case rightOption  = "Right ⌥"
    case rightControl = "Right ⌃"
    case rightCommand = "Right ⌘"
    case fn           = "Fn"

    var id: String { rawValue }

    var code: CGKeyCode {
        switch self {
        case .rightOption:  return 61
        case .rightControl: return 62
        case .rightCommand: return 54
        case .fn:           return 63
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .rightOption:  return .maskAlternate
        case .rightControl: return .maskControl
        case .rightCommand: return .maskCommand
        case .fn:           return .maskSecondaryFn
        }
    }
}

// MARK: - Global hotkey via CGEventTap + NSEvent monitor

final class Hotkey {
    var onDown: (() -> Void)?
    var onUp:   (() -> Void)?
    var logCallback: ((String) -> Void)?

    // Дефолт — Fn: на новой машине (и при чистой установке из DMG) хоткей всегда Fn,
    // в тон AppState.hotkeyKey, который тоже стартует с .fn. UserDefaults может
    // переопределить выбор позже, если оператор сам сменит кнопку в настройках.
    var selectedKey: HotkeyKey = .fn {
        didSet { lastFnDown = false }
    }

    private(set) var isActive = false
    private var tap: CFMachPort?
    private var src: CFRunLoopSource?
    private var selfPtr: UnsafeMutableRawPointer?

    // NSEvent monitors — parallel delivery path for Fn/Globe key
    private var fnGlobalMonitor: Any?
    private var fnLocalMonitor:  Any?

    // Double-tap → hands-free mode
    private var handsFree = false
    private var lastUpTime: Date = .distantPast
    private var lastDownTime: Date = .distantPast
    private var ignoreNextUp = false
    private var isDownState = false  // dedup duplicate edges (same direction in a row)

    // Fn edge-detection state (shared by CGEventTap and NSEvent paths)
    private var lastFnDown = false

    // Diagnostic: log next N flagsChanged events verbatim
    var diagRemaining = 0

    func start() -> Bool {
        guard !isActive else { return true }

        let ptr = Unmanaged.passRetained(self).toOpaque()
        selfPtr = ptr

        // Listen for flagsChanged + tap-disabled events so we can re-enable
        // the tap if the system disables it (timeout / heavy CPU spike).
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)
        )

        let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, ref -> Unmanaged<CGEvent>? in
                guard let ref else { return Unmanaged.passUnretained(event) }
                let h = Unmanaged<Hotkey>.fromOpaque(ref).takeUnretainedValue()
                return h.handle(type: type, event: event)
            },
            userInfo: ptr
        )

        guard let t else {
            Unmanaged<Hotkey>.fromOpaque(ptr).release()
            selfPtr = nil
            logCallback?("[Hotkey] ❌ tapCreate failed — нет Input Monitoring?")
            return false
        }

        tap = t
        src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        isActive = true
        logCallback?("[Hotkey] ✓ CGEventTap запущен — \(selectedKey.rawValue)")

        // NSEvent monitors are a parallel delivery path — important for Fn/Globe on
        // M-series Macs where CGEventTap may not receive flagsChanged for keycode 63.
        // Global fires when another app is in front; Local fires when Voice2 is in front.
        let fnHandler = { [weak self] (nsEvent: NSEvent) in
            guard let self, self.selectedKey == .fn else { return }
            let fnNow = nsEvent.modifierFlags.contains(.function)
            if self.diagRemaining > 0 {
                self.logCallback?("[NSEvent] flags=\(String(format:"0x%06X", nsEvent.modifierFlags.rawValue & 0xFFFFFF)) fn=\(fnNow)")
            }
            guard fnNow != self.lastFnDown else { return }
            self.lastFnDown = fnNow
            // Route through processEdge so double-tap → hands-free works for Fn too.
            // Previously called fire() directly, which skipped the hands-free state machine.
            self.processEdge(isDown: fnNow)
        }
        fnGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: fnHandler)
        fnLocalMonitor  = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { nsEvent in
            fnHandler(nsEvent)
            return nsEvent
        }

        return true
    }

    func stop() {
        guard isActive else { return }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); tap = nil }
        if let s = src { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes); src = nil }
        if let p = selfPtr { Unmanaged<Hotkey>.fromOpaque(p).release(); selfPtr = nil }
        if let m = fnGlobalMonitor { NSEvent.removeMonitor(m); fnGlobalMonitor = nil }
        if let m = fnLocalMonitor  { NSEvent.removeMonitor(m); fnLocalMonitor  = nil }
        isActive = false
        handsFree = false
        lastFnDown = false
        isDownState = false
        ignoreNextUp = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // System disables the tap on timeout / user input. Re-enable so the hotkey
        // doesn't silently stop working after a long pause or a heavy CPU spike.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            logCallback?("[Hotkey] ⚠️ CGEventTap disabled — re-enabled")
            return Unmanaged.passUnretained(event)
        }
        guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        let key   = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        // Diagnostic mode: log every event verbatim
        if diagRemaining > 0 {
            diagRemaining -= 1
            let fhex = String(format: "0x%06X", flags.rawValue & 0xFFFFFF)
            let fnBit = flags.contains(.maskSecondaryFn) ? " Fn✓" : ""
            logCallback?("[CGTap] key=\(key) flags=\(fhex)\(fnBit) sel=\(selectedKey.rawValue)")
        }

        // Fn/Globe is handled exclusively via NSEvent monitor below.
        // Running both paths fires processEdge() twice per edge, which breaks the
        // double-tap window (the second invocation hits the dedup guard).
        if selectedKey == .fn {
            return Unmanaged.passUnretained(event)
        }

        guard key == selectedKey.code else { return Unmanaged.passUnretained(event) }
        let isDown = flags.contains(selectedKey.flag)

        processEdge(isDown: isDown)
        return nil
    }

    private func processEdge(isDown: Bool) {
        // Dedup: ignore consecutive edges in the same direction.
        // Some keys (Fn on M-series) can emit duplicate flagsChanged events
        // for the same physical action; we only care about real transitions.
        guard isDown != isDownState else { return }
        isDownState = isDown

        let now = Date()
        if isDown {
            if handsFree {
                handsFree = false
                ignoreNextUp = true
                fire(down: false)
                logCallback?("[Hotkey] Hands-free OFF")
            } else {
                fire(down: true)
                // Double-tap detection: this down came within 350ms of the previous up.
                // No lower bound — a fast double-tap (40ms between events) is fine.
                if now.timeIntervalSince(lastUpTime) < 0.35 {
                    handsFree = true
                    logCallback?("[Hotkey] Hands-free ON")
                }
            }
            lastDownTime = now
        } else {
            if ignoreNextUp { ignoreNextUp = false; lastUpTime = now; return }
            lastUpTime = now
            if !handsFree { fire(down: false) }
        }
    }

    private func fire(down: Bool) {
        Task { @MainActor in
            if down { self.onDown?() } else { self.onUp?() }
        }
    }
}
