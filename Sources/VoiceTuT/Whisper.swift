import Foundation

enum Whisper {
    static var cli: String { Bundle.main.resourcePath! + "/whisper-cli" }

    /// Путь к модели — берём из ModelManager (user-downloaded или legacy bundled).
    /// Если оператор ещё не скачал ни одну модель — возвращает nil и run() сообщает в лог.
    @MainActor
    static var model: String? { ModelManager.shared.currentModelPath() }

    static func run(wav: URL, lang: String = "ru", initialPrompt: String = "") async -> String? {
        guard FileManager.default.fileExists(atPath: cli) else {
            print("[Whisper] cli not found: \(cli)"); return nil
        }
        guard let model = await Whisper.model else {
            print("[Whisper] model not configured — run onboarding")
            try? FileManager.default.removeItem(at: wav)
            return nil
        }
        guard FileManager.default.fileExists(atPath: model) else {
            print("[Whisper] model not found at: \(model)")
            try? FileManager.default.removeItem(at: wav)
            return nil
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        var args = ["-m", model, "-f", wav.path, "-l", lang, "--no-timestamps", "-np"]
        let trimmedPrompt = initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            args.append(contentsOf: ["--prompt", trimmedPrompt, "--carry-initial-prompt"])
        }
        p.arguments = args

        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError  = errPipe

        do {
            try p.run()
        } catch {
            print("[Whisper] Launch error: \(error)")
            try? FileManager.default.removeItem(at: wav)
            return nil
        }

        // Drain stderr concurrently — prevents pipe-buffer deadlock (64 KB on macOS).
        // whisper-cli verbose Metal/GGML output easily exceeds this limit.
        let stderrTask = Task.detached { errPipe.fileHandleForReading.readDataToEndOfFile() }

        // Suspend the cooperative thread instead of blocking it with waitUntilExit().
        // Whisper can take 5-30s; blocking the thread starves other async work.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            p.terminationHandler = { _ in cont.resume() }
        }

        let errData = await stderrTask.value
        if let errText = String(data: errData, encoding: .utf8), !errText.isEmpty {
            print("[Whisper] stderr: \(errText.prefix(400))")
        }

        let raw = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        try? FileManager.default.removeItem(at: wav)

        let text = raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[BLANK") && !$0.hasPrefix("[_BEG_") }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        print("[Whisper] \"\(String(text.prefix(60)))\"")
        return text.isEmpty ? nil : text
    }
}
