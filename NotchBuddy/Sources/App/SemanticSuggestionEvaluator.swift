import Foundation
import AppKit
import SwiftUI

// MARK: - Semantic Evaluator Output

public struct SemanticEvaluatorOutput: Codable, Sendable {
    public let shouldSuggest: Bool
    public let matchedCapabilityId: String?
    public let icon: String?
    public let title: String?
    public let detail: String?
    public let actionQuery: String?
}

// MARK: - Semantic Suggestion Evaluator (Zero Hardcode Intelligence)
// Evaluates incoming events (notifications, downloads, emails, etc.) against
// dynamically registered capabilities without hardcoded if/else rules.
@MainActor
public final class SemanticSuggestionEvaluator: ObservableObject {
    public static let shared = SemanticSuggestionEvaluator()

    private var isEvaluating = false
    private var dismissTimer: Timer?
    private var recentTitles: [String] = []

    private init() {}

    // MARK: - Evaluation Entry Point

    func evaluate(event: InputEvent, state: AppState) async {
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }

        let capabilitiesManifest = CapabilityRegistry.shared.promptManifest()

        let systemPrompt = """
        You are Coucou's Proactive Intelligent Observer on macOS.
        A new event or input just occurred on the user's machine.
        Your job is to determine if Coucou should offer a high-value, proactive quick action to help the user.

        REGISTERED CAPABILITIES (DYNAMIC MANIFEST):
        \(capabilitiesManifest)

        GUIDELINES:
        1. "shouldSuggest": true ONLY if the event contains actionable information (e.g. an email needing summarization, an invoice/receipt to record, a meeting to schedule, a downloaded archive to extract/organize, an error to diagnose, a PR to review).
        2. "shouldSuggest": false for trivial social pings, marketing ads, standard system notifications with no action needed.
        3. "title": Maximum 2-3 words ONLY (displayed in a compact Dynamic Island Notch, e.g. "Lưu hoá đơn", "Tóm tắt mail", "Tạo lịch hẹn", "Sắp xếp file").
        4. "detail": Maximum 4-6 words (under 28 chars, e.g. "Hóa đơn EVN 850k", "Email từ đối tác", "File zip vừa tải"). NEVER write a sentence.
        5. "actionQuery": A complete, explicit instruction prompt for Coucou's AI agent to execute when the user clicks 'Thực hiện'. Include key identifiers or context from the event.
        6. Language: Match Vietnamese if context is Vietnamese, English if English.

        Respond with valid JSON only, NO markdown fences:
        {
          "shouldSuggest": true or false,
          "matchedCapabilityId": "id from registered capabilities or null",
          "icon": "valid SF Symbol name (e.g. creditcard.fill, doc.text.magnifyingglass, calendar.badge.plus, folder.badge.gearshape)",
          "title": "2-3 words",
          "detail": "4-6 words",
          "actionQuery": "Prompt for agent"
        }
        """

        var eventDetails = "Event Source: \(event.source.rawValue)\nApp: \(event.appName)\nTitle: \"\(event.title)\""
        if !event.metadata.isEmpty {
            eventDetails += "\nMetadata: \(event.metadata)"
        }
        if !event.content.isEmpty {
            eventDetails += "\nContent Snippet:\n\(event.content.prefix(2500))"
        }

        logSentinel("Semantic Evaluator checking event from [\(event.appName)]: \"\(event.title)\"")

        guard let output = await queryModels(system: systemPrompt, prompt: eventDetails) else {
            return
        }

        guard output.shouldSuggest,
              let rawTitle = output.title, !rawTitle.isEmpty,
              let action = output.actionQuery, !action.isEmpty else {
            return
        }

        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count > 24 { title = String(title.prefix(22)) + "…" }

        var detail = output.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = detail, d.count > 32 { detail = String(d.prefix(30)) + "…" }

