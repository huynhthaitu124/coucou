import Foundation

// MARK: - TypeSafe AI Jev Fast Decision Engine (System One)
// Jev is a non-autoregressive decision model by TypeSafe AI (sub-500ms latency, 70-500ms).
// It acts as the "System One" fast-reflex controller for Computer Use, routing actions
// before or instead of calling slow general reasoning LLMs.

struct JevQuestion: Codable {
    let id: String
    let type: String       // "choice", "score", "noul"
    let prompt: String
    let options: [String]?
}

struct JevDecision: Codable {
    let questionId: String
    let selectedOption: String?
    let confidence: Double?
}

enum TypeSafeJevEngine {

    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    /// Sub-500ms decision query using TypeSafe Jev
    static func decideAction(
        userIntent: String,
        activeContext: PromptContext?,
        apiKey: String
    ) async -> (action: String, confidence: Double)? {
        guard !apiKey.isEmpty else { return nil }

        var stateDict: [String: Any] = [
            "user_intent": userIntent
        ]

        if let ctx = activeContext {
            switch ctx {
            case .window(let app, let title, let url):
                stateDict["active_app"] = app
                stateDict["window_title"] = title
                if let u = url { stateDict["url"] = u }
            case .file(let name, let url):
                stateDict["attached_file"] = name
                if let p = url?.path { stateDict["file_path"] = p }
            case .clipboard(let app, let title, let url, let snippet):
                stateDict["active_app"] = app
                stateDict["window_title"] = title
                if let u = url { stateDict["url"] = u }
                stateDict["clipboard_text"] = snippet
            case .composite(let wApp, let wTitle, let wUrl, let cApp, let cTitle, let cUrl, let snippet, let rel):
                stateDict["active_app"] = wApp
                stateDict["window_title"] = wTitle
                if let u = wUrl { stateDict["url"] = u }
                stateDict["clipboard_app"] = cApp
                stateDict["clipboard_title"] = cTitle
                if let u = cUrl { stateDict["clipboard_url"] = u }
                stateDict["clipboard_text"] = snippet
                stateDict["context_relation"] = rel.rawValue
            }
        }

        let body: [String: Any] = [
            "model": "jev-latest",
            "state": stateDict,
            "questions": [
                [
                    "id": "action_category",
                    "type": "choice",
                    "prompt": "What primary action should the desktop agent take?",
                    "options": ["run_shell", "open_app", "read_context", "chat_answer"]
                ]
            ]
        ]

        var req = URLRequest(url: endpoint, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]],
               let first = results.first,
               let choice = first["selected_option"] as? String {
                let conf = first["confidence"] as? Double ?? 1.0
                return (choice, conf)
            }
        } catch {
            return nil
        }

        return nil
    }
}
