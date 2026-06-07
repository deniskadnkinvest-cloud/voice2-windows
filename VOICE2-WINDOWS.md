# Voice2 — Windows-версия (документ-установщик)

Локальное приложение для голосового ввода на Windows 10/11. Аналог Wispr Flow / Aqua Voice, без облака, без подписки.
Whisper работает прямо на устройстве через CPU (DirectML опционально на iGPU/dGPU).

Парный документ к [VOICE2.md](VOICE2.md) (macOS-версия). Этот файл — для Windows: что ставится, какие кнопки, как пользоваться, как пересобирать.

---

## Что умеет (то же, что на Mac)

| Функция | Как работает |
|---|---|
| Диктовка | Зажал кнопку → говоришь → отпустил → текст вставлен |
| Глобальный хоткей | **Right Ctrl** (правый Control) — работает в любом приложении |
| Hands-free режим | Двойной тап Right Ctrl → пишет, пока не тапнешь снова |
| Floating overlay | Пилюля внизу экрана: запись / распознаю / готово |
| Вставка текста | Clipboard + Ctrl+V — работает везде (Word, Notion, Telegram, Chrome…) |
| Локальное распознавание | `whisper.exe` bundled, модель `ggml-base.bin` (142 MB) |
| Иконка в трее | Mic иконка, меняется на красный кружок во время записи |
| Автозапуск | Опционально: ярлык в `shell:startup` |

---

## Выбор хоткея — почему Right Ctrl, а не Right Alt

Ключевое отличие от macOS-сборки. На Mac мы взяли Right Option, и это было правильно: Right Option там — «чистый» модификатор, нигде не задействован системой. На Windows тот же путь (Right Alt) ломается, потому что **Right Alt = AltGr** в большинстве раскладок (включая RU-русская и EN-INTL) и используется для ввода спецсимволов.

### Рассмотренные варианты

| Кнопка | Плюсы | Минусы | Вердикт |
|---|---|---|---|
| **Right Ctrl** | Есть на 100% клавиатур. Системой не используется как самостоятельная кнопка. Зеркалит Mac-поведение (правая модификаторная) | Нет | ⭐ **Основной** |
| Caps Lock | Большая, легко нащупать вслепую. Wispr Flow юзает её | Многие ремапят в Ctrl (Vim/Emacs), теряется регистр | Альтернатива в настройках |
| Right Alt | Симметрично Mac, привычно | Конфликт с AltGr на RU/EN-INTL раскладках — будет хватать события при наборе `@`, `№`, `™` и пр. | Альтернатива (только для EN-US раскладки) |
| Right Shift | Есть везде | Постоянно используется при наборе — слишком много ложных срабатываний | Нет |
| F8 / F9 / F12 | Свободны на десктопе | F8 = boot menu при запуске; F12 = devtools в браузере; зависит от приложения | Рискованно |
| Pause/Break | Реально свободна | Нет на 60–80% современных ноутбуков | Нет |
| Insert | Свободна на десктопе | Нет на компактных клавиатурах; в Word — toggle вставки | Нет |
| Scroll Lock | Реально свободна | Нет на ноутбуках | Нет |
| Right Win | Нет конфликтов | Нет на 90% ноутбуков | Нет |
| Win+H (системный voice typing) | Нативный Windows | Нельзя переопределить, открывает встроенный диктор Microsoft | Не используем |

### Итоговая логика

| Слот | Кнопка по-умолчанию | Настраивается |
|---|---|---|
| Push-to-talk | **Right Ctrl** (зажать → говорить → отпустить) | Да (Right Ctrl / Caps Lock / Right Alt / F-keys) |
| Hands-free | **Right Ctrl × 2** (двойной тап) | Да |
| Открыть окно из трея | Двойной клик по иконке в трее | — |
| Аварийная остановка записи | **Esc** | Нет (хардкод) |
| Кнопка в окне приложения | Зажми и говори (мышь) | — |

Дефолт можно поменять в Настройках → Хоткей: выпадающий список из 6 вариантов.

---

## Быстрый старт

### 1. Установка (для пользователя)

Скачать `Voice2-Setup-X.Y.Z.exe` с релизов → запустить → два клика «Далее».

Что делает мастер (Inno Setup):
- Распаковывает в `%LocalAppData%\Voice2\` (без админ-прав, не требует UAC)
- Регистрирует `voice2://` URL-схему (для magic-link логина)
- Кладёт `whisper.exe` + `ggml-base.bin` рядом с `Voice2.exe`
- Создаёт ярлыки: Пуск, Рабочий стол (галочка), Автозапуск (галочка)
- При первом запуске Windows покажет диалог разрешения микрофона — нажми «Да»

### 2. Сборка из исходников (для разработчика)

