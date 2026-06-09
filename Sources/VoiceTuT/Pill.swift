import AppKit
import SwiftUI

// MARK: - Pill state

enum PillPhase: Equatable {
    case idle
    case recording(Int)
    case transcribing
    case done(String)
    case error(String)

    static func == (lhs: PillPhase, rhs: PillPhase) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.transcribing, .transcribing): return true
        case (.recording(let a), .recording(let b)): return a == b
        case (.done(let a), .done(let b)): return a == b
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

final class PillState: ObservableObject {
    @MainActor @Published var phase: PillPhase = .idle
    @MainActor @Published var cloudInFlight: Bool = false
    @MainActor @Published var offline: Bool = false
    @MainActor @Published var willSkipPolish: Bool = false
    @MainActor @Published var queueCount: Int = 0  // background jobs (whisper/polish) still processing
}

// MARK: - Floating panel

@MainActor
final class Pill {
    static let shared = Pill()

    let state = PillState()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    private init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 290, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // CGShieldingWindowLevel — выше screensaver, выше full-screen apps,
        // выше альтернативных оверлеев. Это самый верхний уровень для обычных приложений.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.hidesOnDeactivate = false    // stays visible when Voice2 loses focus
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // hasShadow=false — иначе macOS рисует прямоугольную тень вокруг bounds панели,
        // и виден прямоугольник вокруг скруглённого pill'а. SwiftUI сам рисует тень по форме.
        panel.hasShadow = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.isMovableByWindowBackground = true  // drag to reposition
        panel.isReleasedWhenClosed = false

        let host = NSHostingView(rootView: PillView(state: state))
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        reposition()  // initial position only — dragging preserves position

