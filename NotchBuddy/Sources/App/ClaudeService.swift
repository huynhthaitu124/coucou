import Foundation
import Security
import AppKit
import CoreGraphics
import Vision

// MARK: - Keychain helpers

enum Keychain {
    static let service = "fr.louisraille.NotchBuddy"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        // Delete existing item first (update pattern)
        let lookup: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(lookup as CFDictionary)
        // Add with strictest access control:
        // WhenUnlockedThisDeviceOnly = accessible only while Mac is unlocked,
        // never synced to iCloud, never migrated to another device.
        let item: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      key,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse!,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Keychain cache (reads each key ONCE at launch; all subsequent access via dict)

final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore()
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    private static let allKeys = [
        "anthropic-api-key",
        "google-api-key",
        "openai-api-key",
        "resend-api-key", "resend-from",
        "n8n-url", "n8n-api-key",
        "vercel-token",
        "github-token",
        "stripe-api-key",
        "calcom-api-key",
        "notion-api-key",
    ]

    private init() {
        // Called once, on main thread (AppDelegate triggers shared at launch).
        for key in Self.allKeys {
            if let v = Keychain.load(key: key) { cache[key] = v }
        }
    }

    /// Thread-safe read — never touches the Keychain.
    func get(_ key: String) -> String? {
        lock.withLock { cache[key] }
    }

    /// Updates cache + persists to Keychain.
    func set(_ key: String, value: String) {
        lock.withLock { cache[key] = value }
        Keychain.save(key: key, value: value)
    }

    /// Removes from cache + Keychain only if the key was previously set.
    func remove(_ key: String) {
        let had = lock.withLock { () -> Bool in
            let exists = cache[key] != nil
            cache[key] = nil
            return exists
        }
        if had { Keychain.delete(key: key) }
    }
}

// MARK: - Claude API

@MainActor
final class ClaudeService {
    static let shared = ClaudeService()

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let anthropicVersion = "2023-06-01"

    // MARK: - Model list

