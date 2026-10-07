import Foundation
import AppKit
import CryptoKit

// MARK: - Input Event Sources

public enum InputEventSource: String, Codable, Sendable {
    case notificationBanner = "notification_banner"
    case fileDownload       = "file_download"
    case screenshot         = "screenshot"
    case mail               = "mail"
    case calendar           = "calendar"
    case clipboard          = "clipboard"
    case customIPC          = "custom_ipc"
}

// MARK: - Unified Input Event

public struct InputEvent: Identifiable, Sendable {
    public let id: UUID
    public let source: InputEventSource
    public let appName: String
    public let title: String
    public let content: String
    public let metadata: [String: String]
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        source: InputEventSource,
        appName: String,
        title: String,
        content: String,
        metadata: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.appName = appName
        self.title = title
        self.content = content
        self.metadata = metadata
        self.timestamp = timestamp
    }

    public var contentHash: String {
        let raw = "\(source.rawValue):\(appName.lowercased()):\(title.trimmingCharacters(in: .whitespacesAndNewlines)):\(content.prefix(200))"
        let digest = Insecure.MD5.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}

// MARK: - Proactive Event Bus
// Central dispatch hub for all incoming notifications, file system events, and IPC triggers.
// Ensures privacy filtering, deduplication, debounce, and dispatches to the Semantic Evaluator.
@MainActor
public final class ProactiveEventBus: ObservableObject {
    public static let shared = ProactiveEventBus()

    // Deduplication & rate-limiting memory
    private var recentHashes: [String: Date] = [:]
    private var lastEvaluationTime: Date = .distantPast
    private let deduplicationWindowSeconds: TimeInterval = 15.0

    // Privacy ignore list (Sensitive applications)
    private let sensitiveAppKeywords: [String] = [
        "1password", "bitwarden", "lastpass", "keychain", "authenticator",
        "keepass", "private browsing", "incognito"
    ]

    private init() {}

    // MARK: - Ingestion
    func ingest(event: InputEvent, state: AppState) {
        // 1. Privacy filter
        let lowApp = event.appName.lowercased()
        let lowTitle = event.title.lowercased()
        for kw in sensitiveAppKeywords {
            if lowApp.contains(kw) || lowTitle.contains(kw) {
                logSentinel("Event ignored due to privacy filter: [\(event.appName)] \"\(event.title)\"")
                return
            }
        }

        // 2. Ignore empty / trivial notifications
        let trimmedTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || trimmedContent.count >= 5 else { return }

        // 3. Deduplication check
        cleanExpiredHashes()
        let hash = event.contentHash
        if let lastSeen = recentHashes[hash], Date().timeIntervalSince(lastSeen) < deduplicationWindowSeconds {
            return
        }
        recentHashes[hash] = Date()

        logSentinel("ProactiveEventBus received [\(event.source.rawValue)] from [\(event.appName)]: \"\(event.title)\" (content len: \(event.content.count))")

        // 4. Dispatch to Semantic Suggestion Evaluator
        Task {
            await SemanticSuggestionEvaluator.shared.evaluate(event: event, state: state)
        }
    }

    private func cleanExpiredHashes() {
        let now = Date()
        recentHashes = recentHashes.filter { now.timeIntervalSince($0.value) < deduplicationWindowSeconds * 3 }
    }
}