Требования:
- Windows 10/11 x64
- .NET 8 SDK (`winget install Microsoft.DotNet.SDK.8`)
- Visual Studio Build Tools 2022 с MSVC (для пересборки whisper.cpp; если используешь предсобранный — не нужно)
- Inno Setup 6 (`winget install JRSoftware.InnoSetup`)

```powershell
cd $env:USERPROFILE\Desktop\Claude\my-tools\voice2
.\build.ps1
```

Скрипт:
- Собирает Voice2.exe через `dotnet publish -c Release -r win-x64 --self-contained`
- Копирует `whisper.exe` + `ggml-base.bin` в `dist\`
- Опционально подписывает (если установлен EV-сертификат в Cert:\CurrentUser\My)
- Запаковывает в `Voice2-Setup-X.Y.Z.exe` через `iscc.exe Voice2.iss`
- Кладёт результат в `dist\Voice2-Setup-X.Y.Z.exe`

### 3. Проверка после установки

В окне Voice2 внизу должна быть строка:
```
Perms  mic:✓  hotkey:✓  inject:✓
```

Если `hotkey:✗` — другое приложение уже забрало Right Ctrl. Решение: открыть Настройки → Хоткей → переключить на Caps Lock.

---

## Как пользоваться

### Кнопка в окне
- Зажми «🎙 Зажми и говори» (левая кнопка мыши)
- Говори
- Отпусти → текст вставляется в последнее активное приложение

### Хоткей (главный кейс)
- **Right Ctrl** зажал → говоришь → отпустил
- **Right Ctrl × 2** (двойной тап в течение 400 мс) → hands-free, диктуй пока не тапнешь Right Ctrl снова
- Во время записи в правом нижнем углу — пилюля overlay с уровнем громкости

### Куда вставляется текст
- При хоткее: в то окно, которое было в фокусе на момент нажатия (Voice2 запоминает foreground window)
- При кнопке в окне: в последнее окно ДО открытия Voice2

---

## Архитектура

### Стек

```
[UI]     WPF + .NET 8 (self-contained, single-file publish)
[Audio]  WASAPI capture через NAudio
[Hotkey] RegisterHotKey Win32 API + LowLevelKeyboardHook (для двойного тапа)
[STT]    whisper.cpp скомпилирован под MSVC, CPU-only по-умолчанию
[Inject] SendInput Ctrl+V + Clipboard (System.Windows.Forms.Clipboard)
[Tray]   NotifyIcon + WPF ContextMenu
[Overlay] borderless top-most WPF Window с прозрачным фоном
```

### Файлы

```
src/
  App.xaml / App.xaml.cs        — WPF App, single-instance mutex
  MainWindow.xaml / .cs         — главное окно (логи, кнопка, разрешения)
  AppState.cs                   — главный state machine, оркестратор
  Recorder.cs                   — WASAPI capture → wav в %TEMP%
  Whisper.cs                    — Process(whisper.exe) subprocess
  Injector.cs                   — clipboard + SendInput Ctrl+V
  HotkeyManager.cs              — RegisterHotKey + Hook на двойной тап
  PillWindow.xaml / .cs         — floating overlay
  TrayIcon.cs                   — NotifyIcon + меню
  Settings.cs                   — JSON в %AppData%\Voice2\settings.json
  Updater.cs                    — Squirrel.Windows / собственный
  Voice2.csproj                 — .NET 8, OutputType=WinExe, SelfContained=true
installer/
  Voice2.iss                    — Inno Setup конфиг
  License.rtf                   — лицензия (русская)
resources/
  whisper.exe                   — предсобранный whisper.cpp (~3 MB)
  ggml-base.bin                 — модель Whisper (~142 MB)
  voice2.ico                    — иконка приложения
build.ps1                       — сборка + упаковка
```

### Поток данных

```
[User] зажал Right Ctrl
       ↓
[HotkeyManager.OnKeyDown(VK_RCONTROL)]
       ↓
[AppState.StartRecording()]
  → проверяет MicOK
  → Recorder.Start() → WasapiCapture → %TEMP%\voice2-<guid>.wav
  → PillWindow.Show()
  → таймер +1 сек
       ↓
[User] отпустил
       ↓
[AppState.StopRecording()]
  → Recorder.Stop() → возвращает путь к .wav
  → PillWindow.ShowTranscribing()
  → Task.Run(() => Whisper.RunAsync(wavPath))
       ↓
[Whisper.RunAsync()] (ThreadPool)
  → Process(whisper.exe -m ggml-base.bin -f file.wav -l ru -nt --no-timestamps)
  → парсит stdout, фильтрует [BLANK_AUDIO]
  → возвращает string
       ↓
