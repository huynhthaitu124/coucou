import Foundation

// MARK: - Coucou Context & Search Cache System
// High-performance multi-tiered cache designed for real-time meetings and rapid Q&A.
// Prevents redundant web searches, caches web page fetches, tracks meeting facts,
// and injects active meeting knowledge directly into system context to achieve sub-second response times.

public struct CacheEntry: Codable, Sendable {
    public let key: String
    public let originalQuery: String
    public let content: String
    public let timestamp: Date
    public let hitCount: Int
    public let source: String // "web_search", "web_fetch", "window_snippet"

    public init(
        key: String,
        originalQuery: String,
        content: String,
        timestamp: Date = Date(),
        hitCount: Int = 0,
        source: String
    ) {
        self.key = key
        self.originalQuery = originalQuery
        self.content = content
        self.timestamp = timestamp
        self.hitCount = hitCount
        self.source = source
    }
}

public struct MeetingKnowledgeFact: Identifiable, Codable, Sendable {
    public let id: UUID
    public let topic: String
    public let summary: String
    public let timestamp: Date

    public init(id: UUID = UUID(), topic: String, summary: String, timestamp: Date = Date()) {
        self.id = id
        self.topic = topic
        self.summary = summary
        self.timestamp = timestamp
    }
}

public final class CoucouContextCache: @unchecked Sendable {
    public static let shared = CoucouContextCache()

    private let lock = NSLock()
    private var searchCache: [String: CacheEntry] = [:]
    private var webFetchCache: [String: CacheEntry] = [:]
    private var meetingFacts: [MeetingKnowledgeFact] = []

    // Statistics
    private(set) var totalHits: Int = 0
    private(set) var totalMisses: Int = 0

    // Configuration
    public var searchTTL: TimeInterval = 45 * 60      // 45 minutes (covers meeting duration)
    public var webFetchTTL: TimeInterval = 60 * 60    // 60 minutes
    private let maxEntries: Int = 500

    private init() {
        loadPersistedCache()
    }

    // MARK: - Query Normalization & Token Set Matching

    private static let stopWords: Set<String> = [
        "la", "gi", "nhu", "the", "nao", "va", "voi", "giua", "khac", "biet", "so", "sanh", "cho", "cua", "trong", "o", "ve", "cac", "nhung", "mot",
        "the", "a", "an", "is", "what", "how", "difference", "between", "vs", "and", "or", "to", "in", "of", "for", "with", "about"
    ]

