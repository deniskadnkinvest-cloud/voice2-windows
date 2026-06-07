import AppKit
import Combine
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var recordingObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = makeIcon()
        _ = AppState.shared
        _ = Pill.shared
        _ = ModelManager.shared

        installStatusItem()

        recordingObserver = AppState.shared.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] rec in self?.updateStatusIcon(recording: rec) }

        // Первый запуск или модель удалена — показать онбординг.
        // Иначе сразу открыть главное окно, чтобы оператор видел настройки,
        // выбор модели, словарь и т.д. (раньше окно открывалось только по клику
        // на иконку в меню-баре — казалось, что «всё пропало»).
        if ModelManager.shared.needsOnboarding() {
            showOnboarding()
        } else {
            // На следующем тике runloop, когда приложение уже активно — иначе окно
            // создаётся, но не выводится на экран (onscreen=false).
            DispatchQueue.main.async { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.showWindow()
            }
        }
    }

    private var onboardingWindow: NSWindow?

    func showOnboarding() {
        if let w = onboardingWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let ctrl = NSHostingController(rootView: OnboardingView { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        })
        ctrl.view.frame = NSRect(x: 0, y: 0, width: 520, height: 460)
        let w = NSPanel(
            contentRect: ctrl.view.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "VoiceTuT — настройка модели"
        w.contentViewController = ctrl
        w.isReleasedWhenClosed = false
        w.center()
        w.makeKeyAndOrderFront(nil)
        onboardingWindow = w
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    // MARK: - Status item (menu bar mic icon)

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "VoiceTuT")
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private func updateStatusIcon(recording: Bool) {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: recording ? "mic.fill" : "mic",
            accessibilityDescription: "VoiceTuT"
        )
        button.contentTintColor = recording ? .systemRed : nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp ||
            (event?.modifierFlags.contains(.control) ?? false)

        if isRightClick {
            showStatusMenu(from: sender)
        } else {
            showWindow()
        }
    }

    private func showStatusMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Открыть VoiceTuT", action: #selector(showWindow), keyEquivalent: "o")
            .target = self
        menu.addItem(NSMenuItem.separator())
        let status = AppState.shared.isRecording ? "● Запись…" : "Готов"
        let info = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc func showWindow() {
        if let w = mainWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.orderFrontRegardless()
            return
        }

        let ctrl = NSHostingController(rootView: ContentView())
        ctrl.view.frame = NSRect(x: 0, y: 0, width: 440, height: 580)

        // Обычный NSWindow, НЕ NSPanel: у панелей особая семантика показа,
        // из-за которой окно не выходило на экран при открытии на старте
        // (создавалось, но onscreen=false). Стандартное окно показывается надёжно.
        let w = NSWindow(
            contentRect: ctrl.view.frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "VoiceTuT"
        w.contentViewController = ctrl
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.hidesOnDeactivate = false
        w.center()
        mainWindow = w

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
    }

    private func makeIcon() -> NSImage {
        let size = CGSize(width: 512, height: 512)
        let img = NSImage(size: size)
        img.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        let rect = CGRect(origin: .zero, size: size)
        let path = CGPath(roundedRect: rect, cornerWidth: 115, cornerHeight: 115, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0.10, green: 0.55, blue: 0.85, alpha: 1))
        ctx.fillPath()
        if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 280, weight: .medium)) {
            let tinted = NSImage(size: mic.size)
            tinted.lockFocus()
            NSColor.white.set()
            mic.draw(in: NSRect(origin: .zero, size: mic.size))
            tinted.unlockFocus()
            let x = (size.width - mic.size.width) / 2
            let y = (size.height - mic.size.height) / 2
            tinted.draw(at: NSPoint(x: x, y: y), from: .zero, operation: .sourceOver, fraction: 1)
        }
        img.unlockFocus()
        return img
    }
}