[Dispatcher] получает текст
  → PillWindow.ShowResult(text) → закрывается через 2.5 с
  → AppState.InjectText()
     → SetForegroundWindow(savedTargetHwnd)
     → Injector.Paste(text)
       ↓
[Injector.Paste()]
  → сохраняет текущий clipboard
  → Clipboard.SetText(text)
  → SendInput(VK_CONTROL down, V down, V up, VK_CONTROL up)
  → через 600 мс восстанавливает clipboard
```

---

## Ключевые решения (отличия от Mac)

**WASAPI вместо AVAudioRecorder**
WASAPI Capture работает напрямую с PCM 16kHz mono — не нужен ресемплинг. NAudio оборачивает в удобный API. Файл сразу пишется как WAV, готовый для Whisper.

**RegisterHotKey + LowLevelKeyboardHook**
`RegisterHotKey` работает для комбинаций (Ctrl+Shift+X), но НЕ ловит одиночный Right Ctrl. Поэтому ловим Right Ctrl через `SetWindowsHookEx(WH_KEYBOARD_LL)` — глобальный low-level хук, работает даже когда окно Voice2 не в фокусе. Двойной тап определяется в самом хуке: два события Down с Up между ними и интервалом ≤ 400 мс.

**SendInput вместо CGEvent**
Win32 эквивалент: `SendInput` с INPUT_KEYBOARD структурой. Шлём 4 события: Ctrl Down, V Down, V Up, Ctrl Up. Между Down и Up — никаких задержек, Windows обрабатывает мгновенно.

**Single-instance через Mutex**
Чтобы не запустилось два Voice2 одновременно (двойной клик по ярлыку) — глобальный `Mutex("Global\\Voice2-SingleInstance")` на старте. Если уже захвачен — посылаем существующему окну `WM_SHOWWINDOW` и выходим.

**Self-contained .NET publish**
`dotnet publish -c Release -r win-x64 --self-contained -p:PublishSingleFile=true` — даёт один `Voice2.exe` ~90 MB, который не требует установленного .NET runtime у пользователя. Кладём рядом `whisper.exe` + `ggml-base.bin`.

---

## Разрешения Windows

Windows проще macOS — нет TCC, но есть свои нюансы.

| Разрешение | Когда запрашивается | Что делать |
|---|---|---|
| Микрофон | При первом `WasapiCapture.StartRecording()` | Windows покажет диалог в Settings → Privacy → Microphone. Принять. |
| Клавиатурный хук | Не запрашивается, работает сразу | На enterprise-машинах GPO может блокировать `SetWindowsHookEx` — тогда хоткей не поднимется. Лог: `hotkey:✗`. |
| SmartScreen | При первом запуске `.exe` без подписи | «Подробнее → Выполнить в любом случае». С EV-сертификатом этого нет. |
| Defender | На неподписанной сборке может карантинить | Добавить `%LocalAppData%\Voice2\` в исключения. |
| Автозапуск | Опция в инсталляторе | Создаётся `.lnk` в `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\` |

---

## Установщик — Inno Setup

`installer/Voice2.iss` (скелет):

```pascal
[Setup]
AppName=Voice2
AppVersion=2.1.0
DefaultDirName={localappdata}\Voice2
DefaultGroupName=Voice2
OutputBaseFilename=Voice2-Setup-2.1.0
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
LicenseFile=License.rtf
WizardStyle=modern
ShowLanguageDialog=auto

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; GroupDescription: "Дополнительно:"
Name: "autostart"; Description: "Запускать Voice2 при входе в систему"; GroupDescription: "Дополнительно:"

[Files]
Source: "..\dist\Voice2.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\resources\whisper.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\resources\ggml-base.bin"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\resources\voice2.ico"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Voice2"; Filename: "{app}\Voice2.exe"; IconFilename: "{app}\voice2.ico"
Name: "{group}\Удалить Voice2"; Filename: "{uninstallexe}"
Name: "{commondesktop}\Voice2"; Filename: "{app}\Voice2.exe"; IconFilename: "{app}\voice2.ico"; Tasks: desktopicon
Name: "{userstartup}\Voice2"; Filename: "{app}\Voice2.exe"; Parameters: "--minimized"; Tasks: autostart

[Run]
Filename: "{app}\Voice2.exe"; Description: "Запустить Voice2"; Flags: postinstall nowait skipifsilent

