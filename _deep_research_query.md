# Deep Research Query
**[СИСТЕМНОЕ УВЕДОМЛЕНИЕ ДЛЯ ИССЛЕДОВАТЕЛЯ]**
Текущая дата: Май 2026 года.
Твоя задача — провести поиск в реальном времени и найти самые актуальные данные, техники и статьи за последние 6–12 месяцев. Ищи свежие решения на Reddit, GitHub, X (Twitter), Stack Overflow и в актуальных блогах Apple Developer / Swift Forums.

---

## Контекст проекта

**Voice2** — нативное macOS-приложение на Swift/SwiftUI для голосового ввода текста.
Аналог Wispr Flow, работает полностью локально: Whisper через Metal GPU (Apple Silicon).
Пользователь зажимает хоткей → говорит → текст вставляется в последнее активное приложение.

### Технический стек
- **Frontend:** SwiftUI + AppKit (NSPanel, NSHostingView, NSEvent)
- **Backend/Core:** Swift 5.9, macOS 14+, AVFoundation (микрофон), CGEventTap (глобальный хоткей)
- **ИИ/ML:** whisper-cli bundled в .app, модель ggml-small (465 MB), Metal GPU, Apple Silicon
- **Persistence:** UserDefaults (хоткей), FileManager (WAV-запись)
- **Инфраструктура:** Локальное .app, ad-hoc подпись, Package.swift (SPM)

### Ключевая логика

#### 1. Floating Pill (индикатор записи) — `Pill.swift`
```swift
final class Pill {
    private let panel: NSPanel
    
    private init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 290, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver          // выше всех окон включая full-screen
        panel.hidesOnDeactivate = false     // должен оставаться при потере фокуса
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
    }

    func show() {
        cancelHide()
        Task { @MainActor in self.state.phase = .recording(0) }
        panel.orderFrontRegardless()        // показываем без активации приложения
    }
}
```

#### 2. Глобальный хоткей — `Hotkey.swift`
```swift
final class Hotkey {
    var selectedKey: HotkeyKey = .rightOption {
        didSet { lastFnDown = false }
    }
    private var tap: CFMachPort?
    private var fnGlobalMonitor: Any?
    private var fnLocalMonitor:  Any?

    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { ... },
            userInfo: ptr
        )
        // NSEvent monitors — параллельный путь для Fn/Globe на M-series
        // где CGEventTap не всегда ловит keycode 63
        fnGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { ... }
        fnLocalMonitor  = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { ... }
        return true
    }
    
    // Fn edge-detection: CGEventTap ненадёжен на M-series/macOS 14+
    // Поэтому дублируем через NSEvent
    private var lastFnDown = false
}
```

#### 3. Persistence хоткея — `AppState.swift`
```swift
@Published var hotkeyKey: HotkeyKey = .fn {
    didSet {
        hotkey.selectedKey = hotkeyKey
        UserDefaults.standard.set(hotkeyKey.rawValue, forKey: "v2.hotkeyKey")
    }
}

private init() {
    // Restore saved key (defaults to .fn on first launch)
    if let s = UserDefaults.standard.string(forKey: "v2.hotkeyKey"),
       let k = HotkeyKey(rawValue: s) { hotkeyKey = k }
    hotkey.selectedKey = hotkeyKey  // didSet пропускается во время init — синхронизируем вручную
    hotkeyOK = hotkey.start()
}
```

### Текущие проблемы и ограничения

**Проблема 1 — Pill (индикатор записи) не отображается в фоне при нажатии кнопок**
- Pill должен появляться поверх всех приложений когда Voice2 работает в фоне
- При нажатии хоткея из другого приложения — `orderFrontRegardless()` не всегда показывает NSPanel
- Предположительно: macOS 14+ ужесточил политику для `.nonactivatingPanel` при `hidesOnDeactivate = false`
- Или проблема в том, что `panel.level = .screenSaver` сбрасывается при потере фокуса

**Проблема 2 — Выбранный хоткей не сохраняется после перезапуска (особенно Fn)**
- UserDefaults.standard.set() вызывается в `didSet`
- Но `didSet` НЕ срабатывает во время `init` при `@Published var hotkeyKey = .fn`
- После перезапуска иногда возвращается к дефолтному значению
- Fn (keycode 63) особенно проблематичен: на M-series `maskSecondaryFn` ведёт себя иначе чем на Intel

**Проблема 3 — Нет автозагрузки при включении компьютера (Login Item)**
- В приложении нет никакого механизма LaunchAtLogin
- Нужно добавить через `SMAppService.mainApp` (macOS 13+) или LaunchAgent plist
- Приложение не нотаризовано (ad-hoc подпись) — это может влиять на SMAppService

---

## Задание для исследования

Проведи глубокое исследование по следующим трём направлениям:

### 1. NSPanel не показывается в фоне (Pill overlay bug)
- Как надёжно сделать floating NSPanel/NSWindow видимым поверх всех приложений когда основное приложение в фоне на macOS 14+?
- Какие комбинации `windowLevel`, `collectionBehavior`, `hidesOnDeactivate`, `orderFrontRegardless()` работают в 2025–2026?
- Есть ли изменения в macOS 14/15 (Sonoma/Sequoia) которые сломали `panel.level = .screenSaver` или `.nonactivatingPanel`?
- Альтернативы: использовать `NSWindow` вместо `NSPanel`, другой `windowLevel` (floating, tornOffMenu, popUpMenu)?
- Примеры реального кода из open-source утилит (Raycast-style overlays, screenshot tools, etc.)

### 2. UserDefaults + Fn key persistence после перезапуска
- Почему `UserDefaults.standard.set()` в SwiftUI `@Published` `didSet` может не сохраняться на диск до выхода из приложения?
- Нужно ли явно вызывать `UserDefaults.standard.synchronize()` или это не нужно в macOS 14+?
- Известные проблемы с Fn/Globe key (keycode 63) на Apple Silicon: почему `maskSecondaryFn` ведёт себя непредсказуемо?
- Как другие приложения надёжно определяют Fn key через CGEventTap в macOS 14+? Есть ли альтернативный approach через IOKit или другие API?
- Swift Forums / Apple Developer Forums — есть ли известные баги с `CGEventType.flagsChanged` + `keycode 63` на macOS 14+?

### 3. Login Item (автозагрузка) для не-нотаризованного macOS приложения
- Как добавить "Запускать при входе в систему" через `SMAppService.mainApp.register()` на macOS 13+?
- Работает ли `SMAppService` для приложения с ad-hoc подписью (без Developer ID, без нотаризации)?
- Если не работает — какой fallback? LaunchAgent plist в `~/Library/LaunchAgents/`? Как это сделать программно из Swift?
- Как добавить Toggle "Запускать при старте" в SwiftUI интерфейс?
- Примеры готового Swift кода для всех трёх подходов

### 4. Безопасность и edge cases
- Может ли CGEventTap стать причиной зависания приложения при потере Input Monitoring разрешения?
- Как правильно обработать перезапуск tap при изменении разрешений (без утечки памяти)?
- Thread-safety: `@MainActor` + `Task.detached` в Whisper pipeline — есть ли race conditions?

---

## Формат ответа

Дай мне:
- Конкретные решения с кодом (готовым к копированию в Swift)
- Ссылки на источники (Swift Forums, GitHub, Apple Developer Docs, Stack Overflow)
- Приоритизацию: что внедрить в первую очередь (Pill > Persistence > LaunchAtLogin)
- Пошаговый план внедрения каждого фикса
- Что НЕ делать (anti-patterns которые сломают что-то ещё)
