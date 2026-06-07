# Voice2 — macOS диктовщик текста

Локальное приложение для голосового ввода на macOS. Аналог Wispr Flow, без облака, без подписки.
Whisper работает прямо на устройстве через Metal GPU (Apple Silicon).

---

## Что умеет

| Функция | Как работает |
|---|---|
| Диктовка | Зажал кнопку → говоришь → отпустил → текст вставлен |
| Глобальный хоткей | Right Option (⌥ правый) — работает в любом приложении |
| Hands-free режим | Двойной тап Right Option → пишет пока не тапнешь снова |
| Floating overlay | Пилюля внизу экрана показывает статус: запись / распознаю / готово |
| Вставка текста | Clipboard + Cmd+V — работает в любом приложении (TextEdit, Notion, Telegram, Safari...) |
| Локальное распознавание | whisper-cli bundled в .app, модель ggml-small (465 MB) |
| Иконка в Dock + Cmd+Tab | Полноценное .regular приложение, не menu-bar-only |
| Иконка в Menu Bar | Mic иконка, меняется на mic.fill во время записи |

---

## Быстрый старт

### 1. Сборка и установка

```bash
cd ~/Desktop/Claude/my-tools/voice2
bash build.sh
```

Скрипт:
- компилирует Swift код
- копирует whisper-cli + ggml-small.bin в Resources
- подписывает ad-hoc
- устанавливает в /Applications/Voice2.app
- запускает

### 2. Разрешения (один раз после установки)

**Микрофон** — нажми "Выдать доступ к микрофону" в приложении.

**Accessibility** (нужен для вставки):
```
Настройки → Конфиденциальность → Универсальный доступ → + → /Applications/Voice2.app → включи
```

**Input Monitoring** (нужен для хоткея):
```
Настройки → Конфиденциальность → Мониторинг ввода → + → /Applications/Voice2.app → включи
```

После выдачи разрешений → **перезапусти Voice2** один раз.

### 3. Проверка

В логе внизу приложения должна быть строка:
```
Perms  mic:✓  ax:✓  hotkey:✓
```

---

## Как пользоваться

### Кнопка в окне
- Нажми и держи "🎙 Зажми и говори"
- Говори
- Отпусти — текст вставится в последнее активное приложение

### Хоткей (работает в фоне, не нужно открывать Voice2)
- **Right Option** зажал → говоришь → отпустил
- **Right Option двойной тап** → hands-free режим (пишет пока не тапнешь снова)
- Во время записи в правом нижнем углу экрана появляется пилюля

### Куда вставляется текст
- При хоткее: в то приложение, которое было в фокусе когда ты нажал хоткей
- При кнопке в окне: в последнее приложение, которое ты использовал до Voice2

---

## Архитектура

### Файлы

```
Sources/Voice2/
  Voice2App.swift    — @main, MenuBarExtra
  AppDelegate.swift  — жизненный цикл, главное окно, иконка Dock
  AppState.swift     — главный state machine (@MainActor), оркестрирует всё
  Recorder.swift     — запись аудио (AVAudioRecorder)
  Whisper.swift      — запуск whisper-cli subprocess
  Injector.swift     — вставка текста (clipboard + Cmd+V)
  Hotkey.swift       — глобальный хоткей (CGEventTap)
  Pill.swift         — floating overlay (NSPanel + SwiftUI)
  ContentView.swift  — главное окно (SwiftUI + NSViewRepresentable кнопка)
  Info.plist         — bundle ID: com.voice2.local
```

### Поток данных

