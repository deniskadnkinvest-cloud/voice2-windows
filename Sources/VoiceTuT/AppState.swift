import AppKit
import AVFoundation
import Combine

struct LogEntry: Identifiable {
    let id = UUID()
    let text: String
}

struct HistoryEntry: Identifiable, Codable {
    var id = UUID()
    let text: String
    let timestamp: Date
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var isRecording = false
    @Published var micOK = false
    @Published var axOK = false
    @Published var hotkeyOK = false
    @Published var logLines: [LogEntry] = []
    @Published var history: [HistoryEntry] = []
    @Published var inFlightCount: Int = 0  // pending whisper/polish jobs in background

    private let historyKey = "v2.history"
    private let historyLimit = 30

    // Changing this live-updates the hotkey filter — no restart needed
    @Published var hotkeyKey: HotkeyKey = .fn {
        didSet {
            hotkey.selectedKey = hotkeyKey
            UserDefaults.standard.set(hotkeyKey.rawValue, forKey: "v2.hotkeyKey")
        }
    }

    private let recorder = Recorder()
    private let hotkey   = Hotkey()
    private var timer: Timer?
    private var seconds = 0
    private var recordingMaxPeak: Float = -160

    // Generation counter: identifies each recording session.
    // Used to decide injection: if a newer recording has started by the time
    // this one finishes, we don't inject (active app context shifted) — but
    // we DO still complete processing and add to history. Previously this was
    // used to drop stale results entirely; that lost work on accidental double-tap.
    private var generation = 0

    private var prevApp: NSRunningApplication?
    private var targetApp: NSRunningApplication?
    private let myBundle = Bundle.main.bundleIdentifier ?? "com.voicetut.local"

    // Captured at recording-start: Shift held = skip LLM polish for this dictation.
    private var shiftHeldAtStart = false

