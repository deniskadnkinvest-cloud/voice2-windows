import SwiftUI
import AppKit

struct ContentView: View {
    var body: some View {
        MainView()
            .frame(minWidth: 400, idealWidth: 440, minHeight: 520, idealHeight: 640)
    }
}

// MARK: - Main screen (after login)

struct MainView: View {
    @ObservedObject var app = AppState.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    permSection
                    Divider()
                    settingsSection
                    Divider()
                    MicrophoneSection()
                    Divider()
                    ModelSection()
                    Divider()
                    VocabularySection()
                    Divider()
                    CandidatesSection()
                    Divider()
                    PolishSection()
                    Divider()
                    recordSection
                    Divider()
                    historySection
                    Divider()
                    logSection
                }
                .padding(16)
            }
        }
    }

    // MARK: - Header

    var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(app.isRecording ? Color.red : Color.green)
                .frame(width: 8, height: 8)
                .animation(.easeInOut(duration: 0.3), value: app.isRecording)
            Text(app.isRecording ? "Диктую…" : "VoiceTuT")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button("Проверить разрешения") {
                Task { await app.refreshPermissions(forced: true) }
            }
            .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(.accentColor)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: - Permissions

    var permSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Разрешения").font(.system(size: 12, weight: .semibold))

            HStack(spacing: 28) {
                badge("Микрофон", ok: app.micOK)
                badge("Accessibility", ok: app.axOK)
                badge("Хоткей", ok: app.hotkeyOK)
            }

            if !app.micOK {
                Button("Выдать доступ к микрофону") {
                    Task { await app.requestMic() }
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }

            if !app.axOK {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Accessibility нужен для вставки текста в другие приложения.")
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(.orange)
                    Text("Настройки → Конфиденциальность → Универсальный доступ → + → Voice2")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    Button("Открыть настройки") { app.openAccessibility() }
                        .buttonStyle(.borderedProminent).controlSize(.mini)
                }
                .padding(8).background(Color.orange.opacity(0.1)).cornerRadius(6)
            }

            if !app.hotkeyOK {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Настройки → Конфиденциальность → Мониторинг ввода → + → Voice2")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        Button("Открыть настройки") { app.openInputMonitoring() }
                            .buttonStyle(.plain).controlSize(.mini).foregroundColor(.accentColor)
                        Button("Готово — перезапустить хоткей") { app.restartHotkey() }
                            .buttonStyle(.plain).controlSize(.mini).foregroundColor(.accentColor)
                    }
                }
                .padding(8).background(Color.secondary.opacity(0.06)).cornerRadius(6)
            }
        }
    }

    func badge(_ label: String, ok: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(ok ? .green : .red).font(.system(size: 18))
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
    }

    // MARK: - Settings

    var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Настройки").font(.system(size: 12, weight: .semibold))

            HStack(spacing: 10) {
                Text("Кнопка хоткея:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 110, alignment: .leading)

                Picker("", selection: $app.hotkeyKey) {
                    ForEach(HotkeyKey.allCases) { k in
                        Text(k.rawValue).tag(k)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200, alignment: .leading)
            }

            Text("Двойной тап хоткея = hands-free режим (запись до следующего тапа)")
                .font(.system(size: 10)).foregroundColor(.secondary)

            Text("Индикатор-пилюля: зажмите и тяните чтобы переместить")
                .font(.system(size: 10)).foregroundColor(.secondary)

            Button("🔬 Диагностика хоткея") { app.diagnoseHotkey() }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(.accentColor)
        }
    }

    // MARK: - Record section

    var recordSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Диктовка").font(.system(size: 12, weight: .semibold))

            HoldButton(isDown: app.isRecording,
                       onPress: { Task { @MainActor in app.startRecording() } },
                       onRelease: { Task { @MainActor in app.stopRecording() } })
                .frame(height: 40)

            Text("Или удерживай \(app.hotkeyKey.rawValue) · двойной тап = hands-free")
                .font(.system(size: 10)).foregroundColor(.secondary)

            Text("Текст вставляется в последнее активное приложение через Cmd+V")
                .font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    // MARK: - History section

    @State private var copiedHistoryID: UUID? = nil
    @State private var editingEntry: HistoryEntry? = nil

    var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("История диктовок").font(.system(size: 12, weight: .semibold))
                Spacer()
                if copiedHistoryID != nil {
                    Text("скопировано ✓")
                        .font(.system(size: 10)).foregroundColor(.green)
                        .transition(.opacity)
                }
                if !app.history.isEmpty {
                    Button("Очистить") { app.clearHistory() }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: copiedHistoryID)

            if app.history.isEmpty {
                Text("После первой диктовки распознанный текст появится здесь. Клик = копировать.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(app.history) { entry in
                            historyRow(entry)
                        }
                    }
                    .padding(4)
                }
                .frame(height: 120)
                .background(Color.black.opacity(0.04))
                .cornerRadius(5)
            }
        }
    }

    func historyRow(_ entry: HistoryEntry) -> some View {
        let isCopied = copiedHistoryID == entry.id
        let timeStr = DateFormatter.localizedString(from: entry.timestamp, dateStyle: .none, timeStyle: .short)
        return HStack(alignment: .top, spacing: 6) {
            Text(timeStr)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .leading)
            Text(entry.text)
                .font(.system(size: 11))
                .foregroundColor(isCopied ? .accentColor : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    app.copyHistory(entry)
                    copiedHistoryID = entry.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if copiedHistoryID == entry.id { copiedHistoryID = nil }
                    }
                }
            Button(action: { editingEntry = entry }) {
                Image(systemName: "pencil")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Исправить и обучить словарь")
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundColor(isCopied ? .green : .secondary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .sheet(item: $editingEntry) { entry in
            EditHistorySheet(entry: entry) { editingEntry = nil }
                .frame(width: 460, height: 320)
        }
    }

    // MARK: - Log section

    @State private var copiedID: UUID? = nil

    var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Лог").font(.system(size: 12, weight: .semibold))
                Spacer()
                if copiedID != nil {
                    Text("скопировано ✓")
                        .font(.system(size: 10)).foregroundColor(.green)
                        .transition(.opacity)
                }
                Button("Очистить") { app.logLines.removeAll() }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundColor(.secondary)
            }
            .animation(.easeInOut(duration: 0.2), value: copiedID)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(app.logLines) { entry in
                            Text(entry.text)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(copiedID == entry.id ? .accentColor : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(entry.text, forType: .string)
                                    copiedID = entry.id
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        if copiedID == entry.id { copiedID = nil }
                                    }
                                }
                        }
                    }.padding(4)
                }
                .frame(height: 140)
                .background(Color.black.opacity(0.04))
                .cornerRadius(5)
                .onChange(of: app.logLines.count) {
                    proxy.scrollTo(app.logLines.last?.id)
                }
            }
        }
    }
}