```
[User] зажал Right Option / кнопку
       ↓
[Hotkey.onDown] / [HoldView.mouseDown]
       ↓
[AppState.startRecording()]
  → проверяет micOK + isLimitReached
  → Recorder.start() → AVAudioRecorder → /tmp/UUID.wav
  → Pill.shared.show()
  → запускает таймер (+1 сек)
       ↓
[User] отпустил
       ↓
[AppState.stopRecording()]
  → Recorder.stop() → возвращает URL(wav)
  → Pill.showTranscribing()
  → Task.detached → Whisper.run(wav)
       ↓
[Whisper.run()] (фоновый поток)
  → Process() → whisper-cli -m model.bin -f file.wav -l ru --no-timestamps -np
  → парсит stdout, убирает [BLANK_AUDIO] и [_BEG_] метки
  → возвращает String (или nil если тишина)
       ↓
[MainActor] получает текст
  → UsageTracker.addWords(text) → счётчик слов
  → Pill.showResult(text) → прячется через 2.5с
  → AppState.injectText()
     → если Voice2 в фокусе: target.activate() + 0.5с → Injector.paste()
     → если target в фокусе: Injector.paste() сразу
       ↓
[Injector.paste()]
  → NSPasteboard.setString(text)  ← запись 1
  → asyncAfter(0.05с):
       → NSPasteboard.setString(text)  ← запись 2 (защита от race)
       → CGEvent Cmd+V (down + up)
```

### Ключевые решения

**AVAudioRecorder вместо AVAudioEngine**
AVAudioEngine требует ручного управления форматом WAV (non-interleaved PCM не поддерживается WAV контейнером).
AVAudioRecorder сам конвертирует в нужный формат — никаких ошибок формата.
Параметры: 16kHz, mono, 16-bit PCM — оптимально для Whisper.

**NSView.mouseDown/mouseUp вместо SwiftUI DragGesture**
SwiftUI `Button + simultaneousGesture(DragGesture)` ненадёжен на macOS —
Button перехватывает события до DragGesture. Решение: `NSViewRepresentable`
с `HoldView: NSView`, который переопределяет `mouseDown`/`mouseUp` напрямую.
Гарантированно работает по спецификации AppKit.

**Clipboard + Cmd+V вместо AX API**
AX (Accessibility API) `kAXSelectedTextAttribute` требует разрешения и
работает только в стандартных NSTextField-based полях. Clipboard + Cmd+V
работает в любом приложении без ограничений — Notion, VS Code, браузер, Telegram.

**CGEventTap на main RunLoop**
Глобальный хоткей через `CGEvent.tapCreate(.cgSessionEventTap)`.
Callback добавлен на `CFRunLoopGetMain()` → выполняется в main thread.
Callbacks вызываются через `Task { @MainActor in }` для корректной изоляции.

**Двойная запись в clipboard перед Cmd+V**
`Injector.paste()` пишет текст в NSPasteboard дважды: сразу и через 50мс перед
самим Cmd+V. Это защищает от race condition, когда приложение-цель или система
успевают перезаписать clipboard в момент `target.activate()`.
Без этого в приложениях типа VS Code / Notion иногда вставлялся предыдущий clipboard.

**whisper-cli флаг `-np` (--no-prints) вместо `-nt`**
`-nt` (--no-timestamps) убирает временные метки из текста.
`-np` (--no-prints) убирает весь служебный вывод кроме результата — меньше шума в stderr.
Оба флага не нужны одновременно: `-np` включает в себя поведение `-nt` по выводу.
Текущие аргументы: `--no-timestamps -np`.

---

## Технические детали

### whisper-cli
- Путь в bundle: `Contents/Resources/whisper-cli`
- Модель: `Contents/Resources/ggml-small.bin` (465 MB, ~80 WER% на русском)
- Компилирован статически (`-DBUILD_SHARED_LIBS=OFF`) — не требует dylib
- Зависимости: только системные (Accelerate, Metal, Foundation)
- Аргументы: `-m model -f audio.wav -l ru --no-timestamps -nt`

### Разрешения macOS (TCC)
| Разрешение | Для чего | Как проверить |
|---|---|---|
| Microphone | AVAudioRecorder | `AVAudioApplication.shared.recordPermission` |
| Accessibility | AX API (не используется, но полезен) | `AXIsProcessTrusted()` |
| Input Monitoring | CGEventTap | `CGEvent.tapCreate` возвращает nil если нет |

TCC привязан к bundle path `/Applications/Voice2.app`. После каждой переустановки
на новый путь разрешения нужно выдавать заново.

### Codesign
```bash
# Ad-hoc подпись (без Apple Developer аккаунта)
codesign --force --sign - --entitlements Voice2.entitlements Voice2.app
```

