import Foundation

// MARK: - Proactive Capability Schema (Zero Hardcode)
// Represents a dynamically registered skill or intent that Coucou can suggest.
// Loaded from built-in schemas, user JSON files (~/.coucou/capabilities.json),
// and external plugins (~/.gemini/config/plugins/ or ~/.codex/plugins/).

public struct ProactiveCapability: Identifiable, Codable, Sendable {
    public let id: String
    public let name: String
    /// Natural language description of when this capability should be triggered
    public let triggerIntent: String
    /// Recommended short title for Notch (2-3 words)
    public let defaultTitle: String
    /// Recommended short subtitle for Notch (4-6 words)
    public let defaultDetail: String
    /// System prompt template to execute when accepted by user
    public let actionPromptTemplate: String
    /// SF Symbol icon
    public let icon: String

    public init(
        id: String,
        name: String,
        triggerIntent: String,
        defaultTitle: String,
        defaultDetail: String,
        actionPromptTemplate: String,
        icon: String
    ) {
        self.id = id
        self.name = name
        self.triggerIntent = triggerIntent
        self.defaultTitle = defaultTitle
        self.defaultDetail = defaultDetail
        self.actionPromptTemplate = actionPromptTemplate
        self.icon = icon
    }
}

// MARK: - Dynamic Capability Registry
public final class CapabilityRegistry: @unchecked Sendable {
    public static let shared = CapabilityRegistry()

    private let lock = NSLock()
    private var capabilities: [String: ProactiveCapability] = [:]

    private init() {
        registerBuiltInCapabilities()
        loadUserDefinedCapabilities()
    }

    // MARK: - Built-in Capabilities (Extensible baseline)

    private func registerBuiltInCapabilities() {
        let defaults: [ProactiveCapability] = [
            // 1. Financial Invoices, Receipts & Bank Transactions
            ProactiveCapability(
                id: "save_invoice_transaction",
                name: "Lưu thông tin giao dịch & Hoá đơn",
                triggerIntent: "Hóa đơn điện tử, biên lai thanh toán, xác nhận chuyển khoản, sao kê, thông báo trừ tiền ngân hàng, email hoá đơn EVN/Grab/Shopee/Stripe/Apple/AWS, file PDF invoice hoặc receipt.",
                defaultTitle: "Lưu hoá đơn",
                defaultDetail: "Ghi nhận vào sổ chi tiêu",
                actionPromptTemplate: "Trích xuất đầy đủ thông tin giao dịch từ nội dung sau (gồm: ngày giao dịch, đơn vị phát hành/người nhận, số tiền, loại tiền tệ, mã hoá đơn, hạng mục chi tiêu). Sau đó tổng hợp thành định dạng JSON chuẩn và ghi nhận thông tin giao dịch:",
                icon: "creditcard.fill"
            ),

            // 2. Email & Document Summarization
            ProactiveCapability(
                id: "summarize_email_or_doc",
                name: "Tóm tắt Email & Tài liệu",
                triggerIntent: "Email dài từ đối tác/đồng nghiệp, bản tin tin tức, bài viết, báo cáo PDF, tài liệu nghiệp vụ cần nắm bắt nhanh nội dung cốt lõi và các việc cần làm (action items).",
                defaultTitle: "Tóm tắt nội dung",
                defaultDetail: "Rút gọn các ý chính",
                actionPromptTemplate: "Đọc kỹ nội dung sau từ {appName} ({title}), tóm tắt ngắn gọn 3-5 ý quan trọng nhất cùng danh sách các hành động cần làm tiếp theo (nếu có):",
                icon: "doc.text.magnifyingglass"
            ),

            // 3. Calendar & Meeting Scheduling
            ProactiveCapability(
                id: "schedule_calendar_event",
                name: "Tạo lịch hẹn & Nhắc nhở",
                triggerIntent: "Thông báo có cuộc họp, lời mời Google Meet/Zoom, vé máy bay, lịch hẹn bác sĩ, deadline, hoặc sự kiện có thời gian và địa điểm cụ thể.",
                defaultTitle: "Tạo lịch hẹn",
                defaultDetail: "Thêm vào ứng dụng Lịch",
                actionPromptTemplate: "Phân tích nội dung sau để trích xuất: tiêu đề cuộc hẹn, thời gian bắt đầu, thời gian kết thúc, link họp hoặc địa điểm, danh sách người tham gia. Sau đó hỗ trợ tạo sự kiện tương ứng:",
                icon: "calendar.badge.plus"
            ),

            // 4. Archive & Download Organization
            ProactiveCapability(
                id: "organize_downloaded_file",
                name: "Quản lý & Phân loại file tải về",
                triggerIntent: "File mới tải về máy tính như file nén (.zip, .tar.gz, .rar), file cài đặt (.dmg, .pkg), hoặc bộ tài liệu cần giải nén và phân loại vào đúng thư mục dự án.",
                defaultTitle: "Sắp xếp file tải",
                defaultDetail: "Xử lý file vừa tải về",
                actionPromptTemplate: "Hỗ trợ kiểm tra, giải nén và phân loại file vừa tải về {filePath} vào thư mục làm việc phù hợp:",
                icon: "folder.badge.gearshape"
            ),

            // 5. Code Error & Bug Diagnosis
            ProactiveCapability(
                id: "diagnose_code_error",
                name: "Chẩn đoán lỗi lập trình",
                triggerIntent: "Thông báo lỗi từ terminal, log CI/CD, build failure, compiler error, stack trace, hoặc issue GitHub mới được giao.",
                defaultTitle: "Chẩn đoán lỗi",
                defaultDetail: "Tìm nguyên nhân và cách sửa",
                actionPromptTemplate: "Chẩn đoán nguyên nhân gây ra lỗi sau và đưa ra giải pháp khắc phục chi tiết từng bước kèm đoạn mã sửa chữa:",
                icon: "exclamationmark.triangle.fill"
            ),

            // 6. Pull Request Review & Collaboration
            ProactiveCapability(
                id: "review_pull_request",
                name: "Review Pull Request",
                triggerIntent: "Thông báo từ GitHub/GitLab khi có Pull Request mới cần review, comment mới trên PR, hoặc code review request.",
                defaultTitle: "Review Pull Request",
                defaultDetail: "Xem thay đổi và góp ý code",
                actionPromptTemplate: "Phân tích và tóm tắt Pull Request sau: kiểm tra mục đích thay đổi, rủi ro tiềm ẩn và các điểm cần lưu ý khi review:",
                icon: "arrow.triangle.pull"
            ),

            // 7. General Quick Action (Fallback)
            ProactiveCapability(
                id: "assist_task",
                name: "Hỗ trợ tác vụ",
                triggerIntent: "Yêu cầu công việc, câu hỏi hoặc tác vụ từ tin nhắn/thông báo cần AI hỗ trợ xử lý tức thời.",
                defaultTitle: "Hỗ trợ tác vụ",
                defaultDetail: "Xử lý thông tin mới",
                actionPromptTemplate: "Hỗ trợ xử lý thông tin sau theo ngữ cảnh:",
                icon: "sparkles"
            )
        ]

        lock.lock()
        for cap in defaults {
            capabilities[cap.id] = cap
        }
        lock.unlock()
    }