// MARK: - HoldButton: NSViewRepresentable wrapping a raw NSView

struct HoldButton: NSViewRepresentable {
    var isDown: Bool
    let onPress: () -> Void
    let onRelease: () -> Void

    func makeNSView(context: Context) -> HoldView {
        let v = HoldView()
        v.onPress = onPress
        v.onRelease = onRelease
        return v
    }

    func updateNSView(_ v: HoldView, context: Context) {
        v.onPress = onPress
        v.onRelease = onRelease
        v.isDown = isDown
        v.needsDisplay = true
    }
}

final class HoldView: NSView {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var isDown = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bg: NSColor = isDown ? .systemRed : .controlAccentColor
        bg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()

        let title = isDown ? "● Отпусти для остановки" : "🎙  Зажми и говори"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        ]
        let sz = (title as NSString).size(withAttributes: attrs)
        let pt = NSPoint(x: (bounds.width - sz.width) / 2,
                         y: (bounds.height - sz.height) / 2)
        (title as NSString).draw(at: pt, withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        isDown = true; needsDisplay = true; onPress?()
    }
    override func mouseUp(with event: NSEvent) {
        isDown = false; needsDisplay = true; onRelease?()
    }
}

// MARK: - Vocabulary editor

struct VocabularySection: View {
    @ObservedObject private var vocab = Vocabulary.shared
    @State private var newCanonical = ""
    @State private var newAliases = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Словарь терминов").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(vocab.terms.count)")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            Text("Бренды, имена, продукты, которые Whisper всё время слышит неправильно. «Алиасы» — варианты, которые он выдаёт; заменяются на каноническое написание.")
                .font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                TextField("Например: Charge 5", text: $newCanonical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                TextField("Алиасы через запятую: чардж 5, чарж файв", text: $newAliases)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                Button("+") {
                    let aliases = newAliases
                        .split(separator: ",")
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    vocab.add(canonical: newCanonical, aliases: aliases)
                    newCanonical = ""
                    newAliases = ""
                }
                .disabled(newCanonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .controlSize(.small)
            }

            if vocab.terms.isEmpty {
                Text("Пока пусто. Добавь термины — Whisper начнёт писать их правильно.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(vocab.terms) { term in
                            HStack(alignment: .top, spacing: 6) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(term.canonical)
                                        .font(.system(size: 11, weight: .medium))
                                    if !term.aliases.isEmpty {
                                        Text(term.aliases.joined(separator: ", "))
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                Button(action: { vocab.remove(term) }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 4)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 130)
                .background(Color.black.opacity(0.04))
                .cornerRadius(5)
            }
        }
    }
}