Entitlements (`Voice2.entitlements`):
- `com.apple.security.device.audio-input` — mic
- `com.apple.security.device.input-monitoring` — CGEventTap
- `com.apple.security.app-sandbox = false` — обязательно для Accessibility API

---

## Что добавить дальше (backlog)

- [ ] **Выбор языка** — сейчас всегда `ru`, нужен Picker (en/ru/de/fr)
- [ ] **Gemini/Claude форматирование** — расстановка знаков препинания через API
- [ ] **История диктовок** — список последних 30 транскриптов с копированием
- [ ] **VAD (Voice Activity Detection)** — автостоп при тишине вместо ручного отпускания
- [ ] **Настройка хоткея** — сейчас хардкод Right Option, нужен Picker
- [ ] **ggml-base модель** — 142 MB вместо 465 MB, чуть хуже качество
- [ ] **Звуковой сигнал** — beep при старте/стопе записи
- [ ] **Авто-старт** — LaunchAgent для запуска при входе в систему

---

## Структура проекта

```
my-tools/voice2/
  build.sh              — сборка + установка (запускай после изменений)
  Package.swift         — Swift Package Manager
  Voice2.entitlements   — разрешения приложения
  VOICE2.md             — этот файл
  Sources/Voice2/       — весь исходный код (898 строк)
  Voice2.app/           — локальная сборка (gitignore)
  .build/               — кэш компилятора (gitignore)
```

Зависимости: только macOS SDK. Не нужны CocoaPods, SPM пакеты, Homebrew.

---

## Известные баги и решения

### Вставляется чужой текст / строка с `[20:32:38] ✅`
**Симптом:** в поле ввода появляется строка лога приложения вида
`[20:32:38] ✅ "Редактор субтитров..."  [5/2000 слов]` вместо произнесённого текста.

**Причина A — фоновый звук:** Whisper слышит ТВ, видео, колонки и транскрибирует их.
Voice2 не отличает голос пользователя от фонового звука. Решение: диктуй в тишине
или ближе к микрофону.

**Причина B — race condition clipboard:** между `target.activate()` и `Cmd+V`
приложение-цель успевало перезаписать clipboard → вставлялся предыдущий буфер.
**Починено в текущей версии:** двойная запись в clipboard (сразу + 50мс перед Cmd+V),
задержка активации увеличена с 0.3с до 0.5с.

### Диктовка работала, потом перестала
**Симптом:** бот молчит на хоткей, кнопка не реагирует.
Проверь: разрешения могут слететь после обновления macOS или пересборки в новый путь.
Открой Voice2 → нажми "Проверить разрешения" → если что-то `✗`, выдай заново.

---

## Отладка

### Ничего не происходит при нажатии кнопки
1. Открой лог (внизу окна)
2. Нажми "Проверить разрешения"
3. Убедись что `mic:✓` — если нет, нажми "Выдать доступ к микрофону"
4. Если `mic:✓` но кнопка молчит — смотри строку `❌` в логе

### Текст не вставляется
1. Переключись в текстовый редактор ДО того как нажимаешь кнопку
2. После диктовки Voice2 автоматически переключится туда и вставит
3. Если всё равно не вставляется — попробуй в TextEdit (самый совместимый)

### Хоткей не работает
1. В логе должно быть `hotkey:✓`
2. Если `hotkey:✗` → Настройки → Мониторинг ввода → добавь Voice2 → нажми "Готово — перезапустить хоткей"
3. После добавления в Мониторинг ввода иногда нужен перезапуск приложения

### Пересборка после изменения кода
```bash
cd ~/Desktop/Claude/my-tools/voice2
bash build.sh
```
Автоматически убивает старый процесс, компилирует, устанавливает, запускает.

---

## Bundle ID и версии

| Параметр | Значение |
|---|---|
| Bundle ID | `com.voice2.local` |
| Версия | 2.0 |
| Min macOS | 14.0 (Sonoma) |
| Архитектура | arm64 (Apple Silicon) |
| Установка | `/Applications/Voice2.app` |
