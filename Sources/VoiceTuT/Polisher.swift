import Foundation

// LLM post-processing for raw Whisper output.
// Restores punctuation, breaks long monologues into paragraphs, fixes obvious
// dictation artefacts (mid-sentence "ну", filler doubles) — without changing meaning
// or rewriting the speaker's word choice. Vocabulary terms are pinned: the model is
// told to keep them in their canonical spelling.
//
// Also extracts candidates for self-populating the dictionary — proper nouns / brands /
// product names the model had to fix or that look like terminology. These are NOT
// auto-applied; they go into Vocabulary.candidates for the user to confirm.
//
// Uses OpenAI Chat Completions API (gpt-4o-mini by default — cheap, fast, good Russian)
// with response_format = json_object. Failure is non-fatal: returns the original text.

enum Polisher {

    struct Settings {
        var enabled: Bool
        var apiKey: String
        var model: String
        var customInstruction: String
        var minLength: Int
    }

    struct Candidate: Codable, Equatable {
        let canonical: String
        let raw: String
    }

    struct Result {
        let text: String
        let candidates: [Candidate]
    }

    static func loadSettings() -> Settings {
        let d = UserDefaults.standard
        let minRaw = d.integer(forKey: "v2.polish.minLength")
        return Settings(
            enabled: d.bool(forKey: "v2.polish.enabled"),
            apiKey: d.string(forKey: "v2.polish.apiKey") ?? "",
            model: d.string(forKey: "v2.polish.model") ?? "gpt-4o-mini",
            customInstruction: d.string(forKey: "v2.polish.instruction") ?? "",
            minLength: minRaw > 0 ? minRaw : 80
        )
    }

    static func saveSettings(_ s: Settings) {
        let d = UserDefaults.standard
        d.set(s.enabled, forKey: "v2.polish.enabled")
        d.set(s.apiKey, forKey: "v2.polish.apiKey")
        d.set(s.model, forKey: "v2.polish.model")
        d.set(s.customInstruction, forKey: "v2.polish.instruction")
        d.set(s.minLength, forKey: "v2.polish.minLength")
    }

    // Returns the polished text + any candidate terms the model surfaced.
    // On any failure (offline, bad key, malformed JSON) returns the original text and no candidates.
    static func polish(text: String, terms: [String], settings: Settings) async -> Result {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.enabled,
              !settings.apiKey.isEmpty,
              trimmed.count >= settings.minLength
        else { return Result(text: text, candidates: []) }

        let system = systemPrompt(terms: terms, extra: settings.customInstruction)
        let body: [String: Any] = [
            "model": settings.model,
            "temperature": 0.2,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text],
            ],
        ]

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions"),
              let payload = try? JSONSerialization.data(withJSONObject: body)
        else { return Result(text: text, candidates: []) }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = payload

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                if let http = resp as? HTTPURLResponse {
                    let bodyStr = String(data: data, encoding: .utf8) ?? ""
                    print("[Polisher] HTTP \(http.statusCode): \(bodyStr.prefix(200))")
                }
                return Result(text: text, candidates: [])
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String,
                  let contentData = content.data(using: .utf8),
                  let parsed = try JSONSerialization.jsonObject(with: contentData) as? [String: Any]
            else {
                print("[Polisher] failed to parse JSON envelope")
                return Result(text: text, candidates: [])
            }

            let polishedText = (parsed["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let finalText = polishedText.isEmpty ? text : polishedText

            var candidates: [Candidate] = []
            if let arr = parsed["candidates"] as? [[String: Any]] {
                for item in arr {
                    let canon = (item["canonical"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let raw = (item["raw"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !canon.isEmpty {
                        candidates.append(Candidate(canonical: canon, raw: raw))
                    }
                }
            }
            return Result(text: finalText, candidates: candidates)
        } catch {
            print("[Polisher] error: \(error)")
            return Result(text: text, candidates: [])
        }
    }

    private static func systemPrompt(terms: [String], extra: String) -> String {
        var lines = [
            "Ты редактируешь сырой текст голосовой диктовки на русском языке.",
            "Задачи: расставить знаки препинания, разбить на логические абзацы, убрать слова-паразиты (эээ, ну вот, как бы), починить очевидные оговорки.",
            "ЗАПРЕЩЕНО: менять смысл, переписывать своими словами, добавлять то, чего автор не говорил, сокращать содержательные части.",
            "Сохраняй авторский стиль и лексику. Если фраза разговорная — оставь её разговорной.",
            "Не добавляй заголовки, маркированные списки, подписи.",
            "",
            "Также найди в тексте НЕОЧЕВИДНЫЕ собственные имена: бренды, продукты, технические термины, имена компаний или специфичных людей.",
            "НЕ включай: обычные русские имена (Маша, Петя, Аня), названия городов, обычные нарицательные слова.",
            "Если такой термин в сыром тексте звучал криво — укажи raw в том виде, как он услышан.",
            "Если термин и так написан правильно — raw = canonical.",
        ]
        if !terms.isEmpty {
            let joined = terms.joined(separator: ", ")
            lines.append("Уже известный словарь (НЕ дублируй эти термины в candidates и пиши их строго в этой форме): \(joined).")
        }
        let extraTrim = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extraTrim.isEmpty {
            lines.append("Дополнительно от пользователя: \(extraTrim)")
        }
        lines.append("")
        lines.append("Ответ строго в формате JSON, без markdown, без комментариев:")
        lines.append("{\"text\": \"отредактированный текст\", \"candidates\": [{\"canonical\": \"Charge 5\", \"raw\": \"чардж 5\"}]}")
        lines.append("Если кандидатов нет — \"candidates\": [].")
        return lines.joined(separator: "\n")
    }
}