    /// Normalizes query: folds diacritics, lowercased, punctuation stripped, sorted token set
    public static func normalizeQuery(_ query: String) -> String {
        let folded = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let lower = folded.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet.whitespaces)
        let filtered = lower.unicodeScalars.filter { allowed.contains($0) }
        let clean = String(String.UnicodeScalarView(filtered))
        let tokens = clean.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .sorted()
        return tokens.joined(separator: " ")
    }

    public static func extractCoreTokens(_ normalized: String) -> Set<String> {
        let allTokens = Set(normalized.components(separatedBy: " ").filter { !$0.isEmpty })
        let filtered = allTokens.subtracting(stopWords)
        return filtered.isEmpty ? allTokens : filtered
    }

    /// Computes core token set Jaccard similarity (0.0 to 1.0)
    private static func tokenSimilarity(_ a: String, _ b: String) -> Double {
        let setA = extractCoreTokens(a)
        let setB = extractCoreTokens(b)
        guard !setA.isEmpty && !setB.isEmpty else { return 0 }
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        return Double(intersection) / Double(union)
    }

    // MARK: - Web Search Cache Operations

    public func getSearch(query: String) -> String? {
        let norm = Self.normalizeQuery(query)
        guard !norm.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        let now = Date()

        // 1. Exact normalized match
        if let entry = searchCache[norm] {
            if now.timeIntervalSince(entry.timestamp) < searchTTL {
                totalHits += 1
                searchCache[norm] = CacheEntry(
                    key: entry.key,
                    originalQuery: entry.originalQuery,
                    content: entry.content,
                    timestamp: entry.timestamp,
                    hitCount: entry.hitCount + 1,
                    source: entry.source
                )
                coucouLog("[ContextCache] Exact HIT for '\(query)' (used \(entry.hitCount + 1) times, saved ~2.5s network call)")
                return entry.content
            } else {
                searchCache.removeValue(forKey: norm)
            }
        }

        // 2. Fuzzy / Semantic token overlap match (>= 80% similarity for meeting conversations)
        for (key, entry) in searchCache {
            guard now.timeIntervalSince(entry.timestamp) < searchTTL else { continue }
            let sim = Self.tokenSimilarity(norm, key)
            if sim >= 0.80 {
                totalHits += 1
                searchCache[key] = CacheEntry(
                    key: entry.key,
                    originalQuery: entry.originalQuery,
                    content: entry.content,
                    timestamp: entry.timestamp,
                    hitCount: entry.hitCount + 1,
                    source: entry.source
                )
                coucouLog("[ContextCache] Fuzzy HIT for '\(query)' matches '\(entry.originalQuery)' (sim: \(String(format: "%.2f", sim)), saved ~2.5s network call)")
                return entry.content
            }
        }

        totalMisses += 1
        return nil
    }

    public func putSearch(query: String, content: String) {
        let norm = Self.normalizeQuery(query)
        guard !norm.isEmpty && !content.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        // Evict oldest if reaching capacity
        if searchCache.count >= maxEntries {
            evictOldest()
        }

        searchCache[norm] = CacheEntry(
            key: norm,
            originalQuery: query,
            content: content,
            timestamp: Date(),
            hitCount: 0,
            source: "web_search"
        )

        // Also add concise knowledge snippet into Meeting Knowledge Facts buffer
        let factSummary = Self.extractKeyFactSummary(content: content)
        if !factSummary.isEmpty {
            meetingFacts.append(MeetingKnowledgeFact(topic: query, summary: factSummary))
            if meetingFacts.count > 15 {
                meetingFacts.removeFirst()
            }
        }

        schedulePersist()
    }

    // MARK: - Web Fetch (URL) Cache Operations

    public func getWebFetch(url: String) -> String? {
        let canonical = Self.canonicalURL(url)
        guard !canonical.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if let entry = webFetchCache[canonical] {
            if now.timeIntervalSince(entry.timestamp) < webFetchTTL {
                totalHits += 1
                coucouLog("[ContextCache] WebFetch HIT for URL: \(canonical)")
                return entry.content
            } else {
                webFetchCache.removeValue(forKey: canonical)
            }
        }
        return nil
    }

    public func putWebFetch(url: String, content: String) {
        let canonical = Self.canonicalURL(url)
        guard !canonical.isEmpty && !content.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        if webFetchCache.count >= maxEntries {
            if let oldest = webFetchCache.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
                webFetchCache.removeValue(forKey: oldest)
            }
        }

        webFetchCache[canonical] = CacheEntry(
            key: canonical,
            originalQuery: url,
            content: content,
            timestamp: Date(),
            hitCount: 0,
            source: "web_fetch"
        )
        schedulePersist()
    }

    private static func canonicalURL(_ urlStr: String) -> String {
        guard let url = URL(string: urlStr.trimmingCharacters(in: .whitespacesAndNewlines)),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return urlStr.lowercased()
        }
        // Strip tracking query items
        comps.queryItems = comps.queryItems?.filter { item in
            let low = item.name.lowercased()
            return !low.hasPrefix("utm_") && low != "fbclid" && low != "ref" && low != "source"
        }
        return comps.string?.lowercased() ?? urlStr.lowercased()
    }

    // MARK: - Meeting Context Prompt Injection (Prevents Redundant Tool Invocations)

    /// Returns a compact, dense summary of recently retrieved knowledge in this session.
    /// Injected directly into the assistant prompt so the LLM already knows the facts
    /// and doesn't even need to execute `web_search` tool calls repeatedly!
    public func getMeetingContextInjection() -> String {
        lock.lock()
        defer { lock.unlock() }

        guard !meetingFacts.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("[THÔNG TIN TRA CỨU TRONG PHIÊN / RECENT KNOWLEDGE]:")
        for fact in meetingFacts.suffix(8) {
            lines.append("• Chủ đề \"\(fact.topic)\": \(fact.summary)")
        }
        lines.append("(*) LƯU Ý QUAN TRỌNG KHI HỖ TRỢ MEETING:")
        lines.append("- Nếu câu hỏi của người dùng có thể giải đáp từ thông tin đã tra cứu ở trên, HÃY SỬ DỤNG TRỰC TIẾP để trả lời tức thời (< 0.5s).")
        lines.append("- TUYỆT ĐỐI KHÔNG gọi lại công cụ `web_search` cho cùng một chủ đề hoặc thực thể đã có thông tin ở trên!")

        return lines.joined(separator: "\n")
    }

    private static func extractKeyFactSummary(content: String) -> String {
        // Extracts the first 2-3 meaningful bullet lines or snippet sentences
        let lines = content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }

        let prefixLines = lines.prefix(3).joined(separator: " ")
        if prefixLines.count > 300 {
            return String(prefixLines.prefix(290)) + "…"
        }
        return prefixLines
    }

    // MARK: - Maintenance & Eviction

    private func evictOldest() {
        if let oldestKey = searchCache.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
            searchCache.removeValue(forKey: oldestKey)
        }
    }

    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        searchCache.removeAll()
        webFetchCache.removeAll()
        meetingFacts.removeAll()
        totalHits = 0
        totalMisses = 0
        try? FileManager.default.removeItem(at: cacheFileURL)
        coucouLog("[ContextCache] Cleared all context caches.")
    }

    // MARK: - Persistence (Cache file on disk)

    private var cacheFileURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("fr.louisraille.NotchBuddy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("context_cache.json")
    }

    private func schedulePersist() {
        // Debounced background write
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let entries = Array(self.searchCache.values.prefix(100))
            self.lock.unlock()

            if let data = try? JSONEncoder().encode(entries) {
                try? data.write(to: self.cacheFileURL, options: .atomic)
            }
        }
    }

    private func loadPersistedCache() {
        guard FileManager.default.fileExists(atPath: cacheFileURL.path),
              let data = try? Data(contentsOf: cacheFileURL),
              let list = try? JSONDecoder().decode([CacheEntry].self, from: data) else {
            return
        }
        lock.lock()
        let now = Date()
        for item in list {
            if now.timeIntervalSince(item.timestamp) < searchTTL {
                searchCache[item.key] = item
            }
        }
        lock.unlock()
    }
}