    /// Fetches available models from the Anthropic API in the order the API returns them
    /// (newest first). Returns an empty array on any error — callers fall back to a static list.
    static func fetchModels(apiKey: String) async -> [(id: String, label: String)] {
        guard let url = URL(string: "https://api.anthropic.com/v1/models?limit=100") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? String,
                  let name = item["display_name"] as? String else { return nil }
            return (id: id, label: name)
        }
    }

    /// Fetches Gemini models via the OpenAI-compatible endpoint.
    /// Strips the "models/" prefix that the API sometimes returns and filters non-chat models.
    static func fetchGoogleModels(apiKey: String) async -> [(id: String, label: String)] {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/models") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        let excluded = ["embed", "imagen", "veo", "aqa", "tts", "audio", "live"]
        return items.compactMap { item in
            guard let raw = item["id"] as? String else { return nil }
            let id = raw.hasPrefix("models/") ? String(raw.dropFirst(7)) : raw
            let lower = id.lowercased()
            guard !excluded.contains(where: { lower.contains($0) }) else { return nil }
            return (id: id, label: id)
        }
    }

    /// Fetches chat models from the OpenAI API, sorted newest-first by creation date.
    /// Excludes non-chat model families.
    static func fetchOpenAIModels(apiKey: String) async -> [(id: String, label: String)] {
        guard let url = URL(string: "https://api.openai.com/v1/models") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }
        let excluded = ["embed", "tts", "whisper", "dall-e", "audio", "realtime", "moderat",
                        "codex", "computer-use", "transcribe", "image", "sora",
                        "babbage", "davinci", "instruct"]
        return items
            .compactMap { item -> (id: String, created: Int)? in
                guard let id = item["id"] as? String else { return nil }
                let lower = id.lowercased()
                guard !excluded.contains(where: { lower.contains($0) }) else { return nil }
                return (id: id, created: item["created"] as? Int ?? 0)
            }
            .sorted { $0.created > $1.created }
            .map { (id: $0.id, label: $0.id) }
    }

    /// Chosen in Settings; falls back to the default when the field is left empty.
    private var model: String {
        let m = AppState.shared.claudeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? AppState.defaultClaudeModel : m
    }

    var apiKey: String? { KeychainStore.shared.get("anthropic-api-key") }

    // Multi-turn conversation messages (for API)
    private var conversationMessages: [[String: Any]] = []

    func clearConversation() {
        conversationMessages = []
    }

    func restoreConversation(messages: [ChatMessage]) {
        conversationMessages = messages.map { msg in
            let role = (msg.role == .user) ? "user" : "assistant"
            return ["role": role, "content": msg.content]
        }
    }

    private let systemPrompt = """
    You are Coucou, a lightweight desktop assistant embedded in the user's Mac notch.

    PRIMARY CAPABILITIES:
    1. Answer questions directly, clearly, and concisely.
    2. Understand screen & file context: You receive real-time ambient context of the active macOS application, window title, active browser URL, or attached files. Use this context naturally to answer questions or perform actions.
    3. Perform computer tasks using your local tools:
       - `press_ui_element`: Click or activate a UI button, menu item, or control by its text/title (e.g. 'Connect', 'Build', 'Run', 'Submit', 'Cancel'). Automatically resolves exact screen center coordinates via Accessibility tree or Vision OCR fallback. PREFER THIS tool whenever you want to click a named button or control on screen!
       - `inspect_window`: Inspect the active macOS window or any app to read its title, URL, visible text, editor content, and UI controls with precise screen coordinates [center: (x, y)]. PREFER THIS over screenshot.
       - `computer_action`: Mouse clicks, typing, and keyboard shortcuts. When clicking coordinates (`click`, `double_click`), ONLY use [center: (x, y)] coordinates obtained from `inspect_window`. NEVER make up or guess random coordinates (e.g. 300, 180).
       - `bash`: Quick shell commands (e.g. check battery, disk space, find files, ps/kill, git status, open apps, inspect files).
       - `applescript`: Control native macOS apps (Finder, Music, Safari, active window, System Events).
       - `read_file` / `write_file`: Quick file inspections or edits.

    CREDIT SAVING & BEHAVIOR RULES:
    - To click or interact with UI buttons/controls: ALWAYS prefer `press_ui_element(title: ...)` directly, OR call `inspect_window` first to obtain the exact `[center: (x, y)]` coordinates before calling `computer_action`. NEVER guess coordinates!
    - To understand what the user is looking at or doing in an app (like Antigravity IDE, Xcode, Chrome, RustDesk), ALWAYS use `inspect_window` instead of `screenshot`.
    - KEEP RESPONSES SHORT AND DIRECT. Avoid preamble, excessive explanations, or long code blocks unless explicitly requested.
    - NEVER say "I cannot access your Mac" or ask the user to open Terminal. Execute simple tasks directly using your tools.
    - Do NOT write lengthy code or complex multi-file programming projects. Keep answers focused.
    - Always respond in the user's language (e.g. Vietnamese if asked in Vietnamese).
    """

    private let webSearchTools: [[String: Any]] = [
        ["type": "web_search_20250305", "name": "web_search", "max_uses": 5]
    ]

    // MARK: - Chat (multi-turn, natural text + web search)

    func chat(query: String, context: PromptContext?, state: AppState) async {
        guard state.chatProvider == .anthropic else {
            await chatOpenAICompatible(query: query, context: context, state: state)
            return
        }
        guard let key = apiKey, !key.isEmpty else {
            await showError("API key missing. Open settings.", state: state)
            return
        }

        // Build user content for this turn
        var userContent: [[String: Any]] = []

        // Add file/window context
        if let context = context {
            switch context {
            case .window(let app, let title, let url):
                var parts: [String] = []
                if !app.isEmpty { parts.append("App: \(app)") }
                if !title.isEmpty && title != app { parts.append("Window: \"\(title)\"") }
                if let url = url, !url.isEmpty { parts.append("URL: \(url)") }
                if !parts.isEmpty {
                    userContent.append(["type": "text", "text": "[Active Context: \(parts.joined(separator: " | "))]"])
                }
            case .file(let name, let fileURL):
                if let fileURL = fileURL, let block = readFileAsBlock(url: fileURL) {
                    userContent.append(block)
                }
                var fileDesc = "File: \(name)"
                if let path = fileURL?.path { fileDesc += " (Path: \(path))" }
                userContent.append(["type": "text", "text": fileDesc])
            case .clipboard(let sourceApp, let sourceTitle, let sourceURL, let snippet):
                var parts: [String] = []
                if !sourceApp.isEmpty { parts.append("Source App: \(sourceApp)") }
                if !sourceTitle.isEmpty && sourceTitle != sourceApp { parts.append("Window: \"\(sourceTitle)\"") }
                if let u = sourceURL, !u.isEmpty { parts.append("URL: \(u)") }
                var clipText = "[Active Clipboard Context: \(parts.joined(separator: " | "))]\n"
                clipText += "[Copied Content:\n\(snippet)\n--- End of Copied Content ---]"
                userContent.append(["type": "text", "text": clipText])
            }
        }
        userContent.append(["type": "text", "text": query])

        conversationMessages.append(["role": "user", "content": userContent])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "tools": webSearchTools,
            "system": systemPrompt,
            "messages": conversationMessages,
        ]

        do {
            let data = try await callAPI(body: body, key: key, beta: "web-search-2025-03-05")
            await handleChatResult(data, state: state)
        } catch {
            conversationMessages.removeLast()
            await showError(error.localizedDescription, state: state)
        }
    }

    private func parseToolStep(name: String, argsString: String) -> (title: String, detail: String?) {
        let argsData = argsString.data(using: .utf8) ?? Data()
        let args = (try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]) ?? [:]

        switch name {
        case "bash":
            let cmd = (args["command"] as? String) ?? argsString
            let shortCmd = String(cmd.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
            return ("Chạy lệnh Terminal", shortCmd)
        case "applescript":
            let script = (args["script"] as? String) ?? argsString
            let firstLine = script.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? script
            return ("Chạy AppleScript", String(firstLine.prefix(50)))
        case "read_file":
            let path = (args["path"] as? String) ?? argsString
            let filename = (path as NSString).lastPathComponent
            return ("Đọc file", filename)
        case "write_file":
            let path = (args["path"] as? String) ?? argsString
            let filename = (path as NSString).lastPathComponent
            return ("Ghi file", filename)
        case "screenshot":
            return ("Chụp màn hình", nil)
        case "computer_action":
            let action = (args["action"] as? String) ?? "click"
            let coord = (args["coordinate"] as? [NSNumber])?.map { "\(Int($0.doubleValue))" }.joined(separator: ",")
            let text = args["text"] as? String
            switch action {
            case "click", "left_click":
                return ("Click chuột", coord.map { "(\($0))" })
            case "right_click":
                return ("Click phải", coord.map { "(\($0))" })
            case "double_click":
                return ("Double click", coord.map { "(\($0))" })
            case "type":
                return ("Nhập văn bản", text.map { String($0.prefix(30)) })
            case "key":
                return ("Phím tắt", args["key"] as? String)
            case "scroll":
                return ("Cuộn trang", nil)
            default:
                return ("Thao tác máy", action)
            }
        case "inspect_window":
            let app = (args["app_name"] as? String)
            return ("Đọc cửa sổ", app)
        case "press_ui_element":
            let title = (args["title"] as? String) ?? ""
            return ("Bấm nút UI", title)
        case "key_combo":
            let combo = (args["combo"] as? String) ?? ""
            return ("Phím tắt", combo)
        case "browser_eval":
            let js = (args["javascript"] as? String) ?? ""
            // Summarize the JS action intelligently
            if js.contains("click") { return ("Click phần tử web", nil) }
            if js.contains("querySelector") || js.contains("getElement") { return ("Đọc nội dung trang", nil) }
            if js.contains("window.location") || js.contains("navigate") { return ("Điều hướng trang", nil) }
            if js.contains("value") && js.contains("=") { return ("Nhập form", nil) }
            return ("Chạy JS trên trình duyệt", nil)
        case "browser_open":
            let target = (args["target"] as? String) ?? (args["url"] as? String) ?? ""
            return ("Mở trang web", String(target.prefix(45)))
        case "browser_list_tabs":
            return ("Kiểm tra các tab web", nil)
        case "browser_get_content":
            let kw = args["tab_keyword"] as? String
            return ("Đọc nội dung trang web", kw)
        case "window_control":
            let action = (args["action"] as? String) ?? ""
            let app = args["app_name"] as? String
            if action == "activate" { return ("Mở ứng dụng", app) }
            return ("Quản lý cửa sổ", action)
        default:
            return (name, nil)
        }
    }

    // MARK: - OpenAI-compatible chat (Google Gemini / OpenAI) with Streaming & Low Credit Optimization

    func chatOpenAICompatible(query: String, context: PromptContext?, state: AppState) async {
        let provider = state.chatProvider
        guard provider != .anthropic else { return }
        guard let key = KeychainStore.shared.get(provider.keychainKey), !key.isEmpty else {
            await showError("\(provider.displayName) API key missing. Configure it in Settings.", state: state)
            return
        }

        let baseURL: String
        switch provider {
        case .google:  baseURL = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        case .openai:  baseURL = "https://api.openai.com/v1/chat/completions"
        case .anthropic: return
        }
        guard let url = URL(string: baseURL) else { return }

        // Build messages: system + recent conversation history (last 6 to minimize input credit) + new user turn
        var msgs: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        let recentHistory = conversationMessages.suffix(6)
        for m in recentHistory {
            var simplified = m
            if let content = m["content"] as? [[String: Any]],
               let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
               let text = textBlock["text"] as? String {
                simplified["content"] = text
            }
            msgs.append(simplified)
        }

        // Add user message with active context (window or file)
        var contextPrefix = ""
        if let ctx = context {
            switch ctx {
            case .window(let app, let title, let url):
                var parts: [String] = []
                if !app.isEmpty { parts.append("App: \(app)") }
                if !title.isEmpty && title != app { parts.append("Window: \"\(title)\"") }
                if let u = url, !u.isEmpty { parts.append("URL: \(u)") }
                if !parts.isEmpty {
                    contextPrefix = "[Active Window Context: \(parts.joined(separator: " | "))]\n"
                }
            case .file(let name, let fileURL):
                var fileInfo = "[Context: Attached File \"\(name)\""
                if let path = fileURL?.path {
                    fileInfo += " | Path: \(path)"
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
                       let text = String(data: data.prefix(10000), encoding: .utf8), !text.isEmpty {
                        fileInfo += "]\n[File Content Preview:\n\(text)\n--- End of File Preview ---"
                    }
                }
                fileInfo += "]\n"
                contextPrefix = fileInfo
            case .clipboard(let sourceApp, let sourceTitle, let sourceURL, let snippet):
                var parts: [String] = []
                if !sourceApp.isEmpty { parts.append("Source App: \(sourceApp)") }
                if !sourceTitle.isEmpty && sourceTitle != sourceApp { parts.append("Window: \"\(sourceTitle)\"") }
                if let u = sourceURL, !u.isEmpty { parts.append("URL: \(u)") }
                contextPrefix = "[Active Clipboard Context: \(parts.joined(separator: " | "))]\n[Copied Content:\n\(snippet)\n--- End of Copied Content ---]\n"
            }
        }
        // 0. Create initial placeholder with Jev Fast-Path step in UI
        let jevStep = AssistantWorkStep(
            tool: "jev",
            title: "Jev Fast-Path",
            detail: "Đang định tuyến...",
            isDone: false
        )
        let messageIndex = await MainActor.run { () -> Int in
            state.stateOverride = .working
            let msg = ChatMessage(role: .assistant, content: "", thinking: nil, steps: [jevStep], isRunning: true)
            state.chatHistory.append(msg)
            return state.chatHistory.count - 1
        }

        // Fast-path decision via SystemOne Engine (sub-30ms non-autoregressive routing)
        let systemOneDecision = await SystemOneEngine.shared.decideAction(query: query, context: context)

        // Update Jev step with outcome
        await MainActor.run {
            if messageIndex < state.chatHistory.count, !state.chatHistory[messageIndex].steps.isEmpty {
                state.chatHistory[messageIndex].steps[0].isDone = true
                state.chatHistory[messageIndex].steps[0].detail = "\(systemOneDecision.sourceEngine) · \(String(format: "%.1f", systemOneDecision.executionTimeMs))ms"
            }
        }

        if systemOneDecision.action == .keyCombo, let target = systemOneDecision.target, systemOneDecision.confidence >= 0.90 {
            let step = AssistantWorkStep(tool: "key_combo", title: "Phím tắt", detail: target.uppercased(), isDone: false)
            await MainActor.run {
                if messageIndex < state.chatHistory.count {
                    state.chatHistory[messageIndex].steps.append(step)
                }
            }
            _ = await ComputerUseHarness.executeKeyCombo(combo: target)
            let answer = "Đã thực hiện phím tắt \(target.uppercased()) qua Jev/SystemOne."
            conversationMessages.append(["role": "assistant", "content": answer])
            await MainActor.run {
                if messageIndex < state.chatHistory.count {
                    if let lastIdx = state.chatHistory[messageIndex].steps.indices.last {
                        state.chatHistory[messageIndex].steps[lastIdx].isDone = true
                    }
                    state.chatHistory[messageIndex].content = answer
                    state.chatHistory[messageIndex].isRunning = false
                    state.chatHistory[messageIndex].durationSeconds = 1
                    state.chatHistory[messageIndex].creditsUsed = 0.0
                }
                state.stateOverride = nil
                state.view = .prompt
                state.archiveCurrentSession()
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            }
            return
        }

        if systemOneDecision.action == .runShell, systemOneDecision.confidence >= 0.90, let shellCmd = systemOneDecision.target, !shellCmd.isEmpty {
            let step = AssistantWorkStep(tool: "bash", title: "Chạy lệnh Terminal", detail: shellCmd, isDone: false)
            await MainActor.run {
                if messageIndex < state.chatHistory.count {
                    state.chatHistory[messageIndex].steps.append(step)
                }
            }
            let output = await ComputerUseHarness.runBash(command: shellCmd, cwd: nil)
            let answer = output.trimmingCharacters(in: .whitespacesAndNewlines)
            conversationMessages.append(["role": "assistant", "content": answer])
            await MainActor.run {
                if messageIndex < state.chatHistory.count {
                    if let lastIdx = state.chatHistory[messageIndex].steps.indices.last {
                        state.chatHistory[messageIndex].steps[lastIdx].isDone = true
                    }
                    state.chatHistory[messageIndex].content = answer
                    state.chatHistory[messageIndex].isRunning = false
                    state.chatHistory[messageIndex].durationSeconds = 1
                    state.chatHistory[messageIndex].creditsUsed = 0.0
                }
                state.stateOverride = nil
                state.view = .prompt
                state.archiveCurrentSession()
                NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
            }
            return
        }

        if systemOneDecision.action == .inspectWindow, systemOneDecision.confidence >= 0.90 {
            let detailText = systemOneDecision.target ?? "Ngữ cảnh màn hình"
            let step = AssistantWorkStep(tool: "inspect_window", title: "Đọc cửa sổ", detail: detailText, isDone: false)
            await MainActor.run {
                if messageIndex < state.chatHistory.count {
                    state.chatHistory[messageIndex].steps.append(step)
                }
            }
            let fastWindowInfo = await ComputerUseHarness.inspectActiveWindow(appName: systemOneDecision.target)
            contextPrefix += "\n[SystemOne Pre-fetched Window:\n\(fastWindowInfo)\n]\n"
            await MainActor.run {
                if messageIndex < state.chatHistory.count, let lastIdx = state.chatHistory[messageIndex].steps.indices.last {
                    state.chatHistory[messageIndex].steps[lastIdx].isDone = true
                }
            }
        }

        let userText = contextPrefix.isEmpty ? query : "\(contextPrefix)\n\(query)"
        msgs.append(["role": "user", "content": userText])
        conversationMessages.append(["role": "user", "content": userText])

        // Add thinking step for LLM reasoning
        let thinkingStep = AssistantWorkStep(tool: "thinking", title: "Đang đọc câu hỏi & suy nghĩ", detail: nil, isDone: false)
        await MainActor.run {
            if messageIndex < state.chatHistory.count {
                state.chatHistory[messageIndex].steps.append(thinkingStep)
            }
        }

        // Multi-turn tool execution loop (up to 8 iterations per query)
        var consecutiveBrowserEvalCount = 0
        var totalTokensEstimated = 0
        for iteration in 0..<8 {
            var body: [String: Any] = [
                "model": state.activeChatModel,
                "messages": msgs,
                "tools": ComputerUseHarness.openAIToolDefinitions,
                "stream": true,
                "stream_options": ["include_usage": true],
                "temperature": 0.2,
            ]
            if provider == .openai {
                body["reasoning_effort"] = "none"
                body["max_completion_tokens"] = 1024
            } else {
                body["max_tokens"] = 1024
            }

            var req = URLRequest(url: url, timeoutInterval: 120)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)

            do {
                let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NSError(domain: "ChatAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
                }
                guard httpResponse.statusCode == 200 else {
                    var errData = Data()
                    for try await byte in asyncBytes {
                        errData.append(byte)
                    }
                    if let json = try? JSONSerialization.jsonObject(with: errData) as? [String: Any],
                       let err = (json["error"] as? [String: Any])?["message"] as? String {
                        throw NSError(domain: "ChatAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: err])
                    }
                    throw NSError(domain: "ChatAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"])
                }

                var accumulatedContent = ""
                var accumulatedThinking = ""
                var streamedTools: [Int: (id: String, name: String, args: String)] = [:]

                for try await line in asyncBytes.lines {
                    let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmedLine.hasPrefix("data:") else { continue }
                    let payload = trimmedLine.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                    if payload == "[DONE]" { break }

                    guard let chunkData = payload.data(using: .utf8),
                          let chunkJson = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] else {
                        continue
                    }

                    if let usage = chunkJson["usage"] as? [String: Any],
                       let total = usage["total_tokens"] as? Int {
                        totalTokensEstimated = total
                    }

                    guard let choices = chunkJson["choices"] as? [[String: Any]],
                          let firstChoice = choices.first,
                          let delta = firstChoice["delta"] as? [String: Any] else {
                        continue
                    }

                    // 1. Stream thinking / reasoning tokens
                    if let thinkChunk = (delta["reasoning_content"] as? String) ?? (delta["thought"] as? String), !thinkChunk.isEmpty {
                        accumulatedThinking += thinkChunk
                        let thinkText = accumulatedThinking
                        await MainActor.run {
                            if messageIndex < state.chatHistory.count {
                                state.chatHistory[messageIndex].thinking = thinkText
                            }
                        }
                    }

                    // 2. Stream content tokens
                    if let textChunk = delta["content"] as? String, !textChunk.isEmpty {
                        accumulatedContent += textChunk
                        let text = accumulatedContent
                        await MainActor.run {
                            if messageIndex < state.chatHistory.count {
                                state.chatHistory[messageIndex].content = text
                                for i in 0..<state.chatHistory[messageIndex].steps.count {
                                    state.chatHistory[messageIndex].steps[i].isDone = true
                                }
                            }
                        }
                    }

                    // 3. Accumulate streamed tool calls
                    if let tcChunks = delta["tool_calls"] as? [[String: Any]] {
                        for tc in tcChunks {
                            guard let idx = tc["index"] as? Int else { continue }
                            if streamedTools[idx] == nil {
                                streamedTools[idx] = (id: "", name: "", args: "")
                            }
                            if let id = tc["id"] as? String {
                                streamedTools[idx]?.id += id
                            }
                            if let fn = tc["function"] as? [String: Any] {
                                if let name = fn["name"] as? String {
                                    streamedTools[idx]?.name += name
                                }
                                if let args = fn["arguments"] as? String {
                                    streamedTools[idx]?.args += args
                                }
                            }
                        }
                    }
                }

                // If tool calls were emitted, execute them and continue the loop
                if !streamedTools.isEmpty {
                    let sortedTools = streamedTools.keys.sorted().compactMap { streamedTools[$0] }
                    var toolCallsPayload: [[String: Any]] = []

                    for (idx, tc) in sortedTools.enumerated() {
                        let toolId = tc.id.isEmpty ? "call_\(idx)" : tc.id
                        toolCallsPayload.append([
                            "id": toolId,
                            "type": "function",
                            "function": [
                                "name": tc.name,
                                "arguments": tc.args
                            ]
                        ])
                    }

                    var assistantMsg: [String: Any] = [
                        "role": "assistant",
                        "tool_calls": toolCallsPayload
                    ]
                    if !accumulatedContent.isEmpty {
                        assistantMsg["content"] = accumulatedContent
                    }
                    msgs.append(assistantMsg)

                    // Detect repetitive browser_eval loops (e.g. model stuck on 404 pages)
                    let allBrowserEval = sortedTools.allSatisfy { $0.name == "browser_eval" }
                    if allBrowserEval {
                        consecutiveBrowserEvalCount += 1
                    } else {
                        consecutiveBrowserEvalCount = 0
                    }

                    // Execute each tool and update the live work trail
                    for tc in sortedTools {
                        let toolId = tc.id.isEmpty ? "call_0" : tc.id
                        let argsData = tc.args.data(using: .utf8) ?? Data()
                        let args = (try? JSONSerialization.jsonObject(with: argsData) as? [String: Any]) ?? [:]

                        let parsed = self.parseToolStep(name: tc.name, argsString: tc.args)
                        let step = AssistantWorkStep(tool: tc.name, title: parsed.title, detail: parsed.detail, isDone: false)

                        await MainActor.run {
                            state.stateOverride = .working
                            if messageIndex < state.chatHistory.count {
                                for i in 0..<state.chatHistory[messageIndex].steps.count {
                                    state.chatHistory[messageIndex].steps[i].isDone = true
                                }
                                state.chatHistory[messageIndex].steps.append(step)
                            }
                            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.wink)
                        }

                        coucouLog("[Agent Step] Executing tool: \(tc.name) args: \(tc.args.prefix(200))")
                        let output = await ComputerUseHarness.execute(name: tc.name, arguments: args)
                        coucouLog("[Agent Step] Tool '\(tc.name)' result: \(output.prefix(200))")

                        await MainActor.run {
                            if messageIndex < state.chatHistory.count,
                               let lastIdx = state.chatHistory[messageIndex].steps.indices.last {
                                state.chatHistory[messageIndex].steps[lastIdx].isDone = true
                            }
                        }

                        msgs.append([
                            "role": "tool",
                            "tool_call_id": toolId,
                            "name": tc.name,
                            "content": output
                        ])
                    }

                    // Rescue if model is stuck in a browser_eval loop
                    if consecutiveBrowserEvalCount >= 3 {
                        let fallbackContent = await ComputerUseHarness.getBrowserTabContent()
                        msgs.append([
                            "role": "system",
                            "content": "Notice: Direct JavaScript DOM execution in browser is restricted by browser security settings. Here is the visual content of the browser window captured via Vision OCR:\n\(fallbackContent)\nPlease analyze this information directly and present your complete answer to the user now without calling browser_eval again."
                        ])
                        consecutiveBrowserEvalCount = 0
                    }

                    // Reset accumulated content for the next assistant turn in the loop
                    accumulatedContent = ""
                    continue
                }

                // Final answer text completed
                let trimmed = accumulatedContent.trimmingCharacters(in: .whitespacesAndNewlines)
                conversationMessages.append(["role": "assistant", "content": trimmed])
                await MainActor.run {
                    if messageIndex < state.chatHistory.count {
                        state.chatHistory[messageIndex].content = trimmed
                        state.chatHistory[messageIndex].isRunning = false
                        let elapsed = max(1, Int(Date().timeIntervalSince(state.chatHistory[messageIndex].startedAt)))
                        state.chatHistory[messageIndex].durationSeconds = elapsed
                        for i in 0..<state.chatHistory[messageIndex].steps.count {
                            state.chatHistory[messageIndex].steps[i].isDone = true
                        }
                        let promptEst = userText.count / 4
                        let outEst = (accumulatedContent.count + accumulatedThinking.count) / 4
                        let finalTokens = totalTokensEstimated > 0 ? totalTokensEstimated : max(40, promptEst + outEst)
                        state.chatHistory[messageIndex].creditsUsed = Double(finalTokens) * 0.000012
                    }
                    state.stateOverride = nil
                    state.view = .prompt
                    state.archiveCurrentSession()
                    if trimmed.contains("```") || trimmed.contains("func ") || trimmed.contains("def ") {
                        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
                        NotificationCenter.default.post(name: .botParticle, object: Particle.ParticleType.star)
                    } else {
                        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
                    }
                }
                return
            } catch {
                coucouLog("[Agent Error] \(error.localizedDescription)")
                if !conversationMessages.isEmpty {
                    conversationMessages.removeLast()
                }
                await MainActor.run {
                    if messageIndex < state.chatHistory.count {
                        state.chatHistory.remove(at: messageIndex)
                    }
                }
                await showError(error.localizedDescription, state: state)
                return
            }
        }

        // Safety net: if the loop exhausted all 8 iterations without a final response,
        // reset the UI to prevent permanent hang ("Đang suy nghĩ..." stuck forever).
        let exhaustedMsg = "Coucou đã thực hiện \(8) bước nhưng chưa hoàn tất được yêu cầu. Thử lại với mô tả cụ thể hơn nhé."
        coucouLog("[Agent Loop] Exhausted 8 steps without completing request.")
        conversationMessages.append(["role": "assistant", "content": exhaustedMsg])
        await MainActor.run {
            if messageIndex < state.chatHistory.count {
                state.chatHistory[messageIndex].content = exhaustedMsg
                state.chatHistory[messageIndex].isRunning = false
                let elapsed = max(1, Int(Date().timeIntervalSince(state.chatHistory[messageIndex].startedAt)))
                state.chatHistory[messageIndex].durationSeconds = elapsed
                for i in 0..<state.chatHistory[messageIndex].steps.count {
                    state.chatHistory[messageIndex].steps[i].isDone = true
                }
                let promptEst = userText.count / 4
                let outEst = exhaustedMsg.count / 4
                let finalTokens = totalTokensEstimated > 0 ? totalTokensEstimated : max(40, promptEst + outEst)
                state.chatHistory[messageIndex].creditsUsed = Double(finalTokens) * 0.000012
            }
            state.stateOverride = nil
            state.view = .prompt
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.annoyed)
            NotificationCenter.default.post(name: .botParticle, object: Particle.ParticleType.sweat)
        }
    }

    // MARK: - Structured search (M8 — window attach + web search)

    func search(query: String, context: PromptContext?, state: AppState) async {
        guard let key = apiKey, !key.isEmpty else {
            await showError("Anthropic API key missing. Open settings to configure it.", state: state)
            return
        }

        var userContent: [[String: Any]] = []
        switch context {
        case .window(let appName, let title, let url):
            var text = "App: \(appName)\nWindow title: \(title)"
            if let url = url { text += "\nURL: \(url)" }
            text += "\n\nRequest: \(query)"
            userContent.append(["type": "text", "text": text])
        case .file(let name, let fileURL):
            if let fileURL = fileURL, let fileBlock = readFileAsBlock(url: fileURL) {
                userContent.append(fileBlock)
            }
            userContent.append(["type": "text", "text": "File: \(name)\n\nRequest: \(query)"])
        case .clipboard(let sourceApp, let sourceTitle, let sourceURL, let snippet):
            var text = "Source: \(sourceApp)\nWindow/Tab: \(sourceTitle)"
            if let url = sourceURL { text += "\nURL: \(url)" }
            text += "\nCopied Content:\n\(snippet)"
            text += "\n\nRequest: \(query)"
            userContent.append(["type": "text", "text": text])
        case nil:
            userContent.append(["type": "text", "text": query])
        }

        let system = """
        You are an assistant built into the notch of a Mac. Reply in English, short and precise.
        Reply ONLY with valid JSON in this exact format:
        {"title":"...","items":[{"label":"...","detail":"...","url":"..."}],"note":"..."}
        Maximum 3 items. "url" is optional. "note" is optional.
        """

        let tools: [[String: Any]] = [
            ["type": "web_search_20250305", "name": "web_search", "max_uses": 3]
        ]

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "tools": tools,
            "system": system,
            "messages": [["role": "user", "content": userContent]],
        ]

        do {
            let result = try await callAPI(body: body, key: key, beta: "web-search-2025-03-05")
            await handleResult(result, state: state)
        } catch {
            await showError(error.localizedDescription, state: state)
        }
    }

    // MARK: - API call

    private func callAPI(body: [String: Any], key: String, beta: String? = nil) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let beta { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 45

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            // Parse Anthropic error format: {"type":"error","error":{"type":"…","message":"…"}}
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = json["error"] as? [String: Any],
               let errType = err["type"] as? String,
               let errMsg = err["message"] as? String {
                if errType == "not_found_error" {
                    let id = AppState.shared.claudeModel
                    throw NSError(domain: "Claude", code: 0,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Model not found: \(id). Pick another one in Settings."])
                }
                throw NSError(domain: "Claude", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: errMsg])
            }
            let msg = String(data: data, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "Claude", code: 0, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return data
    }

    // MARK: - Chat result handler

    private func handleChatResult(_ data: Data, state: AppState) async {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            await showError("Unexpected API response.", state: state)
            return
        }

        // Store full content (includes tool_use/tool_result blocks) for correct multi-turn context
        conversationMessages.append(["role": "assistant", "content": content])

        guard let textBlock = content.first(where: { $0["type"] as? String == "text" }),
              let text = textBlock["text"] as? String, !text.isEmpty else {
            await showError("No response text.", state: state)
            return
        }

        // Add to display history
        state.chatHistory.append(ChatMessage(role: .assistant, content: text.trimmingCharacters(in: .whitespacesAndNewlines)))

        state.stateOverride = nil
        state.view = .prompt
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
    }

    // MARK: - Structured result handler

    private func handleResult(_ data: Data, state: AppState) async {
        // Extract text from Anthropic response (may contain tool_use / web_search_tool_result blocks)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let textBlock = content.first(where: { $0["type"] as? String == "text" }),
              let text = textBlock["text"] as? String else {
            await showError("Unexpected API response.", state: state)
            return
        }

        // Strip markdown code fences if present, then extract JSON object
        let cleanText: String
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            cleanText = String(text[start...end])
        } else {
            cleanText = text
        }

        // Try to parse as our JSON format
        if let resultData = cleanText.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] {
            let title  = parsed["title"] as? String ?? "Result"
            let note   = parsed["note"] as? String
            var items: [ResultItem] = []
            if let rawItems = parsed["items"] as? [[String: Any]] {
                for item in rawItems.prefix(3) {
                    items.append(ResultItem(
                        label:  item["label"]  as? String ?? "",
                        detail: item["detail"] as? String ?? "",
                        url:    item["url"]    as? String
                    ))
                }
            }
            state.searchResult = SearchResult(title: title, items: items, note: note)
        } else {
            // Fallback: show raw text in 3-line chunks
            let lines = cleanText.components(separatedBy: "\n").filter { !$0.isEmpty }.prefix(3)
            state.searchResult = SearchResult(
                title: "Claude's response",
                items: lines.map { ResultItem(label: $0, detail: "", url: nil) },
                note: nil
            )
        }

        state.stateOverride = nil
        state.view = .result
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
    }

    private func showError(_ message: String, state: AppState) async {
        state.stateOverride = .error
        state.noteMessage = message
        state.view = .note
    }

    // MARK: - File content block builder

    private func readFileAsBlock(url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()
        let base64 = data.base64EncodedString()

        if ext == "pdf" {
            return ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": base64]]
        } else if ["jpg", "jpeg"].contains(ext) {
            return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": base64]]
        } else if ext == "png" {
            return ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": base64]]
        } else if ext == "gif" {
            return ["type": "image", "source": ["type": "base64", "media_type": "image/gif", "data": base64]]
        } else if ext == "webp" {
            return ["type": "image", "source": ["type": "base64", "media_type": "image/webp", "data": base64]]
        } else {
            // Text/code — inline as text if <= 200 KB
            guard data.count <= 200_000,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return ["type": "text", "text": "File contents:\n\(text)"]
        }
    }
}

