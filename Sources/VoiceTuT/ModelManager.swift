import Foundation

// VoiceTuT использует whisper.cpp. Раньше модель `ggml-small.bin` лежала
// внутри .app bundle (~500 MB). Это плохо для упаковки в продукт — каждый
// апдейт = 500 MB заново. Конкуренты (Superwhisper, MacWhisper) держат
// .app маленьким (~15 MB) и качают модель on-demand при первом запуске.
//
// ModelManager отвечает за:
// 1. Каталог известных моделей (имя, размер, URL, описание)
// 2. Хранение выбранной пользователем модели в UserDefaults
// 3. Путь к модели — сначала в `~/Library/Application Support/VoiceTuT/models/`,
//    fallback на bundled (legacy) если новый путь пуст и выбранная модель = small
// 4. Скачивание с прогрессом (URLSessionDownloadDelegate)
// 5. Сообщение остальной системе (через @Published) что идёт загрузка

import Combine

@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    enum Model: String, CaseIterable, Identifiable, Codable {
        case small         = "ggml-small.bin"
        case largeV3Turbo  = "ggml-large-v3-turbo.bin"
        case largeV3       = "ggml-large-v3.bin"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .small:        return "Быстрая"
            case .largeV3Turbo: return "Сбалансированная"
            case .largeV3:      return "Максимальная"
            }
        }

        var techName: String { rawValue }

        var summary: String {
            switch self {
            case .small:
                return "small · 470 MB · быстрая, но галлюцинирует на сложных русских словах и en-mix"
            case .largeV3Turbo:
                return "large-v3-turbo · 1.6 GB · sweet spot для русского и en-mix, 8× быстрее large-v3"
            case .largeV3:
                return "large-v3 · 3 GB · максимальная точность, ~2× медленнее turbo"
            }
        }

        var sizeBytes: Int64 {
            switch self {
            case .small:        return  466_000_000
            case .largeV3Turbo: return 1_620_000_000
            case .largeV3:      return 3_094_000_000
            }
        }

        var humanSize: String {
            let mb = Double(sizeBytes) / 1_000_000
            return mb >= 1000
                ? String(format: "%.1f GB", mb / 1000)
                : String(format: "%.0f MB", mb)
        }

        var downloadURL: URL {
            URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(rawValue)")!
        }
    }

    // MARK: - Published state

    @Published private(set) var currentModel: Model
    @Published private(set) var isDownloading: Bool = false
    @Published private(set) var downloadProgress: Double = 0  // 0.0 – 1.0
    @Published private(set) var downloadError: String? = nil
    @Published private(set) var downloadingModel: Model? = nil

    // MARK: - Storage

    private let storageKey = "v2.model.selected"

    private init() {
        let saved = UserDefaults.standard.string(forKey: storageKey)
        self.currentModel = saved.flatMap(Model.init(rawValue:)) ?? .small
    }

    func setCurrentModel(_ m: Model) {
        currentModel = m
        UserDefaults.standard.set(m.rawValue, forKey: storageKey)
    }

    /// Каталог моделей: `~/Library/Application Support/VoiceTuT/models/`.
    /// Создаётся при первом обращении.
    var modelsDirectory: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = support
            .appendingPathComponent("VoiceTuT", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Путь к выбранной модели для whisper-cli. Если в новом каталоге пусто
    /// и выбрана `small` — используем legacy bundled (чтобы текущие пользователи
    /// продолжали работать без онбординга). Возвращает nil если модели нет нигде.
    func currentModelPath() -> String? {
        let userPath = modelsDirectory.appendingPathComponent(currentModel.rawValue).path
        if FileManager.default.fileExists(atPath: userPath) { return userPath }
        if currentModel == .small,
           let bundled = Bundle.main.resourcePath {
            let p = bundled + "/ggml-small.bin"
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    /// Проверка доступности конкретной модели — для UI «есть на диске / нужно скачать».
    func isModelAvailable(_ m: Model) -> Bool {
        let userPath = modelsDirectory.appendingPathComponent(m.rawValue).path
        if FileManager.default.fileExists(atPath: userPath) { return true }
        if m == .small, let bundled = Bundle.main.resourcePath {
            return FileManager.default.fileExists(atPath: bundled + "/ggml-small.bin")
        }
        return false
    }

    /// Возвращает true если на текущий момент НЕТ ни одной рабочей модели
    /// (новый пользователь, legacy bundled тоже отсутствует). Используется
    /// для триггера онбординга.
    func needsOnboarding() -> Bool {
        for m in Model.allCases {
            if isModelAvailable(m) { return false }
        }
        return true
    }

    // MARK: - Download

    /// Скачивает выбранную модель в `modelsDirectory`. Идемпотентна (если уже есть — выходит).
    /// Прогресс и ошибки доступны через @Published свойства.
    func downloadModel(_ m: Model) async {
        if isModelAvailable(m) {
            setCurrentModel(m)
            return
        }
        if isDownloading { return }
        isDownloading = true
        downloadingModel = m
        downloadProgress = 0
        downloadError = nil

        let destination = modelsDirectory.appendingPathComponent(m.rawValue)
        let coordinator = DownloadCoordinator()
        // Конфиг с увеличенным таймаутом — 3 GB на медленном интернете могут занять долго.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 60 * 60  // 1 hour cap
        let session = URLSession(configuration: config, delegate: coordinator, delegateQueue: nil)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            coordinator.progressHandler = { [weak self] progress in
                Task { @MainActor [weak self] in self?.downloadProgress = progress }
            }
            coordinator.completionHandler = { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else { cont.resume(); return }
                    switch result {
                    case .success(let tempURL):
                        do {
                            try? FileManager.default.removeItem(at: destination)
                            try FileManager.default.moveItem(at: tempURL, to: destination)
                            self.setCurrentModel(m)
                            self.downloadProgress = 1.0
                        } catch {
                            self.downloadError = "Не удалось сохранить файл: \(error.localizedDescription)"
                        }
                    case .failure(let err):
                        self.downloadError = err.localizedDescription
                    }
                    self.isDownloading = false
                    self.downloadingModel = nil
                    session.finishTasksAndInvalidate()
                    cont.resume()
                }
            }
            let task = session.downloadTask(with: m.downloadURL)
            task.resume()
        }
    }

    func cancelDownload() {
        // Best-effort: следующий вызов downloadModel создаст новую сессию.
        // (Текущая остановится после возврата из withCheckedContinuation.)
        downloadError = "Загрузка отменена"
        isDownloading = false
        downloadingModel = nil
    }

    func deleteDownloadedModel(_ m: Model) {
        let path = modelsDirectory.appendingPathComponent(m.rawValue)
        try? FileManager.default.removeItem(at: path)
    }
}

// MARK: - URLSessionDownloadDelegate

private final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var progressHandler: ((Double) -> Void)?
    var completionHandler: ((Result<URL, Error>) -> Void)?

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // didFinishDownloadingTo даёт временный URL, который ВАЛИДЕН только в этом колбэке —
        // дальше система может его удалить. Переносим сразу в собственный tmp.
        let safe = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicetut-dl-\(UUID().uuidString).bin")
        do {
            try FileManager.default.moveItem(at: location, to: safe)
            completionHandler?(.success(safe))
        } catch {
            completionHandler?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            completionHandler?(.failure(error))
        }
        // Успешное завершение приходит через didFinishDownloadingTo, не здесь.
    }
}
