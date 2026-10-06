import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Window context capture (M8)

enum WindowContextCapture {

    /// Returns a PromptContext from the given app (or frontmost external app).
    /// Uses browser AppleScript for real-time active tab title & URL (Safari, Chrome, Arc, Brave, Edge, Firefox).
    /// Uses CGWindowList / AXUIElement for native window title.
    @MainActor
    static func captureActive(from app: NSRunningApplication? = nil) -> PromptContext? {
        #if APPSTORE
        // App Store: no Accessibility API, no screen capture
        return nil
        #else
        let ourBundle = Bundle.main.bundleIdentifier ?? ""
        var targetApp = (app?.bundleIdentifier != ourBundle) ? app : nil
        var windowTitle = ""
        var browserUrl: String? = nil

        // 1. If targetApp not specified, find topmost external layer-0 window from CGWindowList
        if targetApp == nil {
            if let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                let ignored = ["Coucou", "Window Server", "Dock", "Notification Center", "Spotlight", "SystemUIServer", "TextInputMenuAgent", "Control Center"]
                for info in infoList {
                    let layer = info[kCGWindowLayer as String] as? Int ?? -1
                    let owner = info[kCGWindowOwnerName as String] as? String ?? ""
                    let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
                    let name = info[kCGWindowName as String] as? String ?? ""
                    let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
                    let width = bounds["Width"] as? CGFloat ?? 0
                    let height = bounds["Height"] as? CGFloat ?? 0

                    guard layer == 0, width > 80, height > 80 else { continue }
                    guard !owner.isEmpty, !ignored.contains(owner) else { continue }

                    if let found = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid }),
                       found.bundleIdentifier != ourBundle,
                       found.activationPolicy == .regular {
                        targetApp = found
                        if !name.isEmpty { windowTitle = name }
                        break
                    }
                }
            }
        }

        // 2. Fallback to frontmostApplication if not Coucou
        if targetApp == nil,
           let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != ourBundle,
           front.activationPolicy == .regular {
            targetApp = front
        }

        // 3. Fallback to AppState.shared.lastExternalApp
        if targetApp == nil,
           let last = AppState.shared.lastExternalApp,
           last.bundleIdentifier != ourBundle {
            targetApp = last
        }

        guard let validApp = targetApp,
              let appName = validApp.localizedName,
              validApp.bundleIdentifier != ourBundle else {
            return nil
        }

        // 4. If it's a browser, query active tab title & URL dynamically
        if let tabInfo = browserTabInfo(for: validApp) {
            if let t = tabInfo.title, !t.isEmpty {
                windowTitle = t
            }
            browserUrl = tabInfo.url
        }

        // 5. If windowTitle is still empty, look up in CGWindowList for this specific app
        if windowTitle.isEmpty {
            if let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                for info in infoList {
                    let layer = info[kCGWindowLayer as String] as? Int ?? -1
                    let pid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
                    let name = info[kCGWindowName as String] as? String ?? ""
                    let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
                    let width = bounds["Width"] as? CGFloat ?? 0
                    let height = bounds["Height"] as? CGFloat ?? 0

                    guard layer == 0, width > 80, height > 80, pid == validApp.processIdentifier else { continue }
                    if !name.isEmpty {
                        windowTitle = name
                        break
                    }
                }
            }
        }

        // 6. Fallback to AXUIElement for native window title
        if windowTitle.isEmpty {
            let pid = validApp.processIdentifier
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
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let t = titleRef as? String {
                    windowTitle = t
                }
            }
        }

        return .window(appName: appName, title: windowTitle, url: browserUrl)
        #endif
    }

    // MARK: - Browser Active Tab Info

    static func browserTabInfo(for app: NSRunningApplication) -> (title: String?, url: String?)? {
        #if APPSTORE
        return nil
        #else
        guard let bundleId = app.bundleIdentifier else { return nil }
        let script: String
        switch bundleId {
        case "com.google.Chrome":
            script = "tell application \"Google Chrome\" to if (count of windows) > 0 then return (title of active tab of front window) & \"\t\" & (URL of active tab of front window)"
        case "company.thebrowser.Browser":
            script = "tell application \"Arc\" to if (count of windows) > 0 then return (title of active tab of front window) & \"\t\" & (URL of active tab of front window)"
        case "com.brave.Browser":
            script = "tell application \"Brave Browser\" to if (count of windows) > 0 then return (title of active tab of front window) & \"\t\" & (URL of active tab of front window)"
        case "com.microsoft.edgemac":
            script = "tell application \"Microsoft Edge\" to if (count of windows) > 0 then return (title of active tab of front window) & \"\t\" & (URL of active tab of front window)"
        case "com.apple.Safari":
            script = "tell application \"Safari\" to if (count of windows) > 0 then return (name of current tab of front window) & \"\t\" & (URL of current tab of front window)"
        case "com.apple.SafariTechnologyPreview":
            script = "tell application \"Safari Technology Preview\" to if (count of windows) > 0 then return (name of current tab of front window) & \"\t\" & (URL of current tab of front window)"
        case "org.mozilla.firefox":
            script = "tell application \"Firefox\" to if (count of windows) > 0 then return URL of active tab of front window"
        default:
            return nil
        }

        var error: NSDictionary?
        guard let output = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue,
              !output.isEmpty else {
            return nil
        }

        let parts = output.components(separatedBy: "\t")
        if parts.count >= 2 {
            let t = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let u = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return (t.isEmpty ? nil : t, u.isEmpty ? nil : u)
        } else {
            let val = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if val.hasPrefix("http://") || val.hasPrefix("https://") {
                return (nil, val)
            } else {
                return (val.isEmpty ? nil : val, nil)
            }
        }
        #endif
    }
}