// MARK: - Computer Use Harness (Local tool execution for AI Agent)

@MainActor
enum ComputerUseHarness {

    nonisolated(unsafe) static let openAIToolDefinitions: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "bash",
                "description": "Execute a bash / zsh shell command on the user's macOS computer. Use this to count files, inspect folders, run scripts, query system status, check disk space, git, brew, etc.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "command": [
                            "type": "string",
                            "description": "The command line string to execute in zsh"
                        ],
                        "cwd": [
                            "type": "string",
                            "description": "Optional working directory (defaults to user home directory ~)"
                        ]
                    ],
                    "required": ["command"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "read_file",
                "description": "Read the contents of a file on the user's Mac.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "File path (supports ~ for home directory)"
                        ],
                        "max_bytes": [
                            "type": "integer",
                            "description": "Maximum bytes to read (default: 50000)"
                        ]
                    ],
                    "required": ["path"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "write_file",
                "description": "Create or overwrite a file with content on the user's Mac.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "File path (supports ~ for home directory)"
                        ],
                        "content": [
                            "type": "string",
                            "description": "Text content to write into the file"
                        ]
                    ],
                    "required": ["path", "content"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "applescript",
                "description": "Execute AppleScript on macOS to inspect or automate native applications (Finder, Safari, System Settings, active apps, window controls).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "script": [
                            "type": "string",
                            "description": "The AppleScript code to execute"
                        ]
                    ],
                    "required": ["script"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "inspect_window",
                "description": "Inspect the active macOS window or specific app without screenshots. Reads window title, URL, buttons, text fields, document path, and UI elements directly from macOS Accessibility API & System Events.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "app_name": [
                            "type": "string",
                            "description": "Optional application name to inspect (e.g. 'Antigravity IDE', 'Xcode', 'Safari'). If omitted, inspects the current frontmost application."
                        ]
                    ]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "screenshot",
                "description": "Capture a screenshot of the user's screen. Saved to /tmp/coucou_screenshot.png.",
                "parameters": [
                    "type": "object",
                    "properties": [:]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "computer_action",
                "description": "Perform mouse/keyboard actions on macOS (click, double_click, right_click, mouse_move, type, key, scroll). Use precise screen coordinates [x, y] obtained from inspect_window.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["click", "double_click", "right_click", "mouse_move", "type", "key", "scroll"],
                            "description": "Action type"
                        ],
                        "coordinate": [
                            "type": "array",
                            "items": ["type": "number"],
                            "description": "[x, y] screen coordinates"
                        ],
                        "text": [
                            "type": "string",
                            "description": "Text to type if action is 'type'"
                        ],
                        "key": [
                            "type": "string",
                            "description": "Key name to press (e.g. 'Return', 'Tab', 'Escape')"
                        ],
                        "delta": [
                            "type": "array",
                            "items": ["type": "number"],
                            "description": "[dx, dy] scroll amounts"
                        ]
                    ],
                    "required": ["action"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "press_ui_element",
                "description": "Click or press a UI button, menu item, or control by title on macOS. Automatically resolves exact screen center coordinates via Accessibility tree or Vision OCR fallback.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "Title, label, or text of the button or element to press (e.g. 'Connect', 'Build', 'Run', 'Save', 'Submit', 'OK', 'Cancel')"
                        ],
                        "app_name": [
                            "type": "string",
                            "description": "Optional application name (defaults to frontmost app)"
                        ]
                    ],
                    "required": ["title"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "key_combo",
                "description": "Execute native macOS keyboard shortcut with modifiers (e.g. cmd+s, cmd+b, cmd+w, cmd+r, cmd+shift+p, cmd+space).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "combo": [
                            "type": "string",
                            "description": "Key combination (e.g. 'cmd+s', 'cmd+b', 'cmd+w', 'cmd+r', 'cmd+shift+p')"
                        ]
                    ],
                    "required": ["combo"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "browser_open",
                "description": "Open a URL in the browser, or switch to an already open browser tab matching a title or URL keyword.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "target": [
                            "type": "string",
                            "description": "URL to open (e.g. 'https://example.com') or keyword/title of open tab to switch to (e.g. 'Bug', 'error', 'dashboard')"
                        ]
                    ],
                    "required": ["target"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "browser_list_tabs",
                "description": "List all currently open tabs across Chrome, Safari, and Arc with their titles and URLs.",
                "parameters": [
                    "type": "object",
                    "properties": [:]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "browser_get_content",
                "description": "Read the on-screen visible content or text from the frontmost or active browser tab via Vision OCR and metadata.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "tab_keyword": [
                            "type": "string",
                            "description": "Optional keyword or title to switch to before reading"
                        ]
                    ]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "browser_eval",
                "description": "Execute JavaScript directly in the active tab of Chrome, Safari, Arc, or Brave. Use to click web elements, read text, or fill forms in 5ms without screenshots.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "javascript": [
                            "type": "string",
                            "description": "JavaScript code to evaluate in the active browser tab"
                        ]
                    ],
                    "required": ["javascript"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "window_control",
                "description": "Control macOS application windows (activate app, list open applications and windows).",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["activate", "list_apps"],
                            "description": "Action: 'activate' brings an app to front, 'list_apps' lists all running applications"
                        ],
                        "app_name": [
                            "type": "string",
                            "description": "Application name to activate (for 'activate' action)"
                        ]
                    ],
                    "required": ["action"]
                ]
            ]
        ]
    ]

    static func execute(name: String, arguments: [String: Any]) async -> String {
        switch name {
        case "bash":
            let cmd = arguments["command"] as? String ?? ""
            let cwd = arguments["cwd"] as? String
            return await runBash(command: cmd, cwd: cwd)

        case "read_file":
            let path = arguments["path"] as? String ?? ""
            let maxBytes = (arguments["max_bytes"] as? NSNumber)?.intValue ?? (arguments["max_bytes"] as? Int)
            return readFile(path: path, maxBytes: maxBytes)

        case "write_file":
            let path = arguments["path"] as? String ?? ""
            let content = arguments["content"] as? String ?? ""
            return writeFile(path: path, content: content)

        case "inspect_window":
            let appName = arguments["app_name"] as? String
            return await inspectActiveWindow(appName: appName)

        case "press_ui_element":
            let title = arguments["title"] as? String ?? ""
            let appName = arguments["app_name"] as? String
            return await pressUIElement(title: title, appName: appName)

        case "key_combo":
            let combo = arguments["combo"] as? String ?? ""
            return await executeKeyCombo(combo: combo)

        case "browser_open":
            let target = (arguments["target"] as? String) ?? (arguments["url"] as? String) ?? ""
            return await openOrSwitchBrowserTab(target: target)

        case "browser_list_tabs":
            return await listAllBrowserTabs()

        case "browser_get_content":
            let keyword = arguments["tab_keyword"] as? String
            return await getBrowserTabContent(tabKeyword: keyword)

        case "browser_eval":
            let js = arguments["javascript"] as? String ?? ""
            return await executeBrowserEval(javascript: js)

        case "window_control":
            let action = arguments["action"] as? String ?? ""
            let appName = arguments["app_name"] as? String
            return await executeWindowControl(action: action, appName: appName)

        case "applescript":
            let script = arguments["script"] as? String ?? ""
            return await runAppleScript(script: script)

        case "screenshot":
            return await takeScreenshot()

        case "computer_action":
            let action = arguments["action"] as? String ?? ""
            let coord = (arguments["coordinate"] as? [NSNumber])?.map { $0.doubleValue }
            let text = arguments["text"] as? String
            let key = arguments["key"] as? String
            let delta = (arguments["delta"] as? [NSNumber])?.map { $0.doubleValue }
            return await runComputerAction(action: action, coordinate: coord, text: text, key: key, delta: delta)

        default:
            return "Unknown tool: \(name)"
        }
    }

    static func runBash(command: String, cwd: String?, timeout: TimeInterval = 45) async -> String {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: Command was empty."
        }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]

            var env = ProcessInfo.processInfo.environment
            let home = NSHomeDirectory()
            let customPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(home)/.local/bin:\(home)/bin"
            env["PATH"] = customPath
            env["HOME"] = home
            env["SHELL"] = "/bin/zsh"
            process.environment = env

            if let cwd, !cwd.isEmpty {
                let expandedCwd = (cwd as NSString).expandingTildeInPath
                process.currentDirectoryURL = URL(fileURLWithPath: expandedCwd)
            } else {
                process.currentDirectoryURL = URL(fileURLWithPath: home)
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                return "Failed to run command: \(error.localizedDescription)"
            }

            let timeoutTimer = DispatchSource.makeTimerSource(queue: .global())
            timeoutTimer.schedule(deadline: .now() + timeout)
            timeoutTimer.setEventHandler {
                if process.isRunning {
                    process.terminate()
                }
            }
            timeoutTimer.resume()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeoutTimer.cancel()

            let stdoutStr = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

            var result = ""
            if !stdoutStr.isEmpty {
                result += stdoutStr
            }
            if !stderrStr.isEmpty {
                if !result.isEmpty { result += "\n" }
                result += "[stderr]:\n" + stderrStr
            }
            if process.terminationStatus != 0 {
                result += "\n[Process exited with code \(process.terminationStatus)]"
            }
            if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = "(Command finished with no output)"
            }
            if result.count > 25_000 {
                let prefix = result.prefix(18_000)
                let suffix = result.suffix(5_000)
                result = "\(prefix)\n...[output truncated]...\n\(suffix)"
            }
            return result
        }.value
    }

    static func runAppleScript(script: String) async -> String {
        return await MainActor.run {
            var error: NSDictionary?
            let appleScript = NSAppleScript(source: script)
            let result = appleScript?.executeAndReturnError(&error)
            if let error {
                let msg = error["NSAppleScriptErrorMessage"] as? String ?? error.description
                return "AppleScript Error: \(msg)"
            }
            return result?.stringValue ?? "(Executed successfully with no return value)"
        }
    }

    static func readFile(path: String, maxBytes: Int? = 50_000) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: expanded) else {
            return "Error: File does not exist at \(path)"
        }
        do {
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            let limit = min(data.count, maxBytes ?? 50_000)
            let subData = data.prefix(limit)
            guard let text = String(data: subData, encoding: .utf8) else {
                return "Binary file or non-UTF8 encoding (\(data.count) bytes)"
            }
            var output = text
            if data.count > limit {
                output += "\n...[truncated, showing first \(limit) of \(data.count) bytes]"
            }
            return output
        } catch {
            return "Error reading file: \(error.localizedDescription)"
        }
    }

    static func writeFile(path: String, content: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            return "Successfully wrote \(content.count) characters to \(path)"
        } catch {
            return "Error writing file: \(error.localizedDescription)"
        }
    }

    static func inspectActiveWindow(appName: String? = nil) async -> String {
        return await Task.detached(priority: .userInitiated) { () -> String in
            let workspace = NSWorkspace.shared

            // 1. Resolve target app and window via CGWindowList
            var detectedOwner = ""
            var detectedTitle = ""
            var detectedPid: pid_t = 0
            var matchedWindowId: CGWindowID? = nil

            if let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                for info in infoList {
                    let layer = info[kCGWindowLayer as String] as? Int ?? -1
                    let owner = info[kCGWindowOwnerName as String] as? String ?? ""
                    let name = info[kCGWindowName as String] as? String ?? ""
                    let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
                    let wid = info[kCGWindowNumber as String] as? CGWindowID ?? 0

                    guard layer == 0, !owner.isEmpty, owner != "Coucou", owner != "Window Server" else { continue }

                    if let targetName = appName, !targetName.isEmpty {
                        if owner.localizedCaseInsensitiveContains(targetName) {
                            detectedOwner = owner
                            detectedTitle = name
                            detectedPid = pid
                            matchedWindowId = wid
                            break
                        }
                    } else {
                        // First layer 0 external window in Z-order
                        detectedOwner = owner
                        detectedTitle = name
                        detectedPid = pid
                        matchedWindowId = wid
                        break
                    }
                }
            }

            let targetApp: NSRunningApplication? = {
                if detectedPid > 0 {
                    return workspace.runningApplications.first(where: { $0.processIdentifier == detectedPid })
                }
                if let name = appName, !name.isEmpty {
                    return workspace.runningApplications.first(where: {
                        $0.localizedName?.localizedCaseInsensitiveContains(name) == true
                    })
                }
                return workspace.runningApplications.first(where: {
                    $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                }) ?? workspace.frontmostApplication
            }()

            let finalName = !detectedOwner.isEmpty ? detectedOwner : (targetApp?.localizedName ?? "App")
            var lines: [String] = ["=== Active Window: \(finalName) ==="]

            if !detectedTitle.isEmpty {
                lines.append("Window Title: \"\(detectedTitle)\"")
            }

            // 2. Browser URL extraction
            if let bundleId = targetApp?.bundleIdentifier {
                let browserScripts: [String: String] = [
                    "com.apple.Safari": "tell application \"Safari\" to return URL of current tab of front window",
                    "com.google.Chrome": "tell application \"Google Chrome\" to return URL of active tab of front window",
                    "company.thebrowser.Browser": "tell application \"Arc\" to return URL of active tab of front window",
                    "org.mozilla.firefox": "tell application \"Firefox\" to return URL of active tab of front window",
                    "com.microsoft.edgemac": "tell application \"Microsoft Edge\" to return URL of active tab of front window",
                    "com.brave.Browser": "tell application \"Brave Browser\" to return URL of active tab of front window",
                ]
                if let script = browserScripts[bundleId] {
                    var err: NSDictionary?
                    if let res = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue {
                        lines.append("Browser URL: \(res)")
                    }
                }

                // Terminal / iTerm2 extraction
                if bundleId == "com.apple.Terminal" {
                    let tScript = "tell application \"Terminal\" to return contents of selected tab of front window"
                    var err: NSDictionary?
                    if let termText = NSAppleScript(source: tScript)?.executeAndReturnError(&err).stringValue, !termText.isEmpty {
                        lines.append("Terminal Console Output (last 2000 chars):\n\(termText.suffix(2000))")
                    }
                } else if bundleId == "com.googlecode.iterm2" {
                    let iScript = "tell application \"iTerm\" to return text of current session of current window"
                    var err: NSDictionary?
                    if let itermText = NSAppleScript(source: iScript)?.executeAndReturnError(&err).stringValue, !itermText.isEmpty {
                        lines.append("iTerm Console Output (last 2000 chars):\n\(itermText.suffix(2000))")
                    }
                }
            }

            // 3. Code Editor / IDE File detection from window title
            let titleTokens = detectedTitle.components(separatedBy: CharacterSet(charactersIn: " —-·|:"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let codeExtensions = [".swift", ".ts", ".tsx", ".js", ".py", ".json", ".html", ".css", ".go", ".rs", ".md", ".cpp", ".c", ".h", ".java", ".kt", ".rb", ".yaml", ".yml", ".sh"]
            for token in titleTokens {
                if codeExtensions.contains(where: { token.hasSuffix($0) }) {
                    lines.append("Detected Active File: \(token)")
                    let findTask = Process()
                    findTask.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                    findTask.arguments = ["-name", token]
                    let pipe = Pipe()
                    findTask.standardOutput = pipe
                    try? findTask.run()
                    findTask.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let out = String(data: data, encoding: .utf8) {
                        let foundPaths = out.components(separatedBy: "\n").filter { $0.hasSuffix(token) }
                        if let bestPath = foundPaths.first,
                           let fileData = try? Data(contentsOf: URL(fileURLWithPath: bestPath), options: .mappedIfSafe),
                           let fileContent = String(data: fileData.prefix(8000), encoding: .utf8) {
                            lines.append("File Path on Disk: \(bestPath)")
                            lines.append("--- Active File Preview (First 8000 chars) ---\n\(fileContent)\n--- End of File Preview ---")
                        }
                    }
                    break
                }
            }

            // 4. AXUIElement tree inspection
            var elements: [String] = []
            if let app = targetApp {
                let pid = app.processIdentifier
                let axApp = AXUIElementCreateApplication(pid)

                var windowRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) != .success || windowRef == nil {
                    _ = AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &windowRef)
                }
                if windowRef == nil {
                    var winsRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
                       let wins = winsRef as? [AXUIElement], let first = wins.first {
                        windowRef = first
                    }
                }

                if let windowRef {
                    let axWindow = windowRef as! AXUIElement
                    if detectedTitle.isEmpty {
                        var titleRef: CFTypeRef?
                        if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                           let t = titleRef as? String, !t.isEmpty {
                            lines.append("Window Title: \"\(t)\"")
                        }
                    }

                    var docRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(axWindow, kAXDocumentAttribute as CFString, &docRef) == .success,
                       let doc = docRef as? String {
                        lines.append("Document: \(doc)")
                    }

                    func walk(element: AXUIElement, depth: Int, limit: inout Int) {
                        guard depth <= 6, limit > 0 else { return }
                        var childrenRef: CFTypeRef?
                        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                           let children = childrenRef as? [AXUIElement] {
                            for child in children {
                                guard limit > 0 else { break }
                                var roleRef: CFTypeRef?
                                AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
                                let role = (roleRef as? String)?.replacingOccurrences(of: "AX", with: "") ?? ""

                                var valRef: CFTypeRef?
                                AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valRef)
                                var titleRef: CFTypeRef?
                                AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
                                var descRef: CFTypeRef?
                                AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &descRef)

                                let text = ((valRef as? String) ?? (titleRef as? String) ?? (descRef as? String) ?? "")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)

                                if !text.isEmpty && text.count > 1 {
                                    var coordStr = ""
                                    var posVal: CFTypeRef?
                                    var sizeVal: CFTypeRef?
                                    var pt = CGPoint.zero
                                    var sz = CGSize.zero
                                    if AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posVal) == .success,
                                       let posVal,
                                       AXValueGetValue(posVal as! AXValue, .cgPoint, &pt),
                                       AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeVal) == .success,
                                       let sizeVal,
                                       AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz),
                                       sz.width > 2 && sz.height > 2 {
                                        let cx = Int(pt.x + sz.width / 2.0)
                                        let cy = Int(pt.y + sz.height / 2.0)
                                        coordStr = " [center: (\(cx), \(cy))]"
                                    }

                                    let indent = String(repeating: "  ", count: depth)
                                    elements.append("\(indent)- [\(role)] \"\(text.prefix(120))\"\(coordStr)")
                                    limit -= 1
                                }
                                walk(element: child, depth: depth + 1, limit: &limit)
                            }
                        }
                    }
                    var limit = 45
                    walk(element: axWindow, depth: 1, limit: &limit)

                    if !elements.isEmpty {
                        lines.append("Visible Controls & Text Content:")
                        lines.append(contentsOf: elements)
                    }
                }
            }

            // 5. Vision OCR fallback (essential for Flutter, RustDesk, Web canvas, Electron)
            if elements.count < 4, let wid = matchedWindowId {
                let tmpImg = "/tmp/coucou_win_\(wid).png"
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                proc.arguments = ["-x", "-o", "-l", "\(wid)", tmpImg]
                let pTimer = DispatchSource.makeTimerSource(queue: .global())
                pTimer.schedule(deadline: .now() + 1.5)
                pTimer.setEventHandler { if proc.isRunning { proc.terminate() } }
                pTimer.resume()
                try? proc.run()
                proc.waitUntilExit()
                pTimer.cancel()

                if let img = NSImage(contentsOf: URL(fileURLWithPath: tmpImg)),
                   let cgImg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let req = VNRecognizeTextRequest()
                    req.recognitionLevel = .fast
                    req.usesLanguageCorrection = false
                    let handler = VNImageRequestHandler(cgImage: cgImg, options: [:])
                    try? handler.perform([req])

                    var winRect = CGRect(x: 0, y: 0, width: img.size.width, height: img.size.height)
                    if let rect = getFrontmostWindowRect(forPid: detectedPid)?.rect {
                        winRect = rect
                    }

                    let clickW = img.size.width > 0 ? img.size.width : winRect.width
                    let clickH = img.size.height > 0 ? img.size.height : winRect.height

                    let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                    var ocrItems: [String] = []
                    for obs in observations {
                        if let candidate = obs.topCandidates(1).first {
                            let text = candidate.string.trimmingCharacters(in: .whitespaces)
                            guard !text.isEmpty else { continue }
                            let box = obs.boundingBox
                            let cx = Int(winRect.origin.x + box.midX * clickW)
                            let cy = Int(winRect.origin.y + (1.0 - box.midY) * clickH)
                            ocrItems.append("- \"\(text)\" [center: (\(cx), \(cy))]")
                        }
                    }
                    if !ocrItems.isEmpty {
                        lines.append("On-Screen Visible Elements (Vision OCR with screen coordinates):")
                        lines.append(contentsOf: ocrItems.prefix(50))
                    }
                }
                try? FileManager.default.removeItem(atPath: tmpImg)
            }

            if lines.count == 1 {
                lines.append("(No additional window details or controls detected)")
            }

            return lines.joined(separator: "\n")
        }.value
    }

    nonisolated static func getFrontmostWindowRect(forPid pid: pid_t) -> (wid: CGWindowID, rect: CGRect)? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var minX: CGFloat = .greatestFiniteMagnitude
        var minY: CGFloat = .greatestFiniteMagnitude
        var maxX: CGFloat = -.greatestFiniteMagnitude
        var maxY: CGFloat = -.greatestFiniteMagnitude
        var topWid: CGWindowID = 0
        var found = false

        for info in infoList {
            let p = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let layer = info[kCGWindowLayer as String] as? Int ?? -1
            let wid = info[kCGWindowNumber as String] as? CGWindowID ?? 0
            let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let x = bounds["X"] as? CGFloat ?? 0
            let y = bounds["Y"] as? CGFloat ?? 0
            let w = bounds["Width"] as? CGFloat ?? 0
            let h = bounds["Height"] as? CGFloat ?? 0
            if p == pid && layer == 0 && w > 20 && h > 20 {
                if !found {
                    topWid = wid
                    found = true
                }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x + w)
                maxY = max(maxY, y + h)
            }
        }
        if found && maxX > minX && maxY > minY {
            return (topWid, CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        }
        return nil
    }

    nonisolated static func performHardwareClick(at pt: CGPoint, isRight: Bool = false, label: String? = nil) -> String {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGWarpMouseCursorPosition(pt)
        if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left) {
            move.post(tap: .cgSessionEventTap)
            move.post(tap: .cghidEventTap)
        }
        usleep(40_000)

        let downType: CGEventType = isRight ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = isRight ? .rightMouseUp : .leftMouseUp
        let btn: CGMouseButton = isRight ? .right : .left

        guard let down = CGEvent(mouseEventSource: source, mouseType: downType, mouseCursorPosition: pt, mouseButton: btn),
              let up = CGEvent(mouseEventSource: source, mouseType: upType, mouseCursorPosition: pt, mouseButton: btn) else {
            coucouLog("[Hardware Click] Failed to create CGEvent at (\(Int(pt.x)), \(Int(pt.y)))")
            return "Failed to create mouse event at (\(Int(pt.x)), \(Int(pt.y)))"
        }

        // CRITICAL FOR CHROMIUM, WEBKIT, APPKIT:
        // Set click state to 1. Without this, WebKit & Chromium drop synthetic clicks!
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)

        down.post(tap: .cgSessionEventTap)
        down.post(tap: .cghidEventTap)
        usleep(80_000) // 80ms hold duration for event loop detection
        up.post(tap: .cgSessionEventTap)
        up.post(tap: .cghidEventTap)

        let desc = label.map { "'\($0)'" } ?? ""
        coucouLog("[Hardware Click] Dispatched click \(desc) at (\(Int(pt.x)), \(Int(pt.y)))")

        if let label {
            return "Successfully clicked '\(label)' at (\(Int(pt.x)), \(Int(pt.y)))"
        }
        return "Clicked at (\(Int(pt.x)), \(Int(pt.y)))"
    }

    nonisolated static func performHardwareDoubleClick(at pt: CGPoint) -> String {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGWarpMouseCursorPosition(pt)
        if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left) {
            move.post(tap: .cgSessionEventTap)
            move.post(tap: .cghidEventTap)
        }
        usleep(40_000)

        guard let down1 = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left),
              let up1 = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left),
              let down2 = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: pt, mouseButton: .left),
              let up2 = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: pt, mouseButton: .left) else {
            return "Failed to create double click event"
        }
        down1.setIntegerValueField(.mouseEventClickState, value: 1)
        up1.setIntegerValueField(.mouseEventClickState, value: 1)
        down2.setIntegerValueField(.mouseEventClickState, value: 2)
        up2.setIntegerValueField(.mouseEventClickState, value: 2)

        down1.post(tap: .cgSessionEventTap)
        down1.post(tap: .cghidEventTap)
        usleep(40_000)
        up1.post(tap: .cgSessionEventTap)
        up1.post(tap: .cghidEventTap)
        usleep(60_000)
        down2.post(tap: .cgSessionEventTap)
        down2.post(tap: .cghidEventTap)
        usleep(40_000)
        up2.post(tap: .cgSessionEventTap)
        up2.post(tap: .cghidEventTap)

        coucouLog("[Hardware Click] Dispatched double click at (\(Int(pt.x)), \(Int(pt.y)))")
        return "Double clicked at (\(Int(pt.x)), \(Int(pt.y)))"
    }

    static func pressUIElement(title: String, appName: String?) async -> String {
        return await Task.detached(priority: .userInitiated) { () -> String in
            let workspace = NSWorkspace.shared
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty else { return "Error: Element title is empty." }

            // 1. Resolve target app
            let targetApp: NSRunningApplication?
            if let name = appName, !name.isEmpty {
                targetApp = workspace.runningApplications.first(where: {
                    $0.localizedName?.localizedCaseInsensitiveContains(name) == true
                })
            } else {
                targetApp = workspace.runningApplications.first(where: {
                    $0.isActive && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                }) ?? workspace.frontmostApplication
            }
            guard let app = targetApp, let name = app.localizedName else {
                return "Error: No active application found."
            }

            // Bring application to front and focus front window
            app.activate(options: [.activateIgnoringOtherApps])
            let asScript = "tell application \"\(name)\" to activate"
            NSAppleScript(source: asScript)?.executeAndReturnError(nil)
            usleep(150_000)

            // Fast browser DOM click attempt if target is a web browser (Chrome, Arc, Brave, Safari, Edge)
            var browserDomClicked = false
            let bundleId = app.bundleIdentifier ?? ""
            let isBrowser = bundleId.contains("Chrome") || bundleId.contains("Arc") || bundleId.contains("Brave") || bundleId.contains("Edge") || bundleId.contains("Safari")
            if isBrowser {
                let escapedTitle = cleanTitle.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let js = """
                (() => {
                    const query = "\(escapedTitle)".toLowerCase().trim();
                    const tags = 'button, a, [role="button"], [role="tab"], [role="menuitem"], [role="link"], li, input[type="button"], input[type="submit"], [role="treeitem"], div, span';
                    const els = Array.from(document.querySelectorAll(tags));
                    let el = els.find(e => {
                        const t = (e.innerText || e.textContent || '').trim().toLowerCase();
                        const a = (e.getAttribute('aria-label') || '').trim().toLowerCase();
                        return (t === query || a === query) && e.offsetParent !== null;
                    });
                    if (!el) {
                        el = els.find(e => {
                            const t = (e.innerText || e.textContent || '').trim().toLowerCase();
                            const a = (e.getAttribute('aria-label') || '').trim().toLowerCase();
                            return (t.includes(query) || a.includes(query)) && e.offsetParent !== null;
                        });
                    }
                    if (el) {
                        el.scrollIntoView({behavior: 'instant', block: 'center', inline: 'center'});
                        el.focus();
                        el.click();
                        return "SUCCESS";
                    }
                    return "NOT_FOUND";
                })()
                """
                let script: String
                if bundleId.contains("Safari") {
                    script = "tell application \"Safari\" to do JavaScript \"\(js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" in current tab of front window"
                } else {
                    script = "tell application \"\(name)\" to execute active tab of front window javascript \"\(js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
                }
                var err: NSDictionary?
                let res = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue
                if res == "SUCCESS" {
                    browserDomClicked = true
                    coucouLog("[pressUIElement] Clicked '\(cleanTitle)' in \(name) via browser DOM injection.")
                }
            }

            let pid = app.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)

            var windowRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) != .success || windowRef == nil {
                _ = AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &windowRef)
            }
            if windowRef == nil {
                var winsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
                   let wins = winsRef as? [AXUIElement], let first = wins.first {
                    windowRef = first
                }
            }

            var matchedElement: AXUIElement?
            var matchedCenter: CGPoint?

            if let windowRef {
                let axWindow = windowRef as! AXUIElement

                func getElementBounds(_ el: AXUIElement) -> CGRect? {
                    var posVal: CFTypeRef?
                    var sizeVal: CFTypeRef?
                    var pt = CGPoint.zero
                    var sz = CGSize.zero
                    if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posVal) == .success,
                       let posVal,
                       AXValueGetValue(posVal as! AXValue, .cgPoint, &pt),
                       AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeVal) == .success,
                       let sizeVal,
                       AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz),
                       sz.width > 2 && sz.height > 2 {
                        return CGRect(origin: pt, size: sz)
                    }
                    return nil
                }

                func findMatch(element: AXUIElement, depth: Int) {
                    guard depth <= 8, matchedElement == nil else { return }
                    var titleRef: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
                    var descRef: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &descRef)
                    var valRef: CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valRef)

                    let text = ((titleRef as? String) ?? (descRef as? String) ?? (valRef as? String) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if !text.isEmpty && text.localizedCaseInsensitiveContains(cleanTitle) {
                        matchedElement = element
                        if let rect = getElementBounds(element) {
                            matchedCenter = CGPoint(x: rect.midX, y: rect.midY)
                        }
                        return
                    }

                    var childrenRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                       let children = childrenRef as? [AXUIElement] {
                        for child in children {
                            findMatch(element: child, depth: depth + 1)
                            if matchedElement != nil { return }
                        }
                    }
                }

                findMatch(element: axWindow, depth: 1)
            }

            // Strategy 1: If element was found via AX
            if let target = matchedElement {
                // Perform accessibility action directly
                let axResult = AXUIElementPerformAction(target, kAXPressAction as CFString)

                // ALSO perform hardware click at exact center if coordinates are available
                var hwSuccess = false
                if let center = matchedCenter {
                    let hw = performHardwareClick(at: center, label: "\(cleanTitle) in \(name)")
                    hwSuccess = !hw.contains("Failed")
                }

                if axResult == .success || hwSuccess || browserDomClicked {
                    coucouLog("[pressUIElement] Clicked '\(cleanTitle)' in \(name) (AXAction: \(axResult == .success), HWClick: \(hwSuccess), DOM: \(browserDomClicked))")
                    return "Successfully clicked '\(cleanTitle)' in \(name)."
                }
            }

            // Strategy 2: Vision OCR Fallback (Flutter apps like RustDesk, Electron, canvas, games)
            if let windowInfo = getFrontmostWindowRect(forPid: pid) {
                let winRect = windowInfo.rect
                let wid = windowInfo.wid
                let tmpImg = "/tmp/coucou_press_ocr_\(wid).png"
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                proc.arguments = ["-x", "-o", "-l", "\(wid)", tmpImg]
                let pTimer = DispatchSource.makeTimerSource(queue: .global())
                pTimer.schedule(deadline: .now() + 1.5)
                pTimer.setEventHandler { if proc.isRunning { proc.terminate() } }
                pTimer.resume()
                try? proc.run()
                proc.waitUntilExit()
                pTimer.cancel()

                if let img = NSImage(contentsOf: URL(fileURLWithPath: tmpImg)),
                   let cgImg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let req = VNRecognizeTextRequest()
                    req.recognitionLevel = .fast
                    req.usesLanguageCorrection = false
                    let handler = VNImageRequestHandler(cgImage: cgImg, options: [:])
                    try? handler.perform([req])

                    let clickW = img.size.width > 0 ? img.size.width : winRect.width
                    let clickH = img.size.height > 0 ? img.size.height : winRect.height

                    let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                    for obs in observations {
                        if let candidate = obs.topCandidates(1).first,
                           candidate.string.localizedCaseInsensitiveContains(cleanTitle) {
                            let box = obs.boundingBox
                            let clickX = winRect.origin.x + box.midX * clickW
                            let clickY = winRect.origin.y + (1.0 - box.midY) * clickH
                            let targetPt = CGPoint(x: clickX, y: clickY)
                            try? FileManager.default.removeItem(atPath: tmpImg)
                            coucouLog("[pressUIElement] Clicked '\(cleanTitle)' via Vision OCR in \(name) at (\(Int(clickX)), \(Int(clickY)))")
                            return performHardwareClick(at: targetPt, label: "\(cleanTitle) (via Vision OCR in \(name))")
                        }
                    }
                }
                try? FileManager.default.removeItem(atPath: tmpImg)
            }

            if browserDomClicked {
                return "Successfully clicked '\(cleanTitle)' in \(name) via browser DOM."
            }

            coucouLog("[pressUIElement] Element '\(cleanTitle)' not found in \(name)")
            return "UI element '\(cleanTitle)' not found in \(name)."
        }.value
    }

    static func executeKeyCombo(combo: String) async -> String {
        return await MainActor.run { () -> String in
            let parts = combo.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard !parts.isEmpty else { return "Invalid key combo" }
            let key = parts.last!
            let modifiers = parts.dropLast()

            var usingParts: [String] = []
            if modifiers.contains("cmd") || modifiers.contains("command") { usingParts.append("command down") }
            if modifiers.contains("shift") { usingParts.append("shift down") }
            if modifiers.contains("option") || modifiers.contains("alt") { usingParts.append("option down") }
            if modifiers.contains("control") || modifiers.contains("ctrl") { usingParts.append("control down") }

            let usingClause = usingParts.isEmpty ? "" : " using {\(usingParts.joined(separator: ", "))}"
            let script: String
            if key == "space" {
                script = "tell application \"System Events\" to key code 49\(usingClause)"
            } else if key == "return" || key == "enter" {
                script = "tell application \"System Events\" to key code 36\(usingClause)"
            } else if key == "tab" {
                script = "tell application \"System Events\" to key code 48\(usingClause)"
            } else if key == "escape" || key == "esc" {
                script = "tell application \"System Events\" to key code 53\(usingClause)"
            } else {
                script = "tell application \"System Events\" to keystroke \"\(key)\"\(usingClause)"
            }

            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            if let err {
                return "Key combo error: \(err["NSAppleScriptErrorMessage"] ?? "")"
            }
            return "Successfully executed keyboard shortcut: \(combo)"
        }
    }

    static func listAllBrowserTabs() async -> String {
        return await MainActor.run { () -> String in
            var lines: [String] = []
            let workspace = NSWorkspace.shared

            let chromiumApps = ["Google Chrome", "Arc", "Brave Browser", "Microsoft Edge"]
            for cName in chromiumApps {
                if workspace.runningApplications.contains(where: { $0.localizedName == cName }) {
                    let script = """
                    tell application "\(cName)"
                        set outList to ""
                        repeat with w in every window
                            repeat with t in every tab of w
                                set outList to outList & (title of t) & " => " & (URL of t) & "\n"
                            end repeat
                        end repeat
                        return outList
                    end tell
                    """
                    var err: NSDictionary?
                    if let res = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue, !res.isEmpty {
                        lines.append("=== \(cName) Open Tabs ===")
                        lines.append(res.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }

            if workspace.runningApplications.contains(where: { $0.localizedName == "Safari" }) {
                let script = """
                tell application "Safari"
                    set outList to ""
                    repeat with w in every window
                        repeat with t in every tab of w
                            set outList to outList & (name of t) & " => " & (URL of t) & "\n"
                        end repeat
                    end repeat
                    return outList
                end tell
                """
                var err: NSDictionary?
                if let res = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue, !res.isEmpty {
                    lines.append("=== Safari Open Tabs ===")
                    lines.append(res.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }

            return lines.isEmpty ? "No open browser tabs detected." : lines.joined(separator: "\n")
        }
    }

    static func openOrSwitchBrowserTab(target: String) async -> String {
        return await MainActor.run { () -> String in
            let clean = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return "Missing target URL or tab keyword." }

            let workspace = NSWorkspace.shared

            // If it looks like a keyword (not a URL), try switching to existing open tab in Chrome/Arc/Safari
            if !clean.hasPrefix("http://") && !clean.hasPrefix("https://") && !clean.hasPrefix("file://") {
                if workspace.runningApplications.contains(where: { $0.localizedName == "Google Chrome" }) {
                    let escaped = clean.replacingOccurrences(of: "\"", with: "\\\"")
                    let script = """
                    tell application "Google Chrome"
                        repeat with w in every window
                            set tabCount to count of tabs of w
                            repeat with i from 1 to tabCount
                                set t to tab i of w
                                if (title of t contains "\(escaped)" or URL of t contains "\(escaped)") then
                                    set active tab index of w to i
                                    set index of w to 1
                                    activate
                                    return "Switched to tab: " & (title of t) & " (" & (URL of t) & ")"
                                end if
                            end repeat
                        end repeat
                    end tell
                    """
                    var err: NSDictionary?
                    if let res = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue, !res.isEmpty {
                        return res
                    }
                }
            }

            // Open URL directly in default browser
            let urlToOpen: URL? = {
                if let u = URL(string: clean), u.scheme != nil { return u }
                if clean.contains(".") && !clean.contains(" ") { return URL(string: "https://\(clean)") }
                return nil
            }()

            if let validUrl = urlToOpen {
                let ok = workspace.open(validUrl)
                return ok ? "Successfully opened '\(validUrl.absoluteString)' in default browser." : "Failed to open URL '\(validUrl.absoluteString)'."
            }

            return "Could not find open tab matching '\(clean)', and target is not a valid URL."
        }
    }

    static func getBrowserTabContent(tabKeyword: String? = nil) async -> String {
        if let kw = tabKeyword, !kw.isEmpty {
            _ = await openOrSwitchBrowserTab(target: kw)
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        let browserNames = ["Google Chrome", "Arc", "Brave Browser", "Microsoft Edge", "Safari"]
        let browserName = await MainActor.run { () -> String? in
            let workspace = NSWorkspace.shared
            return workspace.runningApplications.first(where: {
                browserNames.contains($0.localizedName ?? "")
            })?.localizedName
        }

        guard let name = browserName else {
            return "No running browser detected."
        }

        return await inspectActiveWindow(appName: name)
    }

    static func executeBrowserEval(javascript: String) async -> String {
        return await MainActor.run { () -> String in
            let workspace = NSWorkspace.shared
            let browserApp = workspace.runningApplications.first(where: {
                let id = $0.bundleIdentifier ?? ""
                return id.contains("Chrome") || id.contains("Arc") || id.contains("Brave") || id.contains("Edge") || id.contains("Safari")
            })

            guard let app = browserApp, let bundleId = app.bundleIdentifier else {
                return "No running browser found (Chrome, Safari, Arc, Brave, Edge)."
            }

            let escaped = javascript.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let script: String
            let appName = app.localizedName ?? "Google Chrome"

            if bundleId.contains("Chrome") || bundleId.contains("Arc") || bundleId.contains("Brave") || bundleId.contains("Edge") {
                script = "tell application \"\(appName)\" to execute active tab of front window javascript \"\(escaped)\""
            } else if bundleId.contains("Safari") {
                script = "tell application \"Safari\" to do JavaScript \"\(escaped)\" in current tab of front window"
            } else {
                return "Application '\(appName)' is not supported for direct DOM evaluation."
            }

            var err: NSDictionary?
            let res = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue
            if let err {
                let msg = (err["NSAppleScriptErrorMessage"] as? String) ?? "Unknown script error"
                if msg.contains("Apple Events") || msg.contains("-1728") || msg.contains("-10004") {
                    return "JavaScript execution via Apple Events is restricted in \(appName). Use 'browser_get_content' or 'inspect_window' to read page contents via Vision OCR."
                }
                return "Browser eval error: \(msg)"
            }
            return res ?? "JavaScript executed successfully."
        }
    }

    static func executeWindowControl(action: String, appName: String?) async -> String {
        return await MainActor.run { () -> String in
            let workspace = NSWorkspace.shared
            if action == "list_apps" {
                let apps = workspace.runningApplications.filter { $0.activationPolicy == .regular }
                let names = apps.compactMap { $0.localizedName }
                return "Running Applications:\n" + names.map { "- \($0)" }.joined(separator: "\n")
            } else if action == "activate" {
                guard let name = appName, !name.isEmpty else { return "Missing app_name to activate." }
                if let target = workspace.runningApplications.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(name) == true }) {
                    target.activate(options: .activateIgnoringOtherApps)
                    return "Activated application '\(target.localizedName ?? name)'."
                }
                return "Could not find application matching '\(name)'."
            }
            return "Unknown window control action: \(action)"
        }
    }

    static func takeScreenshot() async -> String {
        let path = "/tmp/coucou_screenshot.png"
        _ = await runBash(command: "/usr/sbin/screencapture -x -C '\(path)'", cwd: nil)
        if FileManager.default.fileExists(atPath: path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            return "Screenshot saved to \(path) (\(size) bytes)."
        }
        return "Failed to capture screenshot."
    }

    static func runComputerAction(action: String, coordinate: [Double]?, text: String?, key: String?, delta: [Double]?) async -> String {
        return await MainActor.run {
            switch action {
            case "mouse_move":
                guard let coord = coordinate, coord.count >= 2 else { return "Missing coordinate [x, y]" }
                let point = CGPoint(x: coord[0], y: coord[1])
                CGWarpMouseCursorPosition(point)
                return "Mouse moved to (\(coord[0]), \(coord[1]))"

            case "click", "left_click":
                let pt: CGPoint = {
                    if let coord = coordinate, coord.count >= 2 {
                        return CGPoint(x: coord[0], y: coord[1])
                    }
                    let m = NSEvent.mouseLocation
                    let screenH = NSScreen.main?.frame.height ?? 1080
                    return CGPoint(x: m.x, y: screenH - m.y)
                }()
                return performHardwareClick(at: pt, isRight: false)

            case "double_click":
                let pt: CGPoint = {
                    if let coord = coordinate, coord.count >= 2 {
                        return CGPoint(x: coord[0], y: coord[1])
                    }
                    let m = NSEvent.mouseLocation
                    let screenH = NSScreen.main?.frame.height ?? 1080
                    return CGPoint(x: m.x, y: screenH - m.y)
                }()
                return performHardwareDoubleClick(at: pt)

            case "right_click":
                let pt: CGPoint = {
                    if let coord = coordinate, coord.count >= 2 {
                        return CGPoint(x: coord[0], y: coord[1])
                    }
                    let m = NSEvent.mouseLocation
                    let screenH = NSScreen.main?.frame.height ?? 1080
                    return CGPoint(x: m.x, y: screenH - m.y)
                }()
                return performHardwareClick(at: pt, isRight: true)

            case "type":
                guard let text, !text.isEmpty else { return "Missing text to type" }
                for char in text.utf16 {
                    let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
                    var c = char
                    down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                    let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
                    up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
                    down?.post(tap: .cghidEventTap)
                    up?.post(tap: .cghidEventTap)
                }
                return "Typed \(text.count) characters"

            case "key":
                guard let key, !key.isEmpty else { return "Missing key to press" }
                let script = "tell application \"System Events\" to keystroke \"\(key)\""
                var err: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&err)
                return err == nil ? "Pressed key: \(key)" : "Key error: \(err?["NSAppleScriptErrorMessage"] ?? "")"

            case "scroll":
                guard let delta, delta.count >= 2 else { return "Missing delta [dx, dy]" }
                let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(delta[1]), wheel2: Int32(delta[0]), wheel3: 0)
                scroll?.post(tap: .cghidEventTap)
                return "Scrolled by dx: \(delta[0]), dy: \(delta[1])"

            default:
                return "Unknown computer action: \(action)"
            }
        }
    }
}