[Registry]
Root: HKCU; Subkey: "Software\Classes\voice2"; ValueType: string; ValueName: ""; ValueData: "URL:Voice2 Magic Link"
Root: HKCU; Subkey: "Software\Classes\voice2"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\voice2\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Voice2.exe"" ""%1"""
```

Подпись через `signtool.exe`:
```powershell
signtool sign /tr http://timestamp.digicert.com /td sha256 /fd sha256 /a Voice2-Setup-2.1.0.exe
```

---

## Авто-обновления

При запуске Voice2 ходит на `https://api.voice2.ru/version`:
```json
{ "latest": "2.1.4", "url": "https://cdn.voice2.ru/Voice2-Setup-2.1.4.exe", "min_supported": "2.0.0" }
```

Если `latest > current` — качает в `%LocalAppData%\Voice2\update\` в фоне. При следующем запуске Voice2 запускает downloaded `.exe` с флагом `/SILENT` и сам выходит. Inno Setup ставит поверх, перезапускает Voice2.

Альтернатива: Squirrel.Windows (как Slack/Discord) — готовая либа, ~200 строк интеграции.

---

## Системные требования

| Параметр | Минимум | Рекомендуется |
|---|---|---|
| ОС | Windows 10 22H2 x64 | Windows 11 x64 |
| RAM | 4 GB | 8 GB+ |
| CPU | Intel Haswell / AMD Ryzen 1xxx (2014+) | Intel 10gen+ / AMD Ryzen 5xxx+ |
| Свободно на диске | 500 MB | 1 GB |
| Аудио | Любой микрофон с поддержкой WASAPI | — |

Не поддерживается: Win 7/8.1, Win Server, ARM64 (вторая волна — пересборка whisper.cpp под ARM).

---

## Bundle ID и версии

| Параметр | Значение |
|---|---|
| AppId (Inno Setup) | `{{C9F2A1B3-7E4D-4F8C-B6A2-1234567890AB}` |
| Версия | 2.1.0 (Windows-первая) |
| Min Windows | 10 22H2 (Build 19045+) |
| Архитектура | x64 (ARM64 — Q3 2026) |
| Установка | `%LocalAppData%\Voice2\` |
| Настройки | `%AppData%\Voice2\settings.json` |
| Логи | `%AppData%\Voice2\logs\voice2-YYYY-MM-DD.log` |
| Кэш аудио | `%TEMP%\voice2-*.wav` (удаляется через 5 мин) |

---

## Отладка

### Хоткей не срабатывает
1. Открой окно → должно быть `hotkey:✓`
2. Если `hotkey:✗` — другое приложение перехватило Right Ctrl (часто PowerToys, AutoHotkey-скрипты). Закрой их или поменяй хоткей в Настройках.
3. В корпоративной среде проверь GPO: «Disable Windows Hooks» = Disabled.

### Текст не вставляется
1. Переключись в редактор ДО нажатия хоткея.
2. Voice2 запоминает foreground window — после диктовки активирует его и шлёт Ctrl+V.
3. Если не работает — проверь, не блокирует ли антивирус `SendInput`. В логе будет ошибка `SendInput failed: <код>`.

### SmartScreen ругается на .exe
Это нормально, пока не подписали EV-сертификатом. «Подробнее → Выполнить в любом случае». После EV-подписи окно исчезает.

### Whisper медленный
- На i3-7xxx / Celeron расшифровка 10 сек аудио = 8–12 сек. Решение: поменять модель на `ggml-tiny.bin` (75 MB, быстрее в 3 раза, чуть хуже качество)
- На Intel iGPU UHD 6xx+ / любой dGPU — включи DirectML в Настройках → Whisper Backend → DirectML. Ускорение в 4–8 раз.

### Логи
`%AppData%\Voice2\logs\voice2-2026-05-20.log` — текстовый лог всех событий с таймстампами.

---

## Структура проекта (целевая)

```
my-tools/voice2/
  VOICE2.md                  — Mac-документ
  VOICE2-WINDOWS.md          — этот файл
  WINDOWS-AND-PRICING.md     — план Windows + тарификация
  build.sh                   — сборка Mac
  build.ps1                  — сборка Windows
  Sources/Voice2/            — Swift код (Mac)
  src-win/                   — C# код (Windows)         ← создаётся в Неделю 1
  installer/Voice2.iss       — Inno Setup конфиг        ← создаётся в Неделю 3
  resources/                 — whisper.exe + модель + иконка
  dist/                      — итоговый Voice2-Setup-*.exe
```

---

## Что делает `build.ps1`

См. файл `build.ps1` рядом. Кратко:
1. Проверяет .NET 8 SDK и Inno Setup в PATH
2. `dotnet publish` в `dist\Voice2.exe`
3. Копирует `whisper.exe`, `ggml-base.bin`, иконку
4. Подписывает (если есть сертификат)
5. `iscc.exe Voice2.iss` → собирает `Voice2-Setup-X.Y.Z.exe`
6. Кладёт в `dist\` и опционально открывает папку

Запуск:
```powershell
cd $env:USERPROFILE\Desktop\Claude\my-tools\voice2
.\build.ps1
```

---

*Документ синхронизирован с [VOICE2.md](VOICE2.md). При обновлении одного — синхронизировать второй.*
