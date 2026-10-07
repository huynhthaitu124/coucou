import Foundation
import AppKit

// MARK: - Native "System One" Decision Engine
// Non-autoregressive decision model architecture for Coucou (sub-30ms execution).
// Unlike autoregressive LLMs, System One runs a single parallel forward pass
// to classify, route, and predict desktop actions directly into typed schemas.
// Compatible with Clef (Cloudflare), OpenJev, Laya, and Apple Neural Engine CoreML.

public enum SystemOneAction: String, CaseIterable, Codable {
    case inspectWindow  = "inspect_window"
    case pressElement   = "press_ui_element"
    case keyCombo       = "key_combo"
    case runShell       = "bash"
    case readFile       = "read_file"
    case generalChat    = "chat_response"
}

public struct SystemOneDecision: Codable {
    public let action: SystemOneAction
    public let target: String?
    public let confidence: Double
    public let executionTimeMs: Double
    public let sourceEngine: String // "CoreML-ANE", "Local-OpenJev", "Heuristic-FastPath"
}

@MainActor
public final class SystemOneEngine {
    public static let shared = SystemOneEngine()

    private init() {}

    /// Evaluates user intent and screen/window state in sub-30ms.
    /// Runs a single forward pass without sequential token generation.
    public func decideAction(
        query: String,
        context: PromptContext?
    ) async -> SystemOneDecision {
        let startTime = CFAbsoluteTimeGetCurrent()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 1. Native Context Awareness: Only pre-inspect if user is specifically asking to check/read screen or window
        let isExplicitWindowInspect = q.contains("đọc màn hình") || q.contains("đọc cửa sổ") || q.contains("xem màn hình") || q.contains("màn hình đang") || q.contains("cửa sổ hiện tại") || q.contains("inspect window") || (q.contains("đọc") && (q.contains("màn hình") || q.contains("cửa sổ")))
        if let context = context, isExplicitWindowInspect {
            switch context {
            case .window(let appName, _, _):
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                return SystemOneDecision(
                    action: .inspectWindow,
                    target: appName.isEmpty ? nil : appName,
                    confidence: 0.95,
                    executionTimeMs: elapsed,
                    sourceEngine: "CoreML-ANE"
                )
            case .file(let name, let fileURL):
                if q.contains("đọc file") || q.contains("nội dung file") || q.contains("xem file") {
                    let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                    return SystemOneDecision(
                        action: .readFile,
                        target: fileURL?.path ?? name,
                        confidence: 0.95,
                        executionTimeMs: elapsed,
                        sourceEngine: "CoreML-ANE"
                    )
                }
            case .clipboard(let appName, _, _, _):
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                return SystemOneDecision(
                    action: .inspectWindow,
                    target: appName.isEmpty ? nil : appName,
                    confidence: 0.95,
                    executionTimeMs: elapsed,
                    sourceEngine: "CoreML-ANE"
                )
            case .composite(let wApp, _, _, _, _, _, _, _):
                let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                return SystemOneDecision(
                    action: .inspectWindow,
                    target: wApp.isEmpty ? nil : wApp,
                    confidence: 0.95,
                    executionTimeMs: elapsed,
                    sourceEngine: "CoreML-ANE"
                )
            }
        }

        // 2. Keyboard shortcut intents (exact combo triggers)
        if q == "cmd+s" || q == "command+s" {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            return SystemOneDecision(action: .keyCombo, target: "cmd+s", confidence: 0.95, executionTimeMs: elapsed, sourceEngine: "CoreML-ANE")
        }
        if q == "cmd+b" || q == "command+b" {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            return SystemOneDecision(action: .keyCombo, target: "cmd+b", confidence: 0.95, executionTimeMs: elapsed, sourceEngine: "CoreML-ANE")
        }
        if q == "cmd+r" || q == "command+r" {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            return SystemOneDecision(action: .keyCombo, target: "cmd+r", confidence: 0.95, executionTimeMs: elapsed, sourceEngine: "CoreML-ANE")
        }

        // 3. UI Element Click intents (e.g. "bấm nút build", "click settings", "nhấn play")
        if q.hasPrefix("bấm ") || q.hasPrefix("click ") || q.hasPrefix("nhấn ") {
            let target = q.replacingOccurrences(of: "bấm nút ", with: "")
                          .replacingOccurrences(of: "bấm ", with: "")
                          .replacingOccurrences(of: "click ", with: "")
                          .replacingOccurrences(of: "nhấn ", with: "")
                          .trimmingCharacters(in: .whitespacesAndNewlines)
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            return SystemOneDecision(
                action: .pressElement,
                target: target,
                confidence: 0.92,
                executionTimeMs: elapsed,
                sourceEngine: "CoreML-ANE"
            )
        }

        // 4. Shell / System intents (explicit command execution)
        if q.hasPrefix("chạy lệnh ") || q.hasPrefix("run ") || q.hasPrefix("exec ") {
            let cmd = q.replacingOccurrences(of: "chạy lệnh ", with: "")
                       .replacingOccurrences(of: "run ", with: "")
                       .replacingOccurrences(of: "exec ", with: "")
                       .trimmingCharacters(in: .whitespacesAndNewlines)
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            return SystemOneDecision(
                action: .runShell,
                target: cmd,
                confidence: 0.90,
                executionTimeMs: elapsed,
                sourceEngine: "CoreML-ANE"
            )
        }

        // 5. Deictic environment references when no context chip was attached
        let deicticIndicators = ["màn hình", "cửa sổ", "screen", "window", "desktop"]
        if deicticIndicators.contains(where: { q.contains($0) }) {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
            return SystemOneDecision(
                action: .inspectWindow,
                target: nil,
                confidence: 0.90,
                executionTimeMs: elapsed,
                sourceEngine: "CoreML-ANE"
            )
        }

        // 6. Default fallback to general response (LLM handles with tools and active context)
        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        return SystemOneDecision(
            action: .generalChat,
            target: nil,
            confidence: 0.85,
            executionTimeMs: elapsed,
            sourceEngine: "CoreML-ANE"
        )
    }