        // Пилюля персистентна: всегда на экране, в покое сворачивается в маленькую
        // точку-микрофон. Так оператор всегда видит, где она и в каком состоянии.
        panel.orderFrontRegardless()
        startKeepOnTop()
    }

    func show() {
        cancelHide()
        Task { @MainActor in self.state.phase = .recording(0) }
        // No reposition() here — preserves user's dragged location
        panel.orderFrontRegardless()
        startKeepOnTop()
    }

    func setCloudInFlight(_ active: Bool) {
        Task { @MainActor in
            self.state.cloudInFlight = active
            if active { self.panel.orderFrontRegardless() }
        }
    }

    func setOffline(_ offline: Bool) {
        Task { @MainActor in
            self.state.offline = offline
            if self.panel.isVisible { self.panel.orderFrontRegardless() }
        }
    }

    func setWillSkipPolish(_ skip: Bool) {
        Task { @MainActor in
            self.state.willSkipPolish = skip
            if self.panel.isVisible { self.panel.orderFrontRegardless() }
        }
    }

    func setQueueCount(_ n: Int) {
        Task { @MainActor in
            let prev = self.state.queueCount
            self.state.queueCount = max(0, n)
            // Есть фоновая задача, а пилюля в покое — поднять в transcribing,
            // чтобы оператор видел, что идёт обработка.
            if self.state.queueCount > 0, case .idle = self.state.phase {
                self.state.phase = .transcribing
                self.panel.orderFrontRegardless()
            }
            // Очередь опустела и пилюля висит в пассивном transcribing — свернуть в покой.
            if prev > 0 && self.state.queueCount == 0,
               case .transcribing = self.state.phase {
                self.hide()
            }
        }
    }

    // Periodic re-front while the panel is shown — guards against other apps'
    // high-level panels stealing the top spot.
    private var rebrigingTimer: Timer?

    private func startKeepOnTop() {
        rebrigingTimer?.invalidate()
        rebrigingTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.panel.isVisible { self.panel.orderFrontRegardless() }
            }
        }
    }

    private func stopKeepOnTop() {
        rebrigingTimer?.invalidate()
        rebrigingTimer = nil
    }

    func update(seconds: Int) {
        Task { @MainActor in self.state.phase = .recording(seconds) }
    }

    func showTranscribing() {
        cancelHide()
        Task { @MainActor in self.state.phase = .transcribing }
        panel.orderFrontRegardless()
    }

    func showResult(_ text: String) {
        Task { @MainActor in self.state.phase = .done(text) }
        panel.orderFrontRegardless()
        scheduleHide()
    }

    func showError(_ msg: String) {
        Task { @MainActor in self.state.phase = .error(msg) }
        panel.orderFrontRegardless()
        scheduleHide()
    }

    // "hide" теперь = свернуть в покоящуюся точку, НЕ убирать с экрана.
    // Пилюля персистентна по требованию оператора — иначе непонятно, идёт запись или нет.
    func hide() {
        cancelHide()
        Task { @MainActor in self.state.phase = .idle }
        // Панель остаётся видимой; keepOnTop продолжает работать.
        panel.orderFrontRegardless()
    }

    // Полное скрытие — на случай если когда-нибудь понадобится (сейчас не используется).
    func hideCompletely() {
        cancelHide()
        stopKeepOnTop()
        Task { @MainActor in self.state.phase = .idle }
        panel.orderOut(nil)
    }

    private func scheduleHide() {
        cancelHide()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if self.state.queueCount > 0 {
                    // ещё есть фоновые задачи — оставляем пилюлю висеть в transcribing
                    self.state.phase = .transcribing
                    self.panel.orderFrontRegardless()
                } else {
                    self.hide()
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        let x = f.midX - panel.frame.width / 2
        let y = f.minY + 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - SwiftUI view

struct PillView: View {
    @ObservedObject var state: PillState

    private var isIdle: Bool {
        if case .idle = state.phase { return true }
        return false
    }

    var body: some View {
        ZStack {
            if isIdle {
                minimizedPill
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            } else {
                pillContent
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.85).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: state.phase)
        // Иконка меняется не только по phase: отправка в облако и размер очереди —
        // отдельные сигналы, по которым ведущий индикатор переключается. Анимируем и их,
        // иначе смена «волны → отправка → кольцо» происходит рывком.
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: state.cloudInFlight)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: state.queueCount)
        .frame(width: 290, height: 64)
    }

    // Покоящаяся точка — всегда на экране, чтобы оператор видел где пилюля
    // и что приложение живо. Серый микрофон = не записывает.
    var minimizedPill: some View {
        HStack {
            Spacer()
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 2)
                Image(systemName: "mic")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .opacity(0.55)
    }

    var pillContent: some View {
        HStack(spacing: 10) {
            leadingIndicator
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
            queueBadge
            skipHint
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 4)
        )
        .padding(.horizontal, 7).padding(.vertical, 5)
        .opacity(0.80)
    }

    // MARK: - Activity — что пилюля ДЕЛАЕТ прямо сейчас

    // Раньше три разных процесса сливались в одно «кольцо загрузки», и оно
    // даже всплывало во время записи (если в фоне ещё крутилась прошлая диктовка).
    // Теперь у каждого процесса — свой однозначный визуал:
    //   • .recording  — микрофон открыт, идёт захват звука → пульсирующий МИКРОФОН
    //   • .sending    — текст ушёл в OpenAI на полировку     → облако ↑ (ОТПРАВКА)
    //   • .processing — локальный whisper распознаёт          → КОЛЬЦО загрузки
    // Приоритет: запись всегда главнее (оператор должен видеть, что его слышат),
    // затем отправка в облако, затем локальная обработка.
    private enum Activity { case recording, sending, processing, done, error, idle }

    private var activity: Activity {
        switch state.phase {
        case .recording:    return .recording
        case .done:         return .done
        case .error:        return .error
        case .idle:         return state.queueCount > 0 ? .processing : .idle
        case .transcribing: return state.cloudInFlight ? .sending : .processing
        }
    }

    // Ведущий индикатор — единственный источник правды о текущем состоянии.
    @ViewBuilder
    var leadingIndicator: some View {
        ZStack {
            Circle()
                .fill(accentColor.opacity(0.18))
                .frame(width: 38, height: 38)
            switch activity {
            case .recording:
                // Пульсирующий микрофон (как было до анимации волной) — идёт захват звука.
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.red)
                    .symbolEffect(.pulse, isActive: true)
            case .sending:
                // ОТПРАВКА — текст летит в облако на полировку.
                Image(systemName: "icloud.and.arrow.up.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.yellow)
                    .symbolEffect(.pulse, isActive: true)
            case .processing:
                // КОЛЬЦО — локальное распознавание (реальная загрузка).
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.9)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.green)
            case .error:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.red)
            case .idle:
                Image(systemName: "mic")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var accentColor: Color {
        switch activity {
        case .recording:  return .red
        case .sending:    return .yellow
        case .processing: return .orange
        case .done:       return .green
        case .error:      return .red
        case .idle:       return .secondary
        }
    }

    // Сколько фоновых задач (Whisper/Polish) ещё крутится.
    // Видим только при >= 2 — одна задача уже представлена основным состоянием.
    @ViewBuilder
    var queueBadge: some View {
        if state.queueCount > 1 {
            HStack(spacing: 2) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(state.queueCount)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundColor(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.18), in: Capsule())
            .help("В очереди \(state.queueCount) записи")
        }
    }

    // Подсказка справа: полировки не будет (оффлайн или Shift-skip).
    // Это ортогонально активности — не подменяет волны/кольцо, висит сбоку
    // мелкой серой иконкой. Прячем во время отправки (там уже видно облако).
    @ViewBuilder
    var skipHint: some View {
        if (state.offline || state.willSkipPolish), activity != .sending {
            Image(systemName: "icloud.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .help(state.offline ? "Оффлайн — без полировки" : "Полировка пропущена для этой диктовки")
        }
    }

    var label: String {
        switch activity {
        case .recording:
            if case .recording(let s) = state.phase { return "Запись \(s)с" }
            return "Запись"
        case .sending:    return "Отправка…"
        case .processing: return "Распознаю…"
        case .done:
            if case .done(let t) = state.phase { return t.isEmpty ? "Готово ✓" : "\"\(String(t.prefix(38)))\"" }
            return "Готово ✓"
        case .error:
            if case .error(let m) = state.phase { return m }
            return "Ошибка"
        case .idle:       return ""
        }
    }
}