// MARK: - LLM polish settings

struct PolishSection: View {
    @State private var enabled = false
    @State private var apiKey = ""
    @State private var model = "gpt-4o-mini"
    @State private var instruction = ""
    @State private var minLength: Double = 80
    @State private var saved = false

    private let modelOptions = ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Полировка текста (LLM)").font(.system(size: 12, weight: .semibold))
                Spacer()
                if saved {
                    Text("сохранено ✓").font(.system(size: 10)).foregroundColor(.green)
                }
            }

            Toggle(isOn: $enabled) {
                Text("Прогонять через GPT после Whisper")
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: enabled) { _, _ in persist() }

            Text("Расставит запятые, разобьёт на абзацы, уберёт слова-паразиты. Смысл и стиль не трогает.")
                .font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text("OpenAI API Key:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 110, alignment: .leading)
                SecureField("sk-…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { persist() }
            }

            HStack(spacing: 6) {
                Text("Модель:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 110, alignment: .leading)
                Picker("", selection: $model) {
                    ForEach(modelOptions, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
                .onChange(of: model) { _, _ in persist() }
            }

            HStack(spacing: 6) {
                Text("Мин. длина:")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(width: 110, alignment: .leading)
                Slider(value: $minLength, in: 20...300, step: 10) { editing in
                    if !editing { persist() }
                }
                Text("\(Int(minLength)) симв.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }

            Text("Короткие фразы не уходят в облако — остаются 100% локальными.")
                .font(.system(size: 10)).foregroundColor(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text("⇧ Shift при зажатии хоткея = эта диктовка без полировки")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Дополнительная инструкция (опционально):")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                TextEditor(text: $instruction)
                    .font(.system(size: 11))
                    .frame(height: 50)
                    .padding(4)
                    .background(Color.black.opacity(0.04))
                    .cornerRadius(5)
            }

            Button("Сохранить") { persist() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .onAppear(perform: load)
    }

    private func load() {
        let s = Polisher.loadSettings()
        enabled = s.enabled
        apiKey = s.apiKey
        model = s.model.isEmpty ? "gpt-4o-mini" : s.model
        instruction = s.customInstruction
        minLength = Double(s.minLength)
    }

    private func persist() {
        Polisher.saveSettings(.init(
            enabled: enabled,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model,
            customInstruction: instruction,
            minLength: Int(minLength)
        ))
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            saved = false
        }
    }
}

// MARK: - Candidates section — auto-populated by Polisher

struct CandidatesSection: View {
    @ObservedObject private var vocab = Vocabulary.shared
    @State private var editingCandidate: VocabularyCandidate? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Кандидаты в словарь")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !vocab.candidates.isEmpty {
                    Text("\(vocab.candidates.count)")
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }

            Text("Polisher (и твои правки в истории) автоматически собирают сюда термины. Подтверди — попадёт в словарь, отклони — пропадёт.")
                .font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if vocab.candidates.isEmpty {
                Text("Пока пусто. Подключи OpenAI ключ и продиктуй абзац — кандидаты появятся.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(vocab.candidates) { c in
                            HStack(alignment: .top, spacing: 6) {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(c.canonical)
                                            .font(.system(size: 11, weight: .medium))
                                        if c.seenCount > 1 {
                                            Text("×\(c.seenCount)")
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    if !c.rawForms.isEmpty {
                                        Text("слышу как: " + c.rawForms.joined(separator: ", "))
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                Button(action: { vocab.promote(c) }) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(.green)
                                }
                                .buttonStyle(.plain)
                                .help("Добавить в словарь как есть")
                                Button(action: { editingCandidate = c }) {
                                    Image(systemName: "pencil.circle")
                                        .font(.system(size: 14))
                                        .foregroundColor(.accentColor)
                                }
                                .buttonStyle(.plain)
                                .help("Поправить и добавить")
                                Button(action: { vocab.dismiss(c) }) {
                                    Image(systemName: "xmark.circle")
                                        .font(.system(size: 14))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Отклонить")
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 4)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 150)
                .background(Color.black.opacity(0.04))
                .cornerRadius(5)
            }
        }
        .sheet(item: $editingCandidate) { c in
            EditCandidateSheet(candidate: c) { editingCandidate = nil }
                .frame(width: 460)
        }
    }
}

// MARK: - Edit candidate sheet — правка перед добавлением в словарь

struct EditCandidateSheet: View {
    let candidate: VocabularyCandidate
    let onClose: () -> Void

    @State private var canonical: String
    @State private var aliasesText: String

    init(candidate: VocabularyCandidate, onClose: @escaping () -> Void) {
        self.candidate = candidate
        self.onClose = onClose
        _canonical = State(initialValue: candidate.canonical)
        _aliasesText = State(initialValue: candidate.rawForms.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Поправить термин перед добавлением")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("Канон — как должно быть написано:")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                TextField("Charge 5 / Telegram-чат / SwiftUI", text: $canonical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Алиасы — что Whisper слышит (через запятую):")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                TextField("чардж 5, telegram fcl, свифтюай", text: $aliasesText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                if !candidate.rawForms.isEmpty {
                    Text("Изначально: " + candidate.rawForms.joined(separator: ", "))
                        .font(.system(size: 10)).foregroundColor(.secondary)
                }
            }

            Text("Алиасы — это то, как ты обычно произносишь или как звучит в твоей речи. Они заменяются на «канон» на выходе.")
                .font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Отмена") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Добавить в словарь") {
                    let canon = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !canon.isEmpty else { return }
                    let aliases = aliasesText
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    Vocabulary.shared.promoteEdited(candidate, canonical: canon, aliases: aliases)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }
}

// MARK: - History edit sheet — learns from user corrections

struct EditHistorySheet: View {
    let entry: HistoryEntry
    let onClose: () -> Void

    @State private var edited: String

    init(entry: HistoryEntry, onClose: @escaping () -> Void) {
        self.entry = entry
        self.onClose = onClose
        _edited = State(initialValue: entry.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Исправить и обучить словарь")
                .font(.system(size: 13, weight: .semibold))

            Text("Оригинал:")
                .font(.system(size: 10)).foregroundColor(.secondary)
            ScrollView {
                Text(entry.text)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: 60)
            .background(Color.black.opacity(0.04))
            .cornerRadius(5)

            Text("Правка:")
                .font(.system(size: 10)).foregroundColor(.secondary)
            TextEditor(text: $edited)
                .font(.system(size: 11))
                .padding(4)
                .background(Color.black.opacity(0.04))
                .cornerRadius(5)
                .frame(minHeight: 100)

            Text("Изменённые слова автоматически попадут в «Кандидаты в словарь» — там подтвердишь.")
                .font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Отмена") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить и обучить") {
                    AppState.shared.editHistory(id: entry.id, original: entry.text, edited: edited)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}

// MARK: - Model section — выбор и скачивание модели Whisper

struct ModelSection: View {
    @ObservedObject private var manager = ModelManager.shared
    @State private var showOnboarding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Модель распознавания")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if manager.isDownloading, let m = manager.downloadingModel {
                    Text("\(m.displayName) · \(Int(manager.downloadProgress * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.accentColor)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(manager.isModelAvailable(manager.currentModel) ? Color.green.opacity(0.18) : Color.orange.opacity(0.18))
                        .frame(width: 32, height: 32)
                    Image(systemName: manager.isModelAvailable(manager.currentModel) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(manager.isModelAvailable(manager.currentModel) ? .green : .orange)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.currentModel.displayName)
                        .font(.system(size: 12, weight: .medium))
                    Text(manager.currentModel.summary)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(action: { showOnboarding = true }) {
                    Text("Сменить")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if manager.isDownloading {
                ProgressView(value: manager.downloadProgress)
            }

            if let err = manager.downloadError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { showOnboarding = false }
                .frame(width: 520)
        }
    }
}

// MARK: - Microphone section — выбор устройства ввода (фикс записи во время звонков)

struct MicrophoneSection: View {
    @State private var choice: String = UserDefaults.standard.string(forKey: "v2.audio.device") ?? "auto"
    @State private var devices: [AudioInputDevice] = []
    @State private var systemDefaultName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Микрофон")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Обновить список устройств")
            }

            Picker("", selection: $choice) {
                Text("Авто (умный)").tag("auto")
                Text("Встроенный микрофон").tag("builtin")
                Text("Системный по умолчанию").tag("system")
                if !devices.isEmpty {
                    Divider()
                    ForEach(devices) { d in
                        Text(d.name + (d.isBluetooth ? " ᐧ BT" : "")).tag(d.uid)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 320, alignment: .leading)
            .onChange(of: choice) { _, new in
                UserDefaults.standard.set(new, forKey: "v2.audio.device")
            }

            Text(hint)
                .font(.system(size: 10)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: refresh)
    }

    private var hint: String {
        switch choice {
        case "auto":
            let bt = systemDefaultName.isEmpty ? "" : " Сейчас системный: \(systemDefaultName)."
            return "Берёт системный вход, но если это Bluetooth (AirPods) — переключается на встроенный микрофон. Это чинит запись во время звонков: звонок занимает AirPods, а встроенный микрофон свободен.\(bt)"
        case "builtin":
            return "Всегда пишет со встроенного микрофона MacBook. Не крадётся звонком, стабильное качество для диктовки."
        case "system":
            return "Всегда пишет с системного устройства по умолчанию. Во время звонка через AirPods запись может не работать."
        default:
            return "Пишет всегда с выбранного устройства. Если оно занято звонком — запись может быть тишиной."
        }
    }

    private func refresh() {
        devices = AudioDevices.inputDevices()
        systemDefaultName = AudioDevices.systemDefaultInput()?.name ?? ""
    }
}