    // MARK: - Dynamic Loading from Disk (Zero Hardcode)

    public func loadUserDefinedCapabilities() {
        let fileManager = FileManager.default
        let coucouDir = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".coucou")
        let customFile = coucouDir.appendingPathComponent("capabilities.json")
        let customDir = coucouDir.appendingPathComponent("capabilities")

        // 1. Load from ~/.coucou/capabilities.json if exists
        if fileManager.fileExists(atPath: customFile.path),
           let data = try? Data(contentsOf: customFile),
           let list = try? JSONDecoder().decode([ProactiveCapability].self, from: data) {
            lock.lock()
            for cap in list { capabilities[cap.id] = cap }
            lock.unlock()
        }

        // 2. Load from ~/.coucou/capabilities/*.json
        if let files = try? fileManager.contentsOfDirectory(at: customDir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension.lowercased() == "json" {
                if let data = try? Data(contentsOf: f),
                   let cap = try? JSONDecoder().decode(ProactiveCapability.self, from: data) {
                    lock.lock()
                    capabilities[cap.id] = cap
                    lock.unlock()
                }
            }
        }
    }

    public func registerCapability(_ cap: ProactiveCapability) {
        lock.lock()
        capabilities[cap.id] = cap
        lock.unlock()
    }

    public func allCapabilities() -> [ProactiveCapability] {
        lock.lock()
        defer { lock.unlock() }
        return Array(capabilities.values)
    }

    /// Formats all registered capabilities into a compact JSON schema string for the LLM Evaluator
    public func promptManifest() -> String {
        let all = allCapabilities()
        var items: [[String: String]] = []
        for c in all {
            items.append([
                "id": c.id,
                "name": c.name,
                "triggerIntent": c.triggerIntent,
                "defaultTitle": c.defaultTitle,
                "icon": c.icon
            ])
        }
        if let data = try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "[]"
    }

    public func capability(for id: String) -> ProactiveCapability? {
        lock.lock()
        defer { lock.unlock() }
        return capabilities[id]
    }
}