// MARK: - Sentinel Logger (Real-time observability)
func logSentinel(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    NSLog("[Coucou Sentinel] %@", msg)
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/coucou_sentinel.log")) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: "/tmp/coucou_sentinel.log"), options: .atomic)
        }
    }
}

// MARK: - Universal Desktop State Snapshot
public struct UniversalStateSnapshot: Equatable {
    public let appName: String
    public let bundleId: String?
    public let windowTitle: String
    public let browserURL: String?
    public let visibleTextSnippet: String
    public let clipboardSnippet: String?
    public let timestamp: Date = Date()

    public var hashValueKey: String {
        "\(appName):\(windowTitle):\(browserURL ?? ""):\(visibleTextSnippet.prefix(150)):\(clipboardSnippet?.prefix(100) ?? "")"
    }
}

// MARK: - Coucou Background Sentinel (Autonomous 24/7 Model-Driven Observer)
// Runs continuously in the background, observes user desktop state,
// and invokes a lightweight AI model to generate dynamic suggestions and actions without hardcoded rules.
@MainActor
public final class CoucouSentinel: ObservableObject {
    public static let shared = CoucouSentinel()

    private var isMonitoring = false
    private var isEvaluating = false
    private var lastSnapshotHash: String = ""
    private var lastEvaluationTime: Date = .distantPast
    private var dismissTimer: Timer?
    private var clipboardPollingTimer: Timer?
    private var windowTabPollingTimer: Timer?
    private var debounceTask: Task<Void, Never>?
    private var clipboardChangeCount: Int = 0

    // Real-time tracking of active window/tab changes
    private var lastObservedAppPid: pid_t = 0
    private var lastObservedTabUrl: String = ""
    private var lastObservedWindowTitle: String = ""

    // Short-term anti-repetition memory
    private var recentSuggestionTitles: [String] = []
    private var recentContextHashes: [String: Date] = [:]

    private init() {}