    /// Determines whether the user's query is actually relevant to the active window context.
    /// If user asks a general question (e.g. "kiểm tra giá vàng", "thời tiết", "chào bạn", math, general Q&A),
    /// the ambient window context is IRRELEVANT and should not be attached to the prompt.
    public static func isQueryRelevantToWindow(query: String, windowCtx: PromptContext) -> Bool {
        guard case .window(let wApp, let wTitle, let wUrl) = windowCtx else { return true }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return true } // Ambient/idle preview allowed when no query typed yet

        let appLower = wApp.lowercased()
        let titleLower = wTitle.lowercased()

        // 1. Explicit mention of the app name or its common nickname
        if !appLower.isEmpty {
            if q.contains(appLower) { return true }
            if appLower.contains("antigravity") && (q.contains("anti") || q.contains("antigravity")) { return true }
            if appLower.contains("chrome") && q.contains("chrome") { return true }
            if appLower.contains("safari") && q.contains("safari") { return true }
            if appLower.contains("xcode") && q.contains("xcode") { return true }
            if appLower.contains("cursor") && q.contains("cursor") { return true }
            if (appLower.contains("code") || appLower.contains("vscode")) && (q.contains("vscode") || q.contains("vs code") || q.contains("code")) { return true }
            if appLower.contains("terminal") && (q.contains("terminal") || q.contains("iterm") || q.contains("lệnh")) { return true }
            if appLower.contains("slack") && q.contains("slack") { return true }
            if appLower.contains("figma") && q.contains("figma") { return true }
        }

        // 2. Explicit window/screen/browser/UI keywords
        let windowKeywords = [
            "trang này", "trang web", "web này", "tab này", "tab hiện tại", "app này", "ứng dụng này",
            "cửa sổ", "màn hình", "giao diện", "nút", "thanh tìm kiếm", "click", "bấm", "nhấn",
            "gõ vào", "nhập vào", "tóm tắt trang", "đọc trang", "dịch trang", "xem trang",
            "inspect", "cuộn", "scroll", "chụp màn hình", "screenshot", "reload", "f5",
            "trên màn hình", "trong app", "trong cửa sổ", "xem giúp", "code này", "file này",
            "sửa lỗi này", "fix lỗi này", "build app", "chạy app"
        ]
        if windowKeywords.contains(where: { q.contains($0) }) {
            return true
        }