        // Anti-repetition check
        if recentTitles.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) {
            return
        }
        recentTitles.append(title)
        if recentTitles.count > 10 { recentTitles.removeFirst() }

        let icon = output.icon ?? "sparkles"
        let promptCtx: PromptContext = .window(
            appName: event.appName,
            title: event.title,
            url: event.metadata["url"]
        )

        let suggestion = ProactiveSuggestion(
            icon: icon,
            title: title,
            detail: detail,
            actionQuery: action,
            context: promptCtx
        )

        presentSuggestion(suggestion, state: state)
    }

    // MARK: - UI Presentation

    private func presentSuggestion(_ suggestion: ProactiveSuggestion, state: AppState) {
        logSentinel("Semantic Evaluator triggered suggestion: \"\(suggestion.title)\" - \"\(suggestion.detail ?? "")\"")

        let low = (suggestion.title + " " + suggestion.actionQuery).lowercased()
        let emote: BotEmote
        let particle: Particle.ParticleType?

        if low.contains("lưu") || low.contains("hoá đơn") || low.contains("tiền") || low.contains("giao dịch") {
            emote = .proud
            particle = .star
        } else if low.contains("tóm tắt") || low.contains("email") || low.contains("mail") {
            emote = .wink
            particle = .spark
        } else if low.contains("lỗi") || low.contains("error") || low.contains("fix") {
            emote = .surprised
            particle = .sweat
        } else if low.contains("lịch") || low.contains("họp") || low.contains("calendar") {
            emote = .happy
            particle = nil
        } else {
            emote = .happy
            particle = nil
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
            state.proactiveSuggestion = suggestion
            SoundEngine.shared.play("pop")
            NotificationCenter.default.post(name: .triggerEmote, object: emote)
            if let p = particle {
                NotificationCenter.default.post(name: .botParticle, object: p)
            }
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        }

        // Auto-dismiss after 15 seconds if ignored
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak state] _ in
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.3)) {
                    state?.proactiveSuggestion = nil
                    if state?.mode != .expanded {
                        state?.mode = .compact
                    }
                }
            }
        }
    }

    // MARK: - Multi-model Query Chain

    private func queryModels(system: String, prompt: String) async -> SemanticEvaluatorOutput? {
        // 1. Local Ollama (0 cost, 100% on-device privacy for emails/invoices)
        if let localResult = await callOllamaEvaluator(system: system, prompt: prompt) {
            return localResult
        }

        // 2. Anthropic Claude (Haiku 3.5 ~0.8s)
        if let key = KeychainStore.shared.get("anthropic-api-key"), !key.isEmpty {
            if let result = await callAnthropicEvaluator(system: system, prompt: prompt, apiKey: key) {
                return result
            }
        }

        // 3. OpenAI (gpt-4o-mini)
        if let key = KeychainStore.shared.get("openai-api-key"), !key.isEmpty {
            if let result = await callOpenAIEvaluator(system: system, prompt: prompt, apiKey: key) {
                return result
            }
        }

        // 4. Google Gemini
        if let key = KeychainStore.shared.get("google-api-key"), !key.isEmpty {
            if let result = await callGoogleEvaluator(system: system, prompt: prompt, apiKey: key) {
                return result
            }
        }

        return nil
    }

    // MARK: - API Callers

    private func callOllamaEvaluator(system: String, prompt: String) async -> SemanticEvaluatorOutput? {
        guard let url = URL(string: "http://127.0.0.1:11434/v1/chat/completions") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 2.5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "llama3.2:latest",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": prompt]
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0.1
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data

        do {
            let (resData, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return parseChatOutput(resData)
        } catch {
            return nil
        }
    }

    private func callAnthropicEvaluator(system: String, prompt: String, apiKey: String) async -> SemanticEvaluatorOutput? {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3.5
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": "claude-3-5-haiku-20241022",
            "max_tokens": 250,
            "system": system + "\nOutput raw JSON without markdown fences.",
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.1
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data

        do {
            let (resData, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            guard let root = try? JSONSerialization.jsonObject(with: resData) as? [String: Any],
                  let content = root["content"] as? [[String: Any]],
                  let first = content.first,
                  let text = first["text"] as? String else {
                return nil
            }
            return cleanAndParse(text)
        } catch {
            return nil
        }
    }

    private func callOpenAIEvaluator(system: String, prompt: String, apiKey: String) async -> SemanticEvaluatorOutput? {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3.5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": prompt]
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0.1,
            "max_tokens": 200
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data

        do {
            let (resData, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return parseChatOutput(resData)
        } catch {
            return nil
        }
    }

    private func callGoogleEvaluator(system: String, prompt: String, apiKey: String) async -> SemanticEvaluatorOutput? {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=\(apiKey)") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3.5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": [
                "response_mime_type": "application/json",
                "temperature": 0.1
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data

        do {
            let (resData, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            guard let root = try? JSONSerialization.jsonObject(with: resData) as? [String: Any],
                  let candidates = root["candidates"] as? [[String: Any]],
                  let cand = candidates.first,
                  let content = cand["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String else {
                return nil
            }
            return cleanAndParse(text)
        } catch {
            return nil
        }
    }

    // MARK: - Parsing Helpers

    private func parseChatOutput(_ data: Data) -> SemanticEvaluatorOutput? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = msg["content"] as? String else {
            return nil
        }
        return cleanAndParse(text)
    }

    private func cleanAndParse(_ text: String) -> SemanticEvaluatorOutput? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawData = cleaned.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SemanticEvaluatorOutput.self, from: rawData)
    }
}