    func startMonitoring(state: AppState) {
        guard !isMonitoring else { return }
        isMonitoring = true
        clipboardChangeCount = NSPasteboard.general.changeCount

        logSentinel("Coucou Sentinel 24/7 started (event-driven context & clipboard engine)")

        // 1. Immediate App switch observer
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                state.lastExternalApp = app
            }
            self?.scheduleDebouncedEvaluation(state: state, delayMs: 250, immediate: true)
        }

        // 2. Space switch observer
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleDebouncedEvaluation(state: state, delayMs: 300, immediate: true)
        }

        // 3. Ultra-fast event-driven Clipboard Observer (0.25s polling, zero-lag copy detection)
        let clipTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let count = NSPasteboard.general.changeCount
            if count != self.clipboardChangeCount {
                self.clipboardChangeCount = count
                Task { @MainActor in
                    self.handleClipboardChange(state: state)
                }
            }
        }
        RunLoop.main.add(clipTimer, forMode: .common)
        clipboardPollingTimer = clipTimer

        // 4. Fast active window & tab ticker (every 1.0s to detect tab switching in browsers and editors)
        let tabTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkActiveWindowAndTabDelta(state: state)
            }
        }
        RunLoop.main.add(tabTimer, forMode: .common)
        windowTabPollingTimer = tabTimer

        // Initial evaluation
        scheduleDebouncedEvaluation(state: state, delayMs: 300, immediate: true)
    }

    private func scheduleDebouncedEvaluation(state: AppState, delayMs: UInt64, immediate: Bool) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            guard !Task.isCancelled else { return }
            self.evaluateContextDelta(state: state, immediate: immediate)
        }
    }

    // MARK: - Window Title Helper

    private func getWindowTitle(for app: NSRunningApplication) -> String {
        let pid = app.processIdentifier
        let appName = app.localizedName ?? ""

        if let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for info in infoList {
                let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
                let owner = info[kCGWindowOwnerName as String] as? String ?? ""
                let layer = info[kCGWindowLayer as String] as? Int ?? -1
                let name = info[kCGWindowName as String] as? String ?? ""
                let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
                let width = bounds["Width"] as? CGFloat ?? 0
                let height = bounds["Height"] as? CGFloat ?? 0

                if (ownerPid == pid || owner == appName) && layer == 0 && width > 100 && height > 100 && !name.isEmpty {
                    return name
                }
            }
        }

        let axApp = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) != .success || windowRef == nil {
            _ = AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &windowRef)
        }
        if let windowRef {
            let axWindow = windowRef as! AXUIElement
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
               let t = titleRef as? String, !t.isEmpty {
                return t
            }
        }

        return appName
    }

    private func isClipboardContext(_ ctx: PromptContext?) -> Bool {
        guard let ctx else { return false }
        if case .clipboard = ctx { return true }
        return false
    }

    private func isFileContext(_ ctx: PromptContext?) -> Bool {
        guard let ctx else { return false }
        if case .file = ctx { return true }
        return false
    }

    // MARK: - Real-time Tab & Window Delta Detection

    private func checkActiveWindowAndTabDelta(state: AppState) {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return
        }

        let pid = front.processIdentifier
        var currentTitle = ""
        var currentURL: String = ""

        if let tabInfo = WindowContextCapture.browserTabInfo(for: front) {
            currentTitle = tabInfo.title ?? ""
            currentURL = tabInfo.url ?? ""
        } else {
            currentTitle = getWindowTitle(for: front)
        }

        let pidChanged = (pid != lastObservedAppPid)
        let tabChanged = (!currentURL.isEmpty && currentURL != lastObservedTabUrl)
        let titleChanged = (!currentTitle.isEmpty && currentTitle != lastObservedWindowTitle)

        if pidChanged || tabChanged || titleChanged {
            lastObservedAppPid = pid
            lastObservedTabUrl = currentURL
            lastObservedWindowTitle = currentTitle
            state.lastExternalApp = front

            // Update promptContext for active window only if not user-pinned file or recent clipboard
            if state.promptContext == nil || (!isClipboardContext(state.promptContext) && !isFileContext(state.promptContext)) {
                let fresh = PromptContext.window(
                    appName: front.localizedName ?? "App",
                    title: currentTitle.isEmpty ? (front.localizedName ?? "") : currentTitle,
                    url: currentURL.isEmpty ? nil : currentURL
                )
                if state.dismissedContextKey != fresh.contextKey && state.promptContext != fresh {
                    state.promptContext = fresh
                }
            }

            scheduleDebouncedEvaluation(state: state, delayMs: 400, immediate: true)
        }
    }

    // MARK: - Clipboard Source & Context Capture

    private func handleClipboardChange(state: AppState) {
        guard let copiedText = NSPasteboard.general.string(forType: .string),
              !copiedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              copiedText.count >= 2 else {
            return
        }

        // Capture frontmost application at the exact moment of copy (Cmd+C)
        let front = NSWorkspace.shared.frontmostApplication
        let ourBundle = Bundle.main.bundleIdentifier ?? ""
        let targetApp: NSRunningApplication? = (front?.bundleIdentifier != ourBundle) ? front : state.lastExternalApp

        guard let validApp = targetApp, validApp.bundleIdentifier != ourBundle else { return }

        let sourceApp = validApp.localizedName ?? "App"
        var sourceTitle = ""
        var sourceURL: String? = nil

        if let tabInfo = WindowContextCapture.browserTabInfo(for: validApp) {
            sourceTitle = tabInfo.title ?? ""
            sourceURL = tabInfo.url
        }

        if sourceTitle.isEmpty {
            sourceTitle = getWindowTitle(for: validApp)
        }
        if sourceTitle.isEmpty {
            sourceTitle = sourceApp
        }

        let snippet = String(copiedText.prefix(4000))
        let promptCtx = PromptContext.clipboard(
            sourceApp: sourceApp,
            sourceTitle: sourceTitle,
            sourceURL: sourceURL,
            snippet: snippet
        )

        // Set prompt context immediately so chip in Coucou UI displays source
        state.promptContext = promptCtx
        state.dismissedContextKey = nil

        logSentinel("Clipboard copy detected from [\(sourceApp)]: \"\(sourceTitle)\", url=\(sourceURL ?? "nil"), len=\(copiedText.count)")

        // Subtle bot squash & blink on copy detection
        NotificationCenter.default.post(name: .botSquash, object: nil)
        NotificationCenter.default.post(name: .botBlink, object: nil)

        evaluateClipboardSuggestion(
            sourceApp: sourceApp,
            sourceTitle: sourceTitle,
            sourceURL: sourceURL,
            copiedText: copiedText,
            promptCtx: promptCtx,
            state: state
        )
    }

    private func evaluateClipboardSuggestion(
        sourceApp: String,
        sourceTitle: String,
        sourceURL: String?,
        copiedText: String,
        promptCtx: PromptContext,
        state: AppState
    ) {
        // 1. Instant heuristic suggestion
        if let heuristic = generateHeuristicClipboardSuggestion(
            sourceApp: sourceApp,
            sourceTitle: sourceTitle,
            sourceURL: sourceURL,
            copiedText: copiedText,
            promptCtx: promptCtx
        ) {
            presentSuggestion(heuristic, state: state)
        }

        // 2. Query AI model in background to produce a refined, custom suggestion if available
        Task {
            let snippet = String(copiedText.prefix(2000))
            var info = "Source App: \(sourceApp)\nWindow/Tab Title: \"\(sourceTitle)\""
            if let u = sourceURL, !u.isEmpty { info += "\nBrowser URL: \(u)" }
            info += "\nCopied Content:\n\(snippet)"

            let systemPrompt = """
            You are Coucou's 24/7 Proactive Observer on macOS. The user just copied content using Cmd+C.
            Analyze the source application ("\(sourceApp)") and the copied text to suggest the single most useful action.

            CRITICAL TEXT LENGTH RULES (DISPLAYED IN NOTCH):
            - "title": MAXIMUM 2-3 words ONLY (e.g. "Review PR", "Sửa lỗi Terminal", "Tối ưu SQL", "Dịch tiếng Việt").
            - "detail": 4-6 words maximum (under 28 characters). E.g. "Tóm tắt từ \(sourceApp)".
            - "actionQuery": Detailed user instruction for Coucou Claude to execute.

            Respond in valid JSON only with NO markdown fences:
            {
              "shouldSuggest": true,
              "icon": "valid SF Symbol name",
              "title": "2-3 words",
              "detail": "4-6 words max",
              "actionQuery": "The exact user instruction/prompt for Coucou to execute"
            }
            """

            if let output = await querySentinelModels(system: systemPrompt, prompt: info) {
                await MainActor.run {
                    guard output.shouldSuggest,
                          let rawTitle = output.title, !rawTitle.isEmpty,
                          let action = output.actionQuery, !action.isEmpty else {
                        return
                    }

                    var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if title.count > 24 { title = String(title.prefix(22)) + "…" }
                    var detail = output.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let d = detail, d.count > 32 { detail = String(d.prefix(30)) + "…" }

                    let icon = output.icon ?? "sparkles"
                    let aiSuggestion = ProactiveSuggestion(
                        icon: icon,
                        title: title,
                        detail: detail,
                        actionQuery: action,
                        context: promptCtx
                    )
                    self.presentSuggestion(aiSuggestion, state: state)
                }
            }
        }
    }

    // MARK: - Smart Heuristic Suggestion Generators

    private func generateHeuristicClipboardSuggestion(
        sourceApp: String,
        sourceTitle: String,
        sourceURL: String?,
        copiedText: String,
        promptCtx: PromptContext
    ) -> ProactiveSuggestion? {
        let trimmed = copiedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }
        let lower = trimmed.lowercased()

        // 1. URL copied
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            if lower.contains("github.com") && lower.contains("/pull/") {
                return ProactiveSuggestion(
                    icon: "arrow.triangle.pull",
                    title: "Xem Pull Request",
                    detail: "Tóm tắt PR từ \(sourceApp)",
                    actionQuery: "Tóm tắt pull request sau từ GitHub: \(trimmed). Nêu rõ mục đích, các thay đổi chính và các điểm cần lưu ý khi review.",
                    context: promptCtx
                )
            } else if lower.contains("github.com") && lower.contains("/issues/") {
                return ProactiveSuggestion(
                    icon: "exclamationmark.circle.fill",
                    title: "Tóm tắt Issue",
                    detail: "Phân tích issue trên GitHub",
                    actionQuery: "Tóm tắt nội dung và giải pháp được đề xuất trong issue GitHub này: \(trimmed)",
                    context: promptCtx
                )
            } else if lower.contains("youtube.com") || lower.contains("youtu.be") {
                return ProactiveSuggestion(
                    icon: "play.rectangle.fill",
                    title: "Tóm tắt Video",
                    detail: "Tóm tắt nội dung YouTube",
                    actionQuery: "Tóm tắt nội dung và các ý chính của video YouTube sau: \(trimmed)",
                    context: promptCtx
                )
            } else {
                let host = URL(string: trimmed)?.host ?? sourceApp
                return ProactiveSuggestion(
                    icon: "safari.fill",
                    title: "Tóm tắt liên kết",
                    detail: "Đọc nội dung từ \(host)",
                    actionQuery: "Đọc và tóm tắt những thông tin quan trọng nhất từ trang web: \(trimmed)",
                    context: promptCtx
                )
            }
        }

        // 2. Error / Exception / Stack Trace
        let errorMarkers = [
            "error:", "exception:", "fatal:", "failed:", "traceback (most recent",
            "syntaxerror", "typeerror", "referenceerror", "panic:", "build failed",
            "undefined is not a function", "nullpointerexception", "segmentation fault",
            "uncaught error", "failed to compile", "command failed", "404 not found", "500 internal"
        ]
        if errorMarkers.contains(where: { lower.contains($0) }) {
            let appLabel = sourceApp.isEmpty ? "mã nguồn" : sourceApp
            return ProactiveSuggestion(
                icon: "exclamationmark.triangle.fill",
                title: "Sửa lỗi \(appLabel)",
                detail: "Chẩn đoán nguyên nhân lỗi",
                actionQuery: "Chẩn đoán nguyên nhân và hướng dẫn từng bước cách sửa lỗi sau được copy từ \(sourceApp) (\(sourceTitle)):\n\n```\n\(String(trimmed.prefix(2500)))\n```",
                context: promptCtx
            )
        }

        // 3. SQL Query
        if lower.hasPrefix("select ") || lower.hasPrefix("insert into ") || lower.hasPrefix("update ") || lower.hasPrefix("delete from ") || lower.hasPrefix("create table ") {
            return ProactiveSuggestion(
                icon: "cylinder.split.1x2",
                title: "Tối ưu câu SQL",
                detail: "Phân tích query từ \(sourceApp)",
                actionQuery: "Phân tích cú pháp, chỉ mục và đề xuất tối ưu hóa câu lệnh SQL sau được copy từ \(sourceApp):\n\n```sql\n\(String(trimmed.prefix(2500)))\n```",
                context: promptCtx
            )
        }

        // 4. Shell / Terminal Command
        if lower.hasPrefix("git ") || lower.hasPrefix("docker ") || lower.hasPrefix("kubectl ") || lower.hasPrefix("curl ") || lower.hasPrefix("brew ") || lower.hasPrefix("npm ") || lower.hasPrefix("pnpm ") || lower.hasPrefix("yarn ") || lower.hasPrefix("ssh ") {
            return ProactiveSuggestion(
                icon: "terminal.fill",
                title: "Giải thích lệnh",
                detail: "Phân tích lệnh \(sourceApp)",
                actionQuery: "Giải thích chi tiết tác dụng, từng tham số cờ và cảnh báo rủi ro an toàn cho lệnh terminal này được copy từ \(sourceApp):\n\n`\(String(trimmed.prefix(500)))`",
                context: promptCtx
            )
        }

        // 5. JSON Data
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            if (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil {
                return ProactiveSuggestion(
                    icon: "curlybraces",
                    title: "Format JSON",
                    detail: "Format chuẩn hoá từ \(sourceApp)",
                    actionQuery: "Format đẹp chuẩn và phân tích cấu trúc schema của dữ liệu JSON này được copy từ \(sourceApp):\n\n```json\n\(String(trimmed.prefix(2500)))\n```",
                    context: promptCtx
                )
            }
        }

        // 6. Code snippet
        let codeMarkers = ["func ", "function ", "def ", "class ", "struct ", "enum ", "import ", "const ", "var ", "let ", "public ", "private ", "return ", "interface ", "async ", "await "]
        if codeMarkers.contains(where: { lower.contains($0) }) {
            return ProactiveSuggestion(
                icon: "chevron.left.forwardslash.chevron.right",
                title: "Giải thích code",
                detail: "Phân tích logic từ \(sourceApp)",
                actionQuery: "Giải thích chi tiết logic đoạn mã này được copy từ \(sourceApp) (\(sourceTitle)). Tìm lỗi tiềm ẩn và gợi ý cải tiến refactor:\n\n```\n\(String(trimmed.prefix(2500)))\n```",
                context: promptCtx
            )
        }

        // 7. English text / Reading passage (> 60 chars)
        if trimmed.count > 60 {
            let englishWords = ["the", "and", "that", "this", "with", "from", "for", "have", "not", "with", "you", "are"]
            let words = lower.components(separatedBy: .whitespacesAndNewlines)
            let englishMatches = words.filter { englishWords.contains($0) }.count
            if englishMatches >= 2 {
                return ProactiveSuggestion(
                    icon: "character.book.closed.fill",
                    title: "Dịch tiếng Việt",
                    detail: "Dịch ngữ cảnh từ \(sourceApp)",
                    actionQuery: "Dịch đoạn văn bản sau được copy từ \(sourceApp) (\(sourceTitle)) sang tiếng Việt tự nhiên và tóm tắt các ý chính:\n\n\"\(String(trimmed.prefix(2500)))\"",
                    context: promptCtx
                )
            } else {
                return ProactiveSuggestion(
                    icon: "doc.text.magnifyingglass",
                    title: "Tóm tắt nội dung",
                    detail: "Tóm tắt từ \(sourceApp)",
                    actionQuery: "Tóm tắt ngắn gọn các ý quan trọng nhất của đoạn văn bản sau được copy từ \(sourceApp) (\(sourceTitle)):\n\n\"\(String(trimmed.prefix(2500)))\"",
                    context: promptCtx
                )
            }
        }

        return nil
    }

    private func generateHeuristicWindowSuggestion(snapshot: UniversalStateSnapshot) -> ProactiveSuggestion? {
        let promptCtx: PromptContext = .window(appName: snapshot.appName, title: snapshot.windowTitle, url: snapshot.browserURL)

        if let u = snapshot.browserURL?.lowercased() {
            if u.contains("github.com") && u.contains("/pull/") {
                return ProactiveSuggestion(
                    icon: "arrow.triangle.pull",
                    title: "Review Pull Request",
                    detail: "Tóm tắt PR GitHub",
                    actionQuery: "Tóm tắt pull request này và các thay đổi chính: \(snapshot.browserURL ?? snapshot.windowTitle)",
                    context: promptCtx
                )
            } else if u.contains("github.com") && u.contains("/issues/") {
                return ProactiveSuggestion(
                    icon: "exclamationmark.circle.fill",
                    title: "Tóm tắt Issue",
                    detail: "Phân tích issue GitHub",
                    actionQuery: "Tóm tắt vấn đề và các giải pháp đề xuất trong issue này: \(snapshot.browserURL ?? snapshot.windowTitle)",
                    context: promptCtx
                )
            } else if u.contains("stackoverflow.com") {
                return ProactiveSuggestion(
                    icon: "doc.text.magnifyingglass",
                    title: "Tóm tắt giải pháp",
                    detail: "Đọc câu trả lời hay nhất",
                    actionQuery: "Tóm tắt giải pháp được bình chọn cao nhất cho câu hỏi trên StackOverflow: \(snapshot.browserURL ?? snapshot.windowTitle)",
                    context: promptCtx
                )
            }
        }

        let appLow = snapshot.appName.lowercased()
        if appLow.contains("terminal") || appLow.contains("ghostty") || appLow.contains("iterm") || appLow.contains("warp") {
            return ProactiveSuggestion(
                icon: "terminal.fill",
                title: "Trợ lý dòng lệnh",
                detail: "Hỗ trợ Terminal",
                actionQuery: "Trợ lý dòng lệnh: tôi đang ở terminal \"\(snapshot.windowTitle)\". Hãy sẵn sàng hỗ trợ tôi các lệnh shell.",
                context: promptCtx
            )
        }

        return nil
    }

    // MARK: - General Context Evaluation Loop

    private func evaluateContextDelta(state: AppState, immediate: Bool = false) {
        guard !isEvaluating else { return }

        let minCooldown: TimeInterval = immediate ? 1.0 : 3.0
        guard Date().timeIntervalSince(lastEvaluationTime) >= minCooldown else { return }

        let frontApp: NSRunningApplication? = {
            if let front = NSWorkspace.shared.frontmostApplication,
               front.bundleIdentifier != Bundle.main.bundleIdentifier {
                return front
            }
            if let last = state.lastExternalApp,
               last.bundleIdentifier != Bundle.main.bundleIdentifier {
                return last
            }
            return NSWorkspace.shared.runningApplications.first(where: {
                $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
            })
        }()

        guard let frontApp else { return }

        let appName = frontApp.localizedName ?? "App"
        let bundleId = frontApp.bundleIdentifier

        var windowTitle = ""
        let pid = frontApp.processIdentifier

        if let tabInfo = WindowContextCapture.browserTabInfo(for: frontApp) {
            windowTitle = tabInfo.title ?? ""
        }
        if windowTitle.isEmpty {
            windowTitle = getWindowTitle(for: frontApp)
        }

        let axApp = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) != .success || windowRef == nil {
            _ = AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &windowRef)
        }

        var visibleText = ""
        if let windowRef {
            let axWindow = windowRef as! AXUIElement
            var focusedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWindow, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
               let focusedRef {
                let axFocused = focusedRef as! AXUIElement
                var valRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axFocused, kAXSelectedTextAttribute as CFString, &valRef) == .success,
                   let sel = valRef as? String, !sel.isEmpty {
                    visibleText = sel
                } else if AXUIElementCopyAttributeValue(axFocused, kAXValueAttribute as CFString, &valRef) == .success,
                          let v = valRef as? String, !v.isEmpty {
                    visibleText = v
                }
            }

            if visibleText.isEmpty {
                visibleText = sampleAXText(from: axWindow, maxChars: 500, depth: 0)
            }
        }

        var browserURL: String? = nil
        if let tabInfo = WindowContextCapture.browserTabInfo(for: frontApp) {
            browserURL = tabInfo.url
        }

        var clipboardSnippet: String? = nil
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            clipboardSnippet = String(text.prefix(350))
        }

        let snapshot = UniversalStateSnapshot(
            appName: appName,
            bundleId: bundleId,
            windowTitle: windowTitle,
            browserURL: browserURL,
            visibleTextSnippet: visibleText,
            clipboardSnippet: clipboardSnippet
        )

        let currentHash = snapshot.hashValueKey
        guard currentHash != lastSnapshotHash else { return }
        lastSnapshotHash = currentHash
        lastEvaluationTime = Date()

        logSentinel("Context change detected: app=\(appName), title=\"\(windowTitle)\", url=\(browserURL ?? "nil")")

        isEvaluating = true
        Task {
            let suggestion = await queryModelForSuggestion(snapshot: snapshot)
            await MainActor.run {
                self.isEvaluating = false
                guard let suggestion else { return }
                self.presentSuggestion(suggestion, state: state)
            }
        }
    }

    // MARK: - AI Model Query

    private struct SentinelModelOutput: Codable {
        let shouldSuggest: Bool
        let icon: String?
        let title: String?
        let detail: String?
        let actionQuery: String?
    }

    private func queryModelForSuggestion(snapshot: UniversalStateSnapshot) async -> ProactiveSuggestion? {
        var contextDetails = "App: \(snapshot.appName)\nWindow Title: \"\(snapshot.windowTitle)\""
        if let u = snapshot.browserURL, !u.isEmpty { contextDetails += "\nBrowser URL: \(u)" }
        if let c = snapshot.clipboardSnippet, !c.isEmpty { contextDetails += "\nRecent Clipboard Content: \(c)" }
        if !snapshot.visibleTextSnippet.isEmpty {
            contextDetails += "\nVisible Content / Selection: \(snapshot.visibleTextSnippet.prefix(500))"
        }

        let recentList = recentSuggestionTitles.suffix(5).joined(separator: ", ")
        let systemPrompt = """
        You are Coucou's 24/7 Autonomous Background Desktop Observer on macOS.
        Observe the user's active desktop context, window title, focused document, and clipboard.
        Determine if there is a proactive assistance opportunity Coucou can offer.

        LANGUAGE REQUIREMENT:
        - Match the language of the user's active document or context (Vietnamese if Vietnamese, English if English).

        CRITICAL TEXT LENGTH RULES (DISPLAYED IN NOTCH):
        - "title": MUST be maximum 2-3 words ONLY (e.g. "Review PR", "Sửa lỗi Git", "Format JSON", "Check Branch").
        - "detail": 4-6 words maximum (under 28 characters). E.g. "Tóm tắt pull request". NEVER write a full sentence.
        - DO NOT repeat recent suggestions. Recently suggested: [\(recentList)].

        Respond in valid JSON only with NO markdown fences:
        {
          "shouldSuggest": true or false,
          "icon": "valid SF Symbol name",
          "title": "Ultra-short 2-3 words",
          "detail": "Short phrase 4-6 words max",
          "actionQuery": "The exact user instruction/prompt for Coucou to execute when accepted"
        }
        """

        let promptPayload = "User desktop snapshot:\n\(contextDetails)"

        if let modelOutput = await querySentinelModels(system: systemPrompt, prompt: promptPayload) {
            if let suggestion = makeSuggestion(from: modelOutput, snapshot: snapshot) {
                return suggestion
            }
        }

        // Heuristic fallback if model returned nothing or is offline
        return generateHeuristicWindowSuggestion(snapshot: snapshot)
    }

    private func querySentinelModels(system: String, prompt: String) async -> SentinelModelOutput? {
        // 1. Anthropic Claude (haiku 3.5 ~0.8s)
        if let key = KeychainStore.shared.get("anthropic-api-key"), !key.isEmpty {
            if let result = await callAnthropicSentinel(system: system, prompt: prompt, apiKey: key) {
                return result
            }
        }

        // 2. Local Ollama (0 cost, 24/7 on Apple Silicon)
        if let localResult = await callOllamaSentinel(system: system, prompt: prompt) {
            return localResult
        }

        // 3. OpenAI (gpt-4o-mini ~1.5s)
        if let key = KeychainStore.shared.get("openai-api-key"), !key.isEmpty {
            if let cloudResult = await callOpenAISentinel(system: system, prompt: prompt, apiKey: key) {
                return cloudResult
            }
        }

        // 4. Google Gemini
        if let key = KeychainStore.shared.get("google-api-key"), !key.isEmpty {
            if let googleResult = await callGoogleSentinel(system: system, prompt: prompt, apiKey: key) {
                return googleResult
            }
        }

        return nil
    }

    private func makeSuggestion(from output: SentinelModelOutput, snapshot: UniversalStateSnapshot) -> ProactiveSuggestion? {
        guard output.shouldSuggest,
              let rawTitle = output.title, !rawTitle.isEmpty,
              let action = output.actionQuery, !action.isEmpty else {
            return nil
        }

        var title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count > 24 {
            title = String(title.prefix(22)) + "…"
        }

        var detail = output.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = detail, d.count > 32 {
            detail = String(d.prefix(30)) + "…"
        }

        if recentSuggestionTitles.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) {
            return nil
        }
        recentSuggestionTitles.append(title)
        if recentSuggestionTitles.count > 8 { recentSuggestionTitles.removeFirst() }

        let icon = output.icon ?? "sparkles"
        let promptCtx: PromptContext = .window(appName: snapshot.appName, title: snapshot.windowTitle, url: snapshot.browserURL)

        return ProactiveSuggestion(
            icon: icon,
            title: title,
            detail: detail,
            actionQuery: action,
            context: promptCtx
        )
    }

    // MARK: - Anthropic Claude Sentinel Runner (Haiku 3.5)

    private func callAnthropicSentinel(system: String, prompt: String, apiKey: String) async -> SentinelModelOutput? {
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
            "system": system + "\nRespond with valid raw JSON only, no markdown markers.",
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.2
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
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rawData = cleaned.data(using: .utf8),
                  let output = try? JSONDecoder().decode(SentinelModelOutput.self, from: rawData) else {
                return nil
            }
            return output
        } catch {
            return nil
        }
    }

    // MARK: - Ollama Local Runner

    private func callOllamaSentinel(system: String, prompt: String) async -> SentinelModelOutput? {
        guard let url = URL(string: "http://127.0.0.1:11434/v1/chat/completions") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 2.0
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "llama3.2:latest",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": prompt]
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0.2
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data

        do {
            let (resData, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return parseChatCompletionOutput(resData)
        } catch {
            return nil
        }
    }

    // MARK: - OpenAI Cloud Observer (gpt-4o-mini)

    private func callOpenAISentinel(system: String, prompt: String, apiKey: String) async -> SentinelModelOutput? {
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
            "temperature": 0.2,
            "max_tokens": 200
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data

        do {
            let (resData, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return parseChatCompletionOutput(resData)
        } catch {
            return nil
        }
    }

    // MARK: - Google Gemini Cloud Observer

    private func callGoogleSentinel(system: String, prompt: String, apiKey: String) async -> SentinelModelOutput? {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 3.5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": "gemini-2.5-flash",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": prompt]
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0.2,
            "max_tokens": 200
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data

        do {
            let (resData, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return parseChatCompletionOutput(resData)
        } catch {
            return nil
        }
    }

    private func parseChatCompletionOutput(_ data: Data) -> SentinelModelOutput? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = root["choices"] as? [[String: Any]],
               let first = choices.first,
               let msg = first["message"] as? [String: Any],
               let content = msg["content"] as? String else {
            return nil
        }
        let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawData = cleaned.data(using: .utf8),
              let output = try? JSONDecoder().decode(SentinelModelOutput.self, from: rawData) else {
            return nil
        }
        return output
    }

    // MARK: - UI Presentation

    private func presentSuggestion(_ suggestion: ProactiveSuggestion, state: AppState) {
        logSentinel("Model Suggested: \"\(suggestion.title)\" -> \(suggestion.actionQuery)")

        let low = (suggestion.title + " " + suggestion.actionQuery).lowercased()
        let emote: BotEmote
        let particle: Particle.ParticleType?

        if low.contains("lỗi") || low.contains("error") || low.contains("fix") || low.contains("chẩn đoán") {
            emote = .surprised
            particle = .spark
        } else if low.contains("pull request") || low.contains("pr") || low.contains("issue") || low.contains("github") {
            emote = .proud
            particle = .star
        } else if low.contains("video") || low.contains("youtube") || low.contains("liên kết") {
            emote = .love
            particle = .heart
        } else if low.contains("sql") || low.contains("json") || low.contains("lệnh") || low.contains("code") {
            emote = .wink
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
            // Reveal in compact notch if hidden
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        }

        // Auto-dismiss after 14 seconds if ignored
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 14.0, repeats: false) { [weak state] _ in
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.3)) {
                    state?.proactiveSuggestion = nil
                }
            }
        }
    }

    // MARK: - Helper Accessibility Traversal

    private func sampleAXText(from element: AXUIElement, maxChars: Int, depth: Int) -> String {
        guard depth < 3 else { return "" }
        var collected: [String] = []
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children.prefix(8) {
                var valRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valRef) == .success,
                   let s = valRef as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    collected.append(s.trimmingCharacters(in: .whitespacesAndNewlines))
                } else if AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &valRef) == .success,
                          let s = valRef as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    collected.append(s.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if collected.joined(separator: " ").count >= maxChars { break }
                let sub = sampleAXText(from: child, maxChars: maxChars - collected.joined(separator: " ").count, depth: depth + 1)
                if !sub.isEmpty { collected.append(sub) }
                if collected.joined(separator: " ").count >= maxChars { break }
            }
        }
        return String(collected.joined(separator: " ").prefix(maxChars))
    }

    // MARK: - Action Execution

    func acceptSuggestion(_ suggestion: ProactiveSuggestion, state: AppState) {
        dismissTimer?.invalidate()
        SoundEngine.shared.play("pop")
        NotificationCenter.default.post(name: .botSquash, object: nil)
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.proud)
        NotificationCenter.default.post(name: .botParticle, object: Particle.ParticleType.star)

        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            state.proactiveSuggestion = nil
            state.promptContext = suggestion.context
            state.mode = .expanded
            state.view = .prompt
        }
        // Launch reasoning query with assistant
        Task {
            state.chatHistory.append(ChatMessage(role: .user, content: suggestion.actionQuery))
            state.stateOverride = .thinking
            await ClaudeService.shared.chat(query: suggestion.actionQuery, context: suggestion.context, state: state)
        }
    }

    func dismissSuggestion(state: AppState) {
        dismissTimer?.invalidate()
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.annoyed)
        NotificationCenter.default.post(name: .botParticle, object: Particle.ParticleType.sweat)
        if let current = state.proactiveSuggestion {
            recentSuggestionTitles.append(current.title)
            logSentinel("User dismissed suggestion: \"\(current.title)\" - silenced from repeating.")
        }
        withAnimation(.easeOut(duration: 0.25)) {
            state.proactiveSuggestion = nil
        }
    }
}