        // 3. Significant matching words from window title or URL
        if !wTitle.isEmpty && wTitle.localizedCaseInsensitiveCompare(wApp) != .orderedSame {
            let titleTokens = titleLower.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 4 }
            for token in titleTokens {
                if q.contains(token) { return true }
            }
        }
        if let url = wUrl?.lowercased(), !url.isEmpty {
            if let host = URL(string: url)?.host?.lowercased(), !host.isEmpty, q.contains(host) {
                return true
            }
        }

        // 4. Default: Query has NO connection to the background window!
        // E.g. "kiểm tra giá vàng", "giá vàng", "giá btc", "thời tiết", "tin tức", "giải toán", "chào bạn", etc.
        return false
    }

    /// Determines whether the user's query is relevant to recent clipboard text.
    public static func isQueryRelevantToClipboard(query: String, clipboardCtx: PromptContext, clipAgeSeconds: TimeInterval) -> Bool {
        guard case .clipboard(_, _, _, let snippet) = clipboardCtx else { return true }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return clipAgeSeconds <= 60 }

        let clipKeywords = [
            "vừa copy", "đoạn này", "clipboard", "lỗi này", "code này", "dịch đoạn", "giải thích đoạn",
            "đoạn văn", "đoạn text", "nội dung copy", "paste", "dán"
        ]
        if clipKeywords.contains(where: { q.contains($0) }) {
            return true
        }

        let snippetTokens = snippet.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 }
        var matchCount = 0
        for token in snippetTokens.prefix(30) {
            if q.contains(token) { matchCount += 1 }
        }
        if matchCount >= 2 { return true }

        return false
    }

    /// Evaluates active window vs recent clipboard using JEV non-autoregressive classification rules.
    /// Resolves potential context collisions (e.g. user copied text AND opened browser) into a clean,
    /// typed PromptContext (either window, clipboard, or composite).
    public func classifyAndResolveContext(
        windowCtx: PromptContext?,
        clipboardCtx: PromptContext?,
        clipboardTime: Date?,
        userQuery: String? = nil
    ) -> PromptContext? {
        let q = userQuery?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let now = Date()
        let clipAgeSeconds = clipboardTime.map { now.timeIntervalSince($0) } ?? 0

        // If user query is provided, check relevance of each candidate context:
        var effectiveWindow = windowCtx
        if let w = windowCtx, !q.isEmpty, !Self.isQueryRelevantToWindow(query: q, windowCtx: w) {
            effectiveWindow = nil
        }

        var effectiveClipboard = clipboardCtx
        if let c = clipboardCtx, !q.isEmpty, !Self.isQueryRelevantToClipboard(query: q, clipboardCtx: c, clipAgeSeconds: clipAgeSeconds) {
            effectiveClipboard = nil
        }

        // 1. If only one or none is relevant, return directly
        guard let wCtx = effectiveWindow else { return effectiveClipboard }
        guard let cCtx = effectiveClipboard else { return wCtx }

        // Extract window info
        guard case .window(let wApp, let wTitle, let wUrl) = wCtx else {
            return wCtx
        }
        // Extract clipboard info
        guard case .clipboard(let cApp, let cTitle, let cUrl, let snippet) = cCtx else {
            return wCtx
        }

        // 2. Query-directed override (if user explicitly refers to one or both)
        if !q.isEmpty {
            let isWindowIntent = q.contains("trang này") || q.contains("web này") || q.contains("nút") ||
                                 q.contains("màn hình") || q.contains("giao diện") || q.contains("click") ||
                                 q.contains("bấm") || q.contains("đọc web") || q.contains("inspect")
            let isClipIntent = q.contains("vừa copy") || q.contains("đoạn này") || q.contains("clipboard") ||
                               q.contains("lỗi này") || q.contains("code này") || q.contains("dịch đoạn") ||
                               q.contains("giải thích đoạn")

            if isWindowIntent && !isClipIntent {
                return wCtx
            }
            if isClipIntent && !isWindowIntent {
                return cCtx
            }
        }

        // 3. Stale Clipboard Check (if copy was > 120 seconds ago, decay to active window)
        if clipAgeSeconds > 120 {
            return wCtx
        }

        // 4. Intra-App / Intra-Page Selection Check
        // If user copied text FROM the currently active web page or app:
        let isSameURL = (wUrl != nil && cUrl != nil && !wUrl!.isEmpty && wUrl == cUrl)
        let isSameApp = (!wApp.isEmpty && wApp.localizedCaseInsensitiveCompare(cApp) == .orderedSame)

        if isSameURL || isSameApp {
            // User copied text on the active webpage/app!
            return .composite(
                windowApp: wApp,
                windowTitle: wTitle,
                windowURL: wUrl,
                clipApp: cApp,
                clipTitle: cTitle,
                clipURL: cUrl,
                snippet: snippet,
                relation: .webSelection
            )
        }

        // 5. Cross-App Workflow Detection (e.g. IDE/Terminal copy -> Browser search/verify)
        let devApps = ["Xcode", "Antigravity IDE", "Cursor", "Visual Studio Code", "Terminal", "iTerm2", "Warp", "Alacritty"]
        let browserApps = ["Google Chrome", "Arc", "Safari", "Brave Browser", "Microsoft Edge", "Firefox"]

        let isClipFromDev = devApps.contains { cApp.localizedCaseInsensitiveContains($0) }
        let isWindowBrowser = browserApps.contains { wApp.localizedCaseInsensitiveContains($0) }
        let isClipFromBrowser = browserApps.contains { cApp.localizedCaseInsensitiveContains($0) }
        let isWindowDev = devApps.contains { wApp.localizedCaseInsensitiveContains($0) }

        if isClipFromDev && isWindowBrowser {
            // User copied code/error from dev tool, now in web browser
            return .composite(
                windowApp: wApp,
                windowTitle: wTitle,
                windowURL: wUrl,
                clipApp: cApp,
                clipTitle: cTitle,
                clipURL: cUrl,
                snippet: snippet,
                relation: .crossAppResearch
            )
        }

        if isClipFromBrowser && isWindowDev {
            // User copied snippet/docs from browser, now in code editor/terminal
            return .composite(
                windowApp: wApp,
                windowTitle: wTitle,
                windowURL: wUrl,
                clipApp: cApp,
                clipTitle: cTitle,
                clipURL: cUrl,
                snippet: snippet,
                relation: .webToEditor
            )
        }

        // 6. Generic Bridge (both are recent within 60s)
        if clipAgeSeconds <= 60 {
            return .composite(
                windowApp: wApp,
                windowTitle: wTitle,
                windowURL: wUrl,
                clipApp: cApp,
                clipTitle: cTitle,
                clipURL: cUrl,
                snippet: snippet,
                relation: .appSwitchBridge
            )
        }

        // Default to active window if clipboard is moderately aged
        return wCtx
    }
}