    private init() {
        // One-time миграция с com.voice2.local → com.voicetut.local после ренейминга.
        // Должна сработать ДО loadHistory() / Vocabulary.shared / Polisher.loadSettings(),
        // иначе все они увидят пустые значения и перезапишут пустотой.
        Self.migrateLegacyUserDefaults()

        // Wire log callback before start() so early messages reach the UI
        hotkey.logCallback = { [weak self] msg in
            Task { @MainActor [weak self] in self?.log(msg) }
        }

        hotkey.onDown = { [weak self] in
            Task { @MainActor [weak self] in
                self?.log("🔑 onDown → startRecording()")
                self?.startRecording()
            }
        }
        hotkey.onUp = { [weak self] in
            Task { @MainActor [weak self] in
                self?.log("🔑 onUp → stopRecording()")
                self?.stopRecording()
            }
        }

        trackFrontmostApp()

        loadHistory()

        // Synchronous checks — run before SwiftUI renders the first frame
        // so badges are correct on launch without any flicker.
        micOK    = AVAudioApplication.shared.recordPermission == .granted
        axOK     = AXIsProcessTrusted()
        // Restore saved key (defaults to .fn on first launch)
        if let s = UserDefaults.standard.string(forKey: "v2.hotkeyKey"),
           let k = HotkeyKey(rawValue: s) { hotkeyKey = k }
        hotkey.selectedKey = hotkeyKey  // didSet skips during init — sync manually
        hotkeyOK = hotkey.start()
        log("Perms  mic:\(micOK ? "✓" : "✗")  ax:\(axOK ? "✓" : "✗")  hotkey:\(hotkeyOK ? "✓" : "✗")")

        // Poll every 2 s to pick up permissions granted after launch.
        // refreshPermissions() only logs when something actually changes.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshPermissions()
            }
        }

        // Mirror NetworkMonitor → Pill.offline so the cloud icon reflects connectivity.
        let net = NetworkMonitor.shared
        Pill.shared.setOffline(!net.isOnline)
        netObserver = net.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self != nil else { return }
                Pill.shared.setOffline(!NetworkMonitor.shared.isOnline)
            }
        }
    }

    private var netObserver: AnyCancellable?

    // MARK: - Recording

    func diagnoseHotkey() {
        log("🔬 Диагностика: нажми хоткей (\(hotkeyKey.rawValue)) — жду 10 событий")
        hotkey.diagRemaining = 10
    }

    func startRecording() {
        log("▶ startRecording() вызван (mic=\(micOK) isRec=\(isRecording) limit=\(UsageTracker.shared.isLimitReached))")
        guard !isRecording else { return }
        guard micOK else {
            Pill.shared.showError("Нет доступа к микрофону")
            log("❌ Нет доступа к микрофону")
            return
        }
        guard !UsageTracker.shared.isLimitReached else {
            Pill.shared.showError("Лимит 2000 слов исчерпан")
            log("🔒 Лимит free-плана исчерпан — нужна оплата")
            return
        }

        targetApp = prevApp
        generation += 1  // invalidate any in-flight whisper task
        recordingMaxPeak = -160

        // Snapshot Shift state at start — Shift held = user wants this dictation
        // to stay 100% local (no OpenAI round-trip).
        shiftHeldAtStart = NSEvent.modifierFlags.contains(.shift)
        let polishOn = Polisher.loadSettings().enabled
        let willSkip = shiftHeldAtStart || !NetworkMonitor.shared.isOnline || !polishOn
        Pill.shared.setWillSkipPolish(willSkip)
        if shiftHeldAtStart { log("⇧ Shift зажат — полировка пропущена для этой диктовки") }

        let (devID, devLabel) = resolveInputDevice()
        guard recorder.start(deviceID: devID) else {
            Pill.shared.showError("Ошибка аудио")
            log("❌ Не удалось запустить запись")
            return
        }
        log("🎙 Источник: \(devLabel)")

        isRecording = true
        seconds = 0
        Pill.shared.show()
        log("▶ Запись началась")

        // Таймер в .common-режиме + tolerance: счётчик секунд не замирает, даже когда
        // главный run-loop уходит в tracking-режим (перетаскивание пилюли, меню и т.п.),
        // и не штрафует CPU за идеальную точность.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.seconds += 1
                Pill.shared.update(seconds: self.seconds)
                // Track peak over entire recording so the silence check uses the max, not the instantaneous level at stop time
                if let p = self.recorder.peakPower(), p > self.recordingMaxPeak {
                    self.recordingMaxPeak = p
                }
            }
        }
        t.tolerance = 0.15
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // Minimum peak level (dB) to send to Whisper.
    // Below this threshold the recording is treated as silence — prevents hallucinations.
    private let silenceThreshold: Float = -35

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        timer?.invalidate()
        timer = nil

        // Take one last sample, then use the max across the entire recording
        if let p = recorder.peakPower(), p > recordingMaxPeak { recordingMaxPeak = p }
        let peak: Float? = recordingMaxPeak > -150 ? recordingMaxPeak : nil
        guard let wav = recorder.stop() else {
            Pill.shared.hide()
            return
        }

        if let peak, peak < silenceThreshold {
            log("🤫 Тишина (пик \(Int(peak)) dB) — пропускаю")
            Pill.shared.hide()
            try? FileManager.default.removeItem(at: wav)
            return
        }

        log("⏸ Остановлено (пик \(peak.map { "\(Int($0)) dB" } ?? "?"), запускаю whisper…")
        Pill.shared.showTranscribing()

        let target = targetApp
        let gen = self.generation  // captured — identifies this specific recording

        // Snapshot vocabulary + polisher settings on the main actor before detaching.
        let whisperPrompt = Vocabulary.shared.whisperPrompt()
        let canonicalTerms = Vocabulary.shared.terms.map { $0.canonical }
        let polishSettings = Polisher.loadSettings()
        let skipPolish = shiftHeldAtStart || !NetworkMonitor.shared.isOnline

        // Track this job in the in-flight queue. The badge shows how many
        // recordings are still pending insertion.
        self.inFlightCount += 1
        Pill.shared.setQueueCount(self.inFlightCount)

        Task.detached(priority: .userInitiated) {
            // 1. Whisper — локально, ~1–2 c на M-series.
            let raw = await Whisper.run(wav: wav, initialPrompt: whisperPrompt)

            // 2. Алиасы словаря — детерминированно и быстро. Это «быстрый» текст,
            //    который можно вставить немедленно, не дожидаясь облака.
            var fast: String? = nil
            if let txt = raw {
                fast = await MainActor.run { Vocabulary.shared.applyAliases(to: txt) }
            }
            guard let fastText = fast,
                  !fastText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await MainActor.run {
                    self.inFlightCount = max(0, self.inFlightCount - 1)
                    Pill.shared.setQueueCount(self.inFlightCount)
                    self.log("⚠️ Пустой результат (тишина или ошибка whisper)")
                    if self.generation == gen && self.inFlightCount == 0 { Pill.shared.hide() }
                }
                return
            }

            // 3. Нужна ли полировка?
            let reason = self.polishDecisionReason(text: fastText, settings: polishSettings, skip: skipPolish)
            await MainActor.run { self.log(reason.0) }

            guard reason.1 else {
                // Без полировки — вставляем быстрый текст сразу.
                await self.finishJob(text: fastText, gen: gen, target: target, candidates: [])
                return
            }

            // 4. Полировка идёт в фоне и НЕ блокирует вставку дольше дедлайна:
            //    • облако ответило быстро → вставляем уже отполированный текст;
            //    • сеть тормозит → вставляем быстрый текст, а полировка дотянется
            //      в фоне и лишь обновит запись истории.
            //    Это убирает зависания на 20–30 c, когда api.openai.com недоступен.
            await MainActor.run { Pill.shared.setCloudInFlight(true) }
            let polishTask = Task.detached(priority: .userInitiated) {
                await Polisher.polish(text: fastText, terms: canonicalTerms, settings: polishSettings)
            }

            if let result = await self.awaitWithinDeadline(polishTask, seconds: self.polishInjectDeadline) {
                // Облако успело — вставляем отполированный текст.
                await MainActor.run { Pill.shared.setCloudInFlight(false) }
                await self.finishJob(text: result.text, gen: gen, target: target, candidates: result.candidates)
            } else {
                // Дедлайн вышел — вставляем быстрый текст немедленно.
                let entryID = await self.finishJob(text: fastText, gen: gen, target: target, candidates: [])
                await MainActor.run {
                    Pill.shared.setCloudInFlight(false)
                    self.log("⚡️ Облако тормозит — вставил быстрый текст, полировка догрузится в историю")
                }
                // Фоном: дождаться полировки и обновить запись истории.
                Task.detached {
                    let result = await polishTask.value
                    await MainActor.run {
                        for c in result.candidates {
                            Vocabulary.shared.recordCandidate(canonical: c.canonical, raw: c.raw)
                        }
                        let polished = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let fastClean = fastText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let entryID, !polished.isEmpty, polished != fastClean {
                            self.updateHistoryText(id: entryID, to: polished)
                            self.log("✨ Полировка догрузилась — история обновлена")
                        }
                    }
                }
            }
        }
    }

    // Дедлайн вставки: сколько максимум ждать облачную полировку, прежде чем
    // вставить быстрый (whisper+словарь) текст. Облако обычно отвечает <2 c;
    // если нет — пользователя не держим.
    private let polishInjectDeadline: Double = 2.0

    /// Ждёт результат задачи не дольше `seconds`. Вернёт результат, если успел,
    /// иначе nil. ВАЖНО: переданная задача НЕ отменяется и НЕ дожидается —
    /// при таймауте она продолжает работу в фоне (полировка дотянется и обновит
    /// историю). Гонщики — неструктурированные Task, поэтому функция возвращается
    /// сразу, как только сработал первый (а не дожидается обоих, как у TaskGroup).
    nonisolated private func awaitWithinDeadline(
        _ task: Task<Polisher.Result, Never>, seconds: Double
    ) async -> Polisher.Result? {
        let gate = ResumeOnce()
        return await withCheckedContinuation { (cont: CheckedContinuation<Polisher.Result?, Never>) in
            // Наблюдатель: дождаться полировки.
            Task {
                let r = await task.value
                if await gate.claim() { cont.resume(returning: r) }
            }
            // Таймер дедлайна.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if await gate.claim() { cont.resume(returning: nil) }
            }
        }
    }

    /// Завершение задачи на главном акторе: учёт очереди, история, авто-вставка
    /// в активное приложение (только если запись всё ещё самая свежая).
    /// Возвращает id созданной записи истории — чтобы фоновая полировка могла её обновить.
    @MainActor @discardableResult
    private func finishJob(
        text: String, gen: Int, target: NSRunningApplication?, candidates: [Polisher.Candidate]
    ) -> UUID? {
        let isLatest = (self.generation == gen)

        if !candidates.isEmpty {
            for c in candidates { Vocabulary.shared.recordCandidate(canonical: c.canonical, raw: c.raw) }
            self.log("📚 \(candidates.count) кандидат(ов) в словарь")
        }

        self.inFlightCount = max(0, self.inFlightCount - 1)
        Pill.shared.setQueueCount(self.inFlightCount)

        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            self.log("⚠️ Пустой результат")
            if isLatest && self.inFlightCount == 0 { Pill.shared.hide() }
            return nil
        }

        UsageTracker.shared.addWords(from: clean)
        let used = UsageTracker.shared.wordsThisMonth
        let limit = UsageTracker.freeLimit
        let entryID = self.appendHistory(clean)

        if isLatest {
            self.log("✅ \"\(String(clean.prefix(60)))\"  [\(used)/\(limit) слов]")
            Pill.shared.showResult(clean)
            self.injectText(clean, target: target, myBundle: self.myBundle)
        } else {
            // Новая запись уже стартовала — не вставляем, чтобы не уронить текст
            // в чужой контекст. Транскрипт уже в истории, можно скопировать кликом.
            self.log("💾 Фоновая запись готова, добавлена в историю (новая запись активна — не вставляем)")
        }
        return entryID
    }

    // Выбор устройства ввода по настройке `v2.audio.device`:
    //  • "auto" (дефолт) — системный вход, НО если он Bluetooth (AirPods),
    //    берём встроенный микрофон (его не крадёт звонок, и для диктовки он лучше HFP)
    //  • "builtin" — всегда встроенный
    //  • "system" — всегда системный по умолчанию (старое поведение)
    //  • "<uid>" — конкретное устройство
    // Возвращает (AudioDeviceID? для recorder, человекочитаемую метку для лога).
    // Возвращает (AudioDeviceID?, метка). nil = «использовать системный дефолт»
    // → AppState/Recorder идут безопасным путём AVAudioRecorder (не AVAudioEngine).
    // Конкретный id возвращается ТОЛЬКО когда реально переопределяем устройство
    // (оно отличается от системного дефолта) — тогда включается AVAudioEngine-путь.
    nonisolated func resolveInputDevice() -> (AudioDeviceID?, String) {
        let choice = UserDefaults.standard.string(forKey: "v2.audio.device") ?? "auto"
        let sysDefault = AudioDevices.systemDefaultInput()

        // helper: если цель == системный дефолт, отдаём nil (безопасный путь)
        func resolve(_ target: AudioInputDevice?, label: String) -> (AudioDeviceID?, String) {
            guard let target else { return (nil, "системный по умолчанию") }
            if let sysDefault, sysDefault.id == target.id {
                return (nil, "\(target.name) (= системный)")
            }
            return (target.id, label)
        }

        switch choice {
        case "system":
            return (nil, "системный по умолчанию")
        case "builtin":
            return resolve(AudioDevices.builtInMic(), label: AudioDevices.builtInMic()?.name ?? "встроенный")
        case "auto":
            if let sys = sysDefault, sys.isBluetooth, let b = AudioDevices.builtInMic() {
                return resolve(b, label: "\(b.name) (авто: системный \(sys.name) — Bluetooth)")
            }
            return (nil, "\(sysDefault?.name ?? "системный") (авто)")
        default:
            return resolve(AudioDevices.device(forUID: choice), label: AudioDevices.device(forUID: choice)?.name ?? "выбранное")
        }
    }

    // Returns (log-string, willActuallyPolish). Used to print an explicit
    // diagnostic line for every dictation so the user knows whether anything
    // went to OpenAI and, if not, exactly why.
    nonisolated private func polishDecisionReason(
        text: String,
        settings: Polisher.Settings,
        skip: Bool
    ) -> (String, Bool) {
        let len = text.trimmingCharacters(in: .whitespacesAndNewlines).count
        if !settings.enabled {
            return ("☁️/  Полировка пропущена: тумблер выключен в настройках", false)
        }
        if settings.apiKey.isEmpty {
            return ("☁️/  Полировка пропущена: не вбит OpenAI API key", false)
        }
        if skip {
            return ("☁️/  Полировка пропущена: Shift был зажат или нет интернета", false)
        }
        if len < settings.minLength {
            return ("☁️/  Полировка пропущена: текст \(len) симв. < порога \(settings.minLength)", false)
        }
        return ("✨ Полировка → OpenAI \(settings.model) (текст \(len) симв.)", true)
    }

    private func injectText(_ text: String, target: NSRunningApplication?, myBundle: String) {
        let isSelfFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == myBundle

        if isSelfFront {
            // Voice2 own window is up — just put text on the clipboard.
            // No focus-stealing, no auto-paste. User decides where to paste.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            log("📋 Voice2 во фронте — текст в буфер, без вставки")
        } else {
            // Some other app is up — paste into it without switching focus.
            Injector.paste(text)
        }
    }

    // MARK: - Permissions

    // forced=true: always log result (used by the "Проверить" button for visible feedback).
    // forced=false: log only on change (used by the background polling timer).
    func refreshPermissions(forced: Bool = false) async {
        let newMic    = AVAudioApplication.shared.recordPermission == .granted
        let newAX     = AXIsProcessTrusted()
        if !hotkey.isActive { _ = hotkey.start() }
        let newHotkey = hotkey.isActive

        let changed = newMic != micOK || newAX != axOK || newHotkey != hotkeyOK
        micOK = newMic; axOK = newAX; hotkeyOK = newHotkey

        if changed || forced {
            let status = "mic:\(micOK ? "✓" : "✗")  ax:\(axOK ? "✓" : "✗")  hotkey:\(hotkeyOK ? "✓" : "✗")"
            log(forced ? "🔄 Проверено: \(status)" : "Perms  \(status)")
        }

        if forced && !hotkeyOK {
            log("ℹ️ Хоткей: выдай доступ в Мониторинг ввода → нажми «Готово — перезапустить хоткей»")
        }
        if forced && !axOK {
            log("ℹ️ Accessibility: включи переключатель VoiceTuT в Универсальном доступе → нажми «Проверить разрешения» ещё раз")
        }
    }

    func requestMic() async {
        _ = await AVAudioApplication.requestRecordPermission()
        micOK = AVAudioApplication.shared.recordPermission == .granted
        if !micOK { log("❌ Микрофон не выдан") } else { log("✅ Микрофон выдан") }
    }

    func restartHotkey() {
        hotkey.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.hotkeyOK = self.hotkey.start()
        }
    }

    func openAccessibility() {
        // com.apple.settings.PrivacySecurity.extension — macOS 13+ direct path.
        // Old com.apple.preference.security triggers a legacy redirect, causing 20-30s delay.
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!
        )
    }

    func openInputMonitoring() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent")!
        )
    }

    // MARK: - App tracking

    private func trackFrontmostApp() {
        if let a = NSWorkspace.shared.frontmostApplication, a.bundleIdentifier != myBundle {
            prevApp = a
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] n in
            guard let self,
                  let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  a.bundleIdentifier != self.myBundle else { return }
            Task { @MainActor [weak self] in self?.prevApp = a }
        }
    }

    // MARK: - History

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        history = decoded
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: historyKey)
    }

    @discardableResult
    func appendHistory(_ text: String) -> UUID? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let entry = HistoryEntry(text: clean, timestamp: Date())
        history.insert(entry, at: 0)
        if history.count > historyLimit { history = Array(history.prefix(historyLimit)) }
        saveHistory()
        return entry.id
    }

    /// Фоновая полировка догрузилась — обновляем уже добавленную запись истории.
    /// Буфер обмена НЕ трогаем (пользователь мог скопировать что-то своё); хочет
    /// отполированный вариант — кликнет по записи в истории.
    func updateHistoryText(id: UUID, to newText: String) {
        let clean = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let idx = history.firstIndex(where: { $0.id == id }) else { return }
        history[idx] = HistoryEntry(id: id, text: clean, timestamp: history[idx].timestamp)
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    // User corrected a transcript in the history sheet. Update the stored text,
    // then run a word-level diff to extract candidate aliases for the dictionary.
    func editHistory(id: UUID, original: String, edited: String) {
        let clean = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let idx = history.firstIndex(where: { $0.id == id }) {
            let oldText = history[idx].text
            history[idx] = HistoryEntry(id: id, text: clean, timestamp: history[idx].timestamp)
            saveHistory()
            Vocabulary.shared.learnFromEdit(original: oldText, edited: clean)
            log("✏️ История обновлена, кандидаты извлечены")
        }
    }

    func copyHistory(_ entry: HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        log("📋 Скопировано: \"\(String(entry.text.prefix(40)))\"")
    }

    // MARK: - Log

    func log(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(ts)] \(msg)"
        print(line)
        logLines.append(LogEntry(text: line))
        if logLines.count > 300 { logLines.removeFirst(50) }
    }

    // MARK: - Legacy migration (Voice2 → VoiceTuT)

    /// Один раз перетаскиваем все `v2.*` ключи из старого домена `com.voice2.local`
    /// в текущий (`com.voicetut.local`). Идемпотентно: помечает флагом и больше не трогает.
    static func migrateLegacyUserDefaults() {
        let migrationFlag = "v2.migration.voice2_to_voicetut"
        let std = UserDefaults.standard
        if std.bool(forKey: migrationFlag) { return }

        guard let legacy = UserDefaults(suiteName: "com.voice2.local") else {
            std.set(true, forKey: migrationFlag)
            return
        }

        // Берём только ключи нашего префикса — не таскаем чужой шум типа NSWindow геометрии.
        let all = legacy.dictionaryRepresentation()
        var copied = 0
        for (key, value) in all where key.hasPrefix("v2.") {
            // Не перезаписываем уже существующие значения (на случай если оператор
            // успел что-то ввести в новом домене).
            if std.object(forKey: key) == nil {
                std.set(value, forKey: key)
                copied += 1
            }
        }
        std.set(true, forKey: migrationFlag)
        print("[Migrate] copied \(copied) keys from com.voice2.local → com.voicetut.local")
    }
}

/// Гарантирует, что continuation сработает ровно один раз в гонке двух задач
/// (полировка vs дедлайн). Первый, кто вызвал claim(), получает true.
actor ResumeOnce {
    private var done = false
    func claim() -> Bool {
        if done { return false }
        done = true
        return true
    }
}
